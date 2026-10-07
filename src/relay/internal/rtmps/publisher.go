package rtmps

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

const (
	// bufferLimitMs は、送出待ちのメディア時間の幅の上限（ミリ秒。契約 relay.egress_buffer_limit_ms。3 秒分）。
	// 達したら ErrBufferOverflow（requirements.md 11.10）。判定の規則（以上）は、core/buffer の Policy.Evaluate の Overflow と同じ。
	bufferLimitMs = contract.RelayEgressBufferLimitMs

	// maxMessageBytes は、RTMP のメッセージの長さの上限（長さの欄が 24 ビット）。
	maxMessageBytes = 1<<24 - 1

	// maxPendingBytes は、送出待ちの量（バイト）の上限。3 秒分の上限（bufferLimitMs）の安全網で、時刻が進まない（同じ時刻を
	// 繰り返す・逆行する）書き込みや、メタデータの大量の書き込みでも、メモリが際限なく増えないようにする。最大のプロファイル
	// （映像 6,000 kbps・音声 128 kbps）の受信上限（1.5 倍）でも 3 秒分は 3.5 MB ほどなので、正しい使い方では、決して達しない。
	maxPendingBytes = 32 * 1024 * 1024
)

// sink は、RTMP の接続への書き込みと、接続の状態。実体は go-rtmp のストリーム（rtmpSink）。試験では、疑似の実装に差し替える。
// write の各メソッドは、同時に 1 つのゴルーチン（Publisher の書き込みのゴルーチン）からしか呼ばれない
// （go-rtmp の Stream.Write は、並行に呼べない）。それ以外のメソッドは、別のゴルーチンから呼ばれる。
type sink interface {
	// writeVideo・writeAudio は、RTMP の映像・音声メッセージを書く（本体は、FLV の VideoData・AudioData）。時刻は、ミリ秒。
	writeVideo(timestampMs uint32, payload []byte) error
	writeAudio(timestampMs uint32, payload []byte) error
	// writeMeta は、RTMP のデータメッセージ（@setDataFrame と、本体 onMetaData）を書く。
	writeMeta(payload []byte) error
	// connectionError は、接続が失われていれば、その原因を返す（健在なら nil）。go-rtmp の読み取りのゴルーチンが止まった
	// （切断・読み取りの失敗）ときに、非 nil になる。
	connectionError() error
	// kill は、接続を直ちに壊す（読み書きで止まっているゴルーチンを解く）。何度呼んでもよい。
	kill()
	// close は、書き込み中のものを待ってから、接続を閉じ、資源を解放する（kill のあとでも呼ぶ）。kill のあとでなければ、
	// 閉じるときに、送信側を閉じ（FIN）、受け口が閉じるのを CloseLinger まで待つ（送ったものを、受け口が受け取ったことの確認）。
	close() error
}

type itemKind uint8

const (
	kindVideo itemKind = iota + 1
	kindAudio
	kindMeta
)

// item は、送出キューの 1 件。payload は、Publisher が所有する。
type item struct {
	kind    itemKind
	ts      uint32
	payload []byte
}

type state uint8

const (
	stateOpen     state = iota // 書き込みを受け付ける
	stateDraining              // Close が呼ばれ、送出待ちを送り切っている。新しい書き込みは受け付けない
	stateClosed                // 終了（失敗・Abort・Close の完了）。バッファは破棄済み
)

func (s state) String() string {
	switch s {
	case stateOpen:
		return "open"
	case stateDraining:
		return "draining"
	case stateClosed:
		return "closed"
	}
	return "unknown"
}

// Publisher は、1 つの RTMPS の接続への、非同期の送出（requirements.md 11.10）。
//
// WriteVideo・WriteAudio・WriteMeta は、送出キューへ積むだけで、呼び出し元をブロックしない。キューは、単一の書き込みの
// ゴルーチンが、積んだ順に、RTMP のメッセージとして書く（go-rtmp の Stream.Write は、並行に呼べないため）。
// 映像・音声・メタを、別のゴルーチンから並行に呼んでよい。
//
// 送出待ちのメディア時間の幅（PendingMs。最後に積んだ時刻 - 最後に送った時刻）が、3 秒分（契約 relay.egress_buffer_limit_ms）に
// 達したら、バッファを破棄し、接続を切って、閉じる（その書き込みは ErrBufferOverflow）。呼び出し側が、接続し直す。
// 時刻が進まない書き込みでも、メモリが増え続けないように、送出待ちの量（バイト）にも、上限を置く（maxPendingBytes。同じ扱い）。
// 接続の切断・書き込みの失敗も、Closed が通知し、以後の書き込みは ErrClosed（原因も包む）。
//
// Close は、送出待ちを送り切ってから接続を切る（停止の経路。13.3）。Abort は、バッファを破棄して直ちに切る。
// 配信キーは、保持しない（Dial が、publish に 1 回使うだけ）。バッファは、閉じるときに破棄する。メディアをファイルへ保存しない。
// 作成は Dial（試験では newPublisher）。
type Publisher struct {
	sink        sink
	cfg         Config
	log         *slog.Logger
	publishedAt time.Time // publish を送った時刻（ErrPublishRejected の窓の起点）

	mu           sync.Mutex
	state        state
	cause        error // 終了の原因。clean な Close・Abort は ErrClosed
	kill         bool  // 後始末で、先に接続を壊すか（失敗・Abort・期限切れ）。送り切った Close だけが、壊さずに閉じる
	closeErr     error // 接続を閉じたときのエラー
	queue        []item
	queuedBytes  int    // キューに積んだ本文の合計（バイト）
	hasMedia     bool   // 時刻を持つメッセージ（映像・音声）を、1 つでも積んだ
	lastQueuedMs uint32 // 最後に積んだ時刻（映像・音声のうち、最大）
	lastSentMs   uint32 // 最後に送った時刻（同じく最大。まだ送っていなければ、最初に積んだ時刻）
	sentBytes    uint64

	wake       chan struct{} // 書き込みのゴルーチンを起こす（容量 1）
	closed     chan struct{} // 終了したら閉じる（Closed）
	writerDone chan struct{} // 書き込みのゴルーチンが終わったら閉じる
	done       chan struct{} // 後始末（接続の切断・ゴルーチンの終了）が済んだら閉じる
}

// newPublisher は、sink の上に Publisher を作り、書き込みと見張りのゴルーチンを始める。
func newPublisher(s sink, cfg Config) (*Publisher, error) {
	normalized, err := cfg.normalized()
	if err != nil {
		return nil, err
	}
	p := &Publisher{
		sink:        s,
		cfg:         normalized,
		log:         normalized.Logger,
		publishedAt: time.Now(),
		wake:        make(chan struct{}, 1),
		closed:      make(chan struct{}),
		writerDone:  make(chan struct{}),
		done:        make(chan struct{}),
	}
	go p.writeLoop()
	go p.monitor()
	return p, nil
}

// WriteVideo は、映像のメッセージ（本体は、flv.Muxer の Video・VideoConfig の出力）を、送出キューへ積む。
// timestampMs は、RTMP のメッセージの時刻（ミリ秒。接続ごとに 0 起点へ再基準化したもの）。payload は、Publisher の所有になる
// （渡したあとは、書き換えない）。呼び出し元をブロックしない。
// 空・上限（24 ビット）を超える本文は ErrInvalidMessage、閉じていれば ErrClosed、送出待ちが 3 秒分に達したら ErrBufferOverflow。
func (p *Publisher) WriteVideo(timestampMs uint32, payload []byte) error {
	return p.enqueue(kindVideo, timestampMs, payload)
}

// WriteAudio は、音声のメッセージ（本体は、flv.Muxer の Audio・AudioConfig の出力）を、送出キューへ積む。WriteVideo と同じ。
func (p *Publisher) WriteAudio(timestampMs uint32, payload []byte) error {
	return p.enqueue(kindAudio, timestampMs, payload)
}

// WriteMeta は、メタデータ（flv.Muxer の Metadata の出力）を、データメッセージ（@setDataFrame）として、送出キューへ積む。
// 時刻を持たず、送出待ちの幅にも、上限にも、数えない。それ以外は、WriteVideo と同じ。
func (p *Publisher) WriteMeta(payload []byte) error {
	return p.enqueue(kindMeta, 0, payload)
}

func (p *Publisher) enqueue(kind itemKind, timestampMs uint32, payload []byte) error {
	if len(payload) == 0 || len(payload) > maxMessageBytes {
		return fmt.Errorf("%w: %d bytes (want 1..%d)", ErrInvalidMessage, len(payload), maxMessageBytes)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.state != stateOpen {
		return p.closedErrLocked()
	}
	if kind != kindMeta {
		p.noteQueuedLocked(timestampMs)
		if pending := p.pendingLocked(); pending >= bufferLimitMs {
			cause := fmt.Errorf("%w: pending %d ms (limit %d ms)", ErrBufferOverflow, pending, bufferLimitMs)
			p.terminateLocked(cause, true)
			return cause
		}
	}
	if total := p.queuedBytes + len(payload); total > maxPendingBytes {
		cause := fmt.Errorf("%w: pending %d bytes (limit %d bytes)", ErrBufferOverflow, total, maxPendingBytes)
		p.terminateLocked(cause, true)
		return cause
	}
	p.queue = append(p.queue, item{kind: kind, ts: timestampMs, payload: payload})
	p.queuedBytes += len(payload)
	p.signalLocked()
	return nil
}

// noteQueuedLocked は、時刻つきのメッセージを積んだことを記録する。最初のメッセージの時刻が、「最後に送った時刻」の起点になる。
func (p *Publisher) noteQueuedLocked(timestampMs uint32) {
	if !p.hasMedia {
		p.hasMedia = true
		p.lastSentMs = timestampMs
		p.lastQueuedMs = timestampMs
		return
	}
	if timestampMs > p.lastQueuedMs {
		p.lastQueuedMs = timestampMs
	}
}

func (p *Publisher) pendingLocked() int {
	if p.state == stateClosed || !p.hasMedia || p.lastQueuedMs <= p.lastSentMs {
		return 0
	}
	return int(p.lastQueuedMs - p.lastSentMs)
}

func (p *Publisher) signalLocked() {
	select {
	case p.wake <- struct{}{}:
	default: // すでに、起こす印がある
	}
}

// PendingMs は、送出待ちのメディア時間の幅（ミリ秒）。最後に積んだ時刻 - 最後に送った時刻（映像・音声のうち、大きい方）。
// 何も送っていないうちは、最初に積んだ時刻を、「最後に送った時刻」とみなす。閉じたあとは 0（バッファは破棄済み）。
// 1.5 秒分（契約 relay.egress_throttle_ms）を超えたら抑制指示を送る判定（core/buffer）の入力に使う。
func (p *Publisher) PendingMs() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pendingLocked()
}

// SentBytes は、RTMP へ書いた本文の合計（バイト）。月次の送信転送量の積算（心拍の sent_bytes_delta）と、送出ビットレートの算出に使う。
func (p *Publisher) SentBytes() uint64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.sentBytes
}

// Closed は、Publisher が終了したときに閉じるチャネル（切断の検知・書き込みの失敗・送出待ちの上限・Close・Abort のどれでも）。
// 理由は、Err。
func (p *Publisher) Closed() <-chan struct{} {
	return p.closed
}

// Err は、終了の原因を返す（終了するまでは nil）。呼び出し側の Close・Abort は ErrClosed。
// 失敗は、ErrBufferOverflow・ErrPublishRejected・ErrDisconnected・ErrDrainTimeout のいずれかを包む（errors.Is で判定する）。
func (p *Publisher) Err() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.state != stateClosed {
		return nil
	}
	return p.cause
}

// closedErrLocked は、閉じたあとの書き込みが返すエラー。ErrClosed で、失敗のあとは、その原因も包む。
func (p *Publisher) closedErrLocked() error {
	if p.state != stateClosed || p.cause == nil || errors.Is(p.cause, ErrClosed) {
		return ErrClosed
	}
	return fmt.Errorf("%w: %w", ErrClosed, p.cause)
}

// Close は、送出待ちをすべて送り切ってから、RTMPS の接続を切る（停止の経路。13.3）。呼んだあとの書き込みは、ErrClosed。
// 送り切れなければ（CloseTimeout が過ぎる・書き込みが失敗する）、強制的に切り、その原因（ErrDrainTimeout など）を返す。
// すべて送り切って切断できたときは、nil（接続を閉じるときのエラーがあれば、それ）。何度呼んでも、並行に呼んでも、同じ結果。
// すでに失敗して閉じていれば、その原因を返す。Abort のあとは、nil。
//
// 送り切ったあとの切断は、おだやかに行う：送信側を閉じて（FIN）、受け口が閉じるのを、CloseLinger まで待ってから戻る。
// 受け口が閉じたことは、送ったものを、受け口がすべて受け取ったことの確認になる（読んでいない受信を残したまま、ソケットを閉じると、
// OS は RST を送り、送信キューに残った配信の最後の部分が捨てられる）。受け口が閉じなくても、CloseLinger で待つのをやめ、
// 失敗にはしない（送り切っている）。
func (p *Publisher) Close() error {
	p.mu.Lock()
	if p.state == stateOpen {
		p.state = stateDraining
		p.signalLocked()
	}
	p.mu.Unlock()

	timer := time.NewTimer(p.cfg.CloseTimeout)
	defer timer.Stop()
	select {
	case <-p.closed:
	case <-timer.C:
		p.terminate(fmt.Errorf("%w (%v)", ErrDrainTimeout, p.cfg.CloseTimeout), true)
	}
	if !p.waitDone() {
		return ErrTeardownTimeout
	}
	return p.finalError()
}

// Abort は、バッファを破棄して、直ちに接続を切る（強制）。止まっている書き込みも解く。何度呼んでもよい。
// すでに終了している Publisher の後始末（送り切った Close が、受け口が閉じるのを待っている最中を含む）は、早めない。
// その後始末が済むのを、TeardownTimeout + CloseLinger まで待つ（有限）。
func (p *Publisher) Abort() {
	p.terminate(ErrClosed, true)
	p.waitDone()
}

// waitDone は、後始末が済むのを、TeardownTimeout + CloseLinger まで待つ（送り切った Close は、後始末の最後に、受け口が閉じるのを、
// CloseLinger まで待つ）。済んだら true。
func (p *Publisher) waitDone() bool {
	timer := time.NewTimer(p.cfg.TeardownTimeout + p.cfg.CloseLinger)
	defer timer.Stop()
	select {
	case <-p.done:
		return true
	case <-timer.C:
		return false
	}
}

func (p *Publisher) finalError() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cause != nil && !errors.Is(p.cause, ErrClosed) {
		return p.cause
	}
	return p.closeErr
}

// terminate は、Publisher を終了させる。最初の原因だけが残る（2 回目以降は、何もしない）。この呼び出しが、最初の原因を残したときだけ true。
func (p *Publisher) terminate(cause error, kill bool) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.terminateLocked(cause, kill)
}

// terminateLocked は、バッファを破棄し、Closed を通知する。後始末（接続の切断）は、見張りのゴルーチンが行う。
// すでに終了していれば、何もせず、false。
func (p *Publisher) terminateLocked(cause error, kill bool) bool {
	if p.state == stateClosed {
		return false
	}
	p.state = stateClosed
	p.cause = cause
	p.kill = kill
	p.queue = nil
	p.queuedBytes = 0
	close(p.closed)
	return true
}

// fail は、接続の失敗（書き込みの失敗・接続の切断）を理由に、Publisher を終了させる。最初の原因だったときだけ、失敗の種類を
// 記録する（自分で接続を壊したあとの、書き込みの失敗は、記録しない）。
func (p *Publisher) fail(cause error) {
	if p.terminate(p.classifyFailure(cause), true) {
		p.log.Warn("rtmps connection error", failureAttrs(cause)...)
	}
}

// classifyFailure は、接続の失敗を分類する。publish を送ってから窓（PublishRejectWindow）の内なら、配信キーの不正・使用中の
// 可能性として ErrPublishRejected、それ以降は ErrDisconnected（どちらも、原因を包む）。
func (p *Publisher) classifyFailure(cause error) error {
	if time.Since(p.publishedAt) < p.cfg.PublishRejectWindow {
		return fmt.Errorf("%w: %w", ErrPublishRejected, cause)
	}
	return fmt.Errorf("%w: %w", ErrDisconnected, cause)
}

// writeLoop は、送出キューを、積んだ順に、sink へ書く（単一のゴルーチン）。
func (p *Publisher) writeLoop() {
	defer close(p.writerDone)
	for {
		next, ok := p.nextItem()
		if !ok {
			return
		}
		if err := p.write(next); err != nil {
			p.fail(err)
			return
		}
		p.noteSent(next)
	}
}

// nextItem は、次に送るものを返す。キューが空なら、積まれるのを待つ。終了していれば、または、閉じている最中にキューが空になれば、
// false（後者は、送り切ったので、clean な終了にする）。
func (p *Publisher) nextItem() (item, bool) {
	for {
		p.mu.Lock()
		switch {
		case p.state == stateClosed:
			p.mu.Unlock()
			return item{}, false
		case len(p.queue) > 0:
			next := p.queue[0]
			p.queue[0] = item{} // 送ったものの本文を、先頭の参照から外す
			p.queue = p.queue[1:]
			p.queuedBytes -= len(next.payload)
			p.mu.Unlock()
			return next, true
		case p.state == stateDraining:
			p.terminateLocked(ErrClosed, false)
			p.mu.Unlock()
			return item{}, false
		}
		p.mu.Unlock()
		select {
		case <-p.wake:
		case <-p.closed:
		}
	}
}

func (p *Publisher) write(next item) error {
	switch next.kind {
	case kindVideo:
		return p.sink.writeVideo(next.ts, next.payload)
	case kindAudio:
		return p.sink.writeAudio(next.ts, next.payload)
	default:
		return p.sink.writeMeta(next.payload)
	}
}

// noteSent は、1 件を送ったことを記録する（最後に送った時刻・送った量）。
func (p *Publisher) noteSent(sent item) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.sentBytes += uint64(len(sent.payload))
	if sent.kind != kindMeta && sent.ts > p.lastSentMs {
		p.lastSentMs = sent.ts
	}
}

// monitor は、接続の切断を見張り（go-rtmp は、切断を通知しないため、一定の間隔で、接続の状態を見る）、終了したら、後始末を行う。
func (p *Publisher) monitor() {
	defer close(p.done)
	ticker := time.NewTicker(p.cfg.PollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			if err := p.sink.connectionError(); err != nil {
				p.fail(err)
			}
		case <-p.closed:
			p.teardown()
			return
		}
	}
}

// teardown は、後始末を行う。失敗・Abort・期限切れなら、先に接続を壊して、止まっている書き込みを解く。送り切った Close は、
// 壊さずに、書き込み中のものを待って、おだやかに閉じる（受け口が閉じるのを待つ）。そのあと、書き込みのゴルーチンの終了を待つ。
func (p *Publisher) teardown() {
	p.mu.Lock()
	kill := p.kill
	cause := p.cause
	p.mu.Unlock()

	if kill {
		p.sink.kill()
	}
	closeErr := p.sink.close()
	<-p.writerDone

	p.mu.Lock()
	p.closeErr = closeErr
	p.mu.Unlock()

	level := slog.LevelInfo
	if errors.Is(cause, ErrClosed) {
		level = slog.LevelDebug
	}
	p.log.Log(context.Background(), level, "rtmps publisher stopped", slog.String("cause", causeLabel(cause)), slog.Bool("killed", kill))
}

// causeLabel は、終了の原因を、決まった語彙で返す（ログ用。取り込み先のホスト名・IP アドレスを含み得る、原因の文言を、ログへ出さない）。
func causeLabel(cause error) string {
	switch {
	case cause == nil:
		return "none"
	case errors.Is(cause, ErrBufferOverflow):
		return "buffer_overflow"
	case errors.Is(cause, ErrPublishRejected):
		return "publish_rejected"
	case errors.Is(cause, ErrDisconnected):
		return "disconnected"
	case errors.Is(cause, ErrDrainTimeout):
		return "drain_timeout"
	case errors.Is(cause, ErrClosed):
		return "closed"
	default:
		return "error"
	}
}

// String は、状態の要約を返す（配信キー・取り込み先・接続の中身を含まない）。
func (p *Publisher) String() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return fmt.Sprintf("rtmps.Publisher{state=%s pending=%dms sent=%dB}", p.state, p.pendingLocked(), p.sentBytes)
}

// GoString は、String と同じ（%#v でも、中身を出さない）。
func (p *Publisher) GoString() string { return p.String() }
