package wsapi

import (
	"fmt"
	"io"
	"log/slog"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/session"
)

// link は、ブラウザとの WebSocket の接続 1 本への送信と切断（session.BrowserLink の実装。requirements.md 11.9・27）。
//
// # 書き込み
//
// 書き込みは、書き込み役のゴルーチン 1 つに直列化する（gorilla/websocket は、同時の書き込みを禁じる）。Send と Close は、
// 待ち行列に積むだけで、呼び出し元（セッションのループ）をブロックしない。
//
// # 待ち行列と優先
//
// 中継がブラウザへ送るのは、小さな制御メッセージだけ（再エンコードしない。映像・音声は、ブラウザから中継への一方向）。
//   - 受領応答（ack）と抑制指示（throttle）は、最新の値だけが意味を持つ。種類ごとに 1 つの枠を持ち、新しいものが古いものを
//     置き換える（遅いブラウザの前に、古い値が積み重ならない）。書き込み役は、これを先に（優先して）書く。ただし、待っている
//     重要なメッセージも、交互に進める（飢えさせない）
//   - それ以外（接続受理・計測結果・キーフレーム要求・状態通知・致命通知）は、状態の変化を伝えるので、落とさず、順序を保って積む。
//     上限（SendQueueLimit）を超えたら、ブラウザが読んでいないものとして、接続を切る（Send は ErrLinkClosed。セッションは、
//     接続を失ったものとして扱い、ブラウザの復帰を待つ）。中継のメモリが、遅いブラウザで増え続けない
//
// # 死活の確認
//
// 時計で PingInterval ごとに、ping を送る（書き込み役が書く）。相手から何も（データも pong も）届かない時間が IdleTimeout に
// なったら切る。1 回の書き込みが WriteTimeout を過ぎても終わらない（読まない相手）なら、接続を閉じて、書き込み役を解放する。
// これらはすべて、注入された時計のタイマーで行う（実時間の期限を、接続に設定しない）。
//
// # 閉じる
//
// Close(code) は、積んだメッセージ（致命通知）をすべて書いてから、Close フレームを送り、書き込み側を閉じる。そのあと、相手が
// Close フレームを返す（または接続を閉じる）のを、LingerTimeout まで待つ（読み取りの繰り返しが読み続ける）。読み残しのある接続を
// すぐに閉じると、TCP が RST を返し、相手に致命通知が届かないことがあるため。
type link struct {
	sock  socket
	clock session.Clock
	opts  Options
	log   *slog.Logger

	wake       chan struct{}
	writerDone chan struct{}

	mu          sync.Mutex
	pingTimer   session.Timer
	writeTimer  session.Timer
	lingerTimer session.Timer
	queued      [][]byte
	latest      [slotCount][]byte
	lastLatest  bool // 直前に書いたのが、最新の 1 つだけを保つメッセージ
	closeReq    bool
	closeCode   int
	dead        bool
	pingDue     bool
	lastRecv    time.Time
}

// 最新の 1 つだけを保つメッセージの枠。
const (
	slotAck = iota
	slotThrottle
	slotCount
)

// 接続を落とす理由（記録に出す語彙）。
const (
	reasonQueueOverflow = "send_queue_overflow"
	reasonWriteTimeout  = "write_timeout"
	reasonWriteFailed   = "write_failed"
	reasonIdleTimeout   = "idle_timeout"
	reasonLinger        = "linger_timeout"
	reasonPanic         = "panic"
	reasonForced        = "shutdown_forced"
)

// latestSlotOf は、符号化済みのメッセージが、最新の 1 つだけを保つもの（受領応答・抑制指示）なら、その枠を返す。種別は、ヘッダの
// 4 バイト目から読む。読めないもの・それ以外のものは、false（状態の変化を伝える重要なメッセージとして、落とさずに積む）。
func latestSlotOf(message []byte) (int, bool) {
	if len(message) <= contract.WSFrameHeaderFieldsTypeOffset {
		return 0, false
	}
	switch contract.FrameType(message[contract.WSFrameHeaderFieldsTypeOffset]) {
	case contract.FrameTypeAck:
		return slotAck, true
	case contract.FrameTypeThrottle:
		return slotThrottle, true
	}
	return 0, false
}

// newLink は、link を作り、書き込み役のゴルーチンを始める。終わるときは、必ず finish を呼ぶ。
func newLink(sock socket, clock session.Clock, opts Options, log *slog.Logger) *link {
	l := &link{
		sock:       sock,
		clock:      clock,
		opts:       opts,
		log:        log,
		wake:       make(chan struct{}, 1),
		writerDone: make(chan struct{}),
		lastRecv:   clock.Now(),
	}
	// タイマーの設定が済むまで、タイマーの処理（l.mu を取る）を待たせる
	l.mu.Lock()
	l.pingTimer = clock.AfterFunc(opts.PingInterval, l.onPingTimer)
	l.writeTimer = clock.AfterFunc(opts.WriteTimeout, l.onWriteTimeout)
	l.writeTimer.Stop()
	l.lingerTimer = clock.AfterFunc(opts.LingerTimeout, l.onLingerTimeout)
	l.lingerTimer.Stop()
	l.mu.Unlock()
	go l.writeLoop()
	return l
}

// ---- session.BrowserLink ----

// Send は、符号化済みのメッセージ（制御メッセージ 1 つ）を送る。呼び出し元をブロックしない。メッセージは、写しを取る。
// 閉じていれば（Close のあとを含む）session.ErrLinkClosed。重要なメッセージの待ち行列が満ちたら、接続を切って、同じエラー。
func (l *link) Send(message []byte) error {
	copied := append([]byte(nil), message...)
	slot, isLatest := latestSlotOf(copied)
	l.mu.Lock()
	if l.dead || l.closeReq {
		l.mu.Unlock()
		return session.ErrLinkClosed
	}
	if isLatest {
		l.latest[slot] = copied
	} else {
		if len(l.queued) >= l.opts.SendQueueLimit {
			l.mu.Unlock()
			l.abort(reasonQueueOverflow)
			return session.ErrLinkClosed
		}
		l.queued = append(l.queued, copied)
	}
	l.mu.Unlock()
	l.signal()
	return nil
}

// Close は、Close コード code で接続を閉じる。すでに Send したメッセージ（致命通知）を送ってから閉じる。何度呼んでもよい
// （最初のコードだけが効く）。呼び出し元をブロックしない。
func (l *link) Close(code int) {
	l.mu.Lock()
	if l.dead || l.closeReq {
		l.mu.Unlock()
		return
	}
	l.closeReq = true
	l.closeCode = code
	// 閉じるときに、古い受領応答・抑制指示を送る意味は無い
	l.latest = [slotCount][]byte{}
	l.mu.Unlock()
	l.signal()
}

// ---- 状態の読み取り ----

// touch は、相手から何か（データ・pong・ping）が届いたことを記録する。
func (l *link) touch() {
	now := l.clock.Now()
	l.mu.Lock()
	l.lastRecv = now
	l.mu.Unlock()
}

// closing は、閉じる手順に入った（Close が呼ばれた、または接続が終わった）か。
func (l *link) closing() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.closeReq || l.dead
}

func (l *link) signal() {
	select {
	case l.wake <- struct{}{}:
	default:
	}
}

// ---- 書き込み役 ----

type workKind int

const (
	workStop workKind = iota + 1
	workPing
	workMessage
	workClose
)

// work は、書き込み役が次にすること。
type work struct {
	kind    workKind
	message []byte
	code    int
}

func (l *link) writeLoop() {
	defer close(l.writerDone)
	defer func() {
		// 書き込みの途中の panic で、中継全体を落とさない。その接続だけを閉じる。panic の値は、記録しない（秘密値が入り得る）
		if recovered := recover(); recovered != nil {
			l.log.Error("the browser connection writer panicked", slog.String("panic_type", fmt.Sprintf("%T", recovered)))
			l.abort(reasonPanic)
		}
	}()
	for {
		next := l.next()
		switch next.kind {
		case workStop:
			return
		case workPing:
			if !l.writeGuarded(func() error { return l.sock.WriteControl(websocket.PingMessage, nil, time.Time{}) }) {
				return
			}
		case workMessage:
			if !l.writeGuarded(func() error { return l.sock.WriteMessage(websocket.BinaryMessage, next.message) }) {
				return
			}
		case workClose:
			l.sendClose(next.code)
			return
		}
	}
}

// next は、次にすることを返す（なければ、起こされるまで待つ）。優先は、ping → 受領応答・抑制指示 → 積んだ重要なメッセージ → 閉じる。
// 受領応答・抑制指示のあとは、待っている重要なメッセージを先に書く（交互。飢えさせない）。
func (l *link) next() work {
	for {
		l.mu.Lock()
		if picked, ok := l.pickLocked(); ok {
			l.mu.Unlock()
			return picked
		}
		l.mu.Unlock()
		<-l.wake
	}
}

func (l *link) pickLocked() (work, bool) {
	if l.dead {
		return work{kind: workStop}, true
	}
	if l.pingDue {
		l.pingDue = false
		return work{kind: workPing}, true
	}
	hasLatest := l.latest[slotAck] != nil || l.latest[slotThrottle] != nil
	hasQueued := len(l.queued) > 0
	if hasLatest && (!l.lastLatest || !hasQueued) {
		slot := slotAck
		if l.latest[slotAck] == nil {
			slot = slotThrottle
		}
		message := l.latest[slot]
		l.latest[slot] = nil
		l.lastLatest = true
		return work{kind: workMessage, message: message}, true
	}
	if hasQueued {
		message := l.queued[0]
		l.queued[0] = nil
		l.queued = l.queued[1:]
		l.lastLatest = false
		return work{kind: workMessage, message: message}, true
	}
	if l.closeReq {
		return work{kind: workClose, code: l.closeCode}, true
	}
	return work{}, false
}

// writeGuarded は、書き込みを 1 回行う。期限（WriteTimeout）の見張りをつけ、失敗したら接続を落として false。
func (l *link) writeGuarded(write func() error) bool {
	l.mu.Lock()
	if l.dead {
		l.mu.Unlock()
		return false
	}
	l.writeTimer.Reset(l.opts.WriteTimeout)
	l.mu.Unlock()
	err := write()
	l.writeTimer.Stop()
	if err != nil {
		l.abort(reasonWriteFailed)
		return false
	}
	return true
}

// sendClose は、Close フレームを送り、書き込み側を閉じて、相手が閉じるのを待つ時間を数え始める。
func (l *link) sendClose(code int) {
	l.pingTimer.Stop()
	closeFrame := websocket.FormatCloseMessage(code, "")
	if !l.writeGuarded(func() error { return l.sock.WriteControl(websocket.CloseMessage, closeFrame, time.Time{}) }) {
		return
	}
	l.mu.Lock()
	if !l.dead {
		l.lingerTimer.Reset(l.opts.LingerTimeout)
	}
	l.mu.Unlock()
	if err := l.sock.CloseWrite(); err != nil {
		l.log.Debug("the write side could not be shut", slog.String("class", "close_write"))
	}
}

// ---- タイマー ----

// onPingTimer は、PingInterval ごとに鳴る。相手から何も届かない時間が IdleTimeout に達していれば、接続を切る。そうでなければ、
// ping を書くよう、書き込み役へ頼み、次の拍を設定する。閉じる手順に入ったあとは、何もしない。
func (l *link) onPingTimer() {
	defer l.recoverCallback()
	now := l.clock.Now()
	l.mu.Lock()
	if l.dead || l.closeReq {
		l.mu.Unlock()
		return
	}
	if now.Sub(l.lastRecv) >= l.opts.IdleTimeout {
		l.mu.Unlock()
		l.abort(reasonIdleTimeout)
		return
	}
	l.pingDue = true
	l.pingTimer.Reset(l.opts.PingInterval)
	l.mu.Unlock()
	l.signal()
}

// onWriteTimer は、1 回の書き込みが期限を過ぎても終わらない。読まない相手とみなして、接続を落とす。
func (l *link) onWriteTimeout() {
	defer l.recoverCallback()
	l.abort(reasonWriteTimeout)
}

// onLingerTimeout は、Close フレームを送ったのに、相手が閉じない。接続を閉じる。
func (l *link) onLingerTimeout() {
	defer l.recoverCallback()
	l.abort(reasonLinger)
}

// recoverCallback は、タイマーの処理の panic で、中継全体を落とさない。値は記録しない。
func (l *link) recoverCallback() {
	if recovered := recover(); recovered != nil {
		l.log.Error("a browser connection timer callback panicked", slog.String("panic_type", fmt.Sprintf("%T", recovered)))
		l.abort(reasonPanic)
	}
}

// ---- 終わらせる ----

// abort は、接続を直ちに落とす（Close フレームは送らない）。最初の理由だけが効く。タイマーを止め、基になる接続を閉じる
// （止まっている読み書きは、エラーで戻る）。
func (l *link) abort(reason string) {
	l.mu.Lock()
	if l.dead {
		l.mu.Unlock()
		return
	}
	l.dead = true
	l.mu.Unlock()
	l.logAbort(reason)
	l.stopTimers()
	_ = l.sock.Close()
	l.signal()
}

// logAbort は、接続を落としたことを記録する。相手が先に閉じた（書き込みの失敗）・相手が閉じなかった（待ちの期限）は、
// 通常の範囲なので、詳細な記録に留める。
func (l *link) logAbort(reason string) {
	switch reason {
	case reasonWriteFailed, reasonLinger:
		l.log.Debug("the browser connection ended", slog.String("reason", reason))
	default:
		l.log.Warn("the browser connection was dropped", slog.String("reason", reason))
	}
}

func (l *link) stopTimers() {
	l.mu.Lock()
	timers := []session.Timer{l.pingTimer, l.writeTimer, l.lingerTimer}
	l.mu.Unlock()
	for _, timer := range timers {
		timer.Stop()
	}
}

// finish は、接続の後始末（受信の繰り返しが終わったあとに、必ず 1 回以上呼ぶ）。以後の送信を拒み、タイマーを止め、基になる
// 接続を閉じ、書き込み役のゴルーチンが終わるのを待つ。何度呼んでもよい。
func (l *link) finish() {
	l.mu.Lock()
	l.dead = true
	l.mu.Unlock()
	l.stopTimers()
	_ = l.sock.Close()
	l.signal()
	<-l.writerDone
}

// String は、待ち行列の長さだけを示す（メッセージの中身を出さない）。
func (l *link) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return fmt.Sprintf("wsapi.link{queued=%d closing=%t dead=%t}", len(l.queued), l.closeReq, l.dead)
}

// GoString は、String と同じ。
func (l *link) GoString() string { return l.String() }

// Format は、どの書式動詞でも、String だけを書く。
func (l *link) Format(f fmt.State, _ rune) { _, _ = io.WriteString(f, l.String()) }
