package wsapi

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"sync"

	"github.com/gorilla/websocket"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/session"
)

// Connection は、WebSocket の接続 1 本を受ける側（*session.Connection が満たす）。
type Connection interface {
	// Handle は、受信した 1 メッセージ（バイナリ）を処理する。message の所有は、Connection に移る。
	Handle(message []byte)
	// HandleText は、テキストのメッセージを受けた（バイナリのみ受理する）。
	HandleText()
	// HandleOversize は、1 メッセージが上限を超えた。
	HandleOversize()
	// Disconnected は、WebSocket が閉じた。
	Disconnected()
}

// Acceptor は、WebSocket の接続を受け付ける（セッション台帳）。link は、その接続への送信と切断。
// 停止の手順に入っていて受け付けられなければ、エラー（接続は、Going Away で閉じる）。
type Acceptor interface {
	Accept(link session.BrowserLink) (Connection, error)
}

// registryAcceptor は、*session.Registry を Acceptor にしたもの。
type registryAcceptor struct {
	registry *session.Registry
}

// RegistryAcceptor は、セッション台帳を、WebSocket の受け口が使う Acceptor にする。
func RegistryAcceptor(registry *session.Registry) Acceptor {
	return registryAcceptor{registry: registry}
}

func (a registryAcceptor) Accept(link session.BrowserLink) (Connection, error) {
	conn, err := a.registry.Accept(link)
	if err != nil {
		return nil, err
	}
	return conn, nil
}

// Handler は、WebSocket の受け口（GET /ws。requirements.md 6.1・11.9）。http.Handler。
//
// 接続ごとに、書き込み役のゴルーチン（link）と、受信の繰り返し（このハンドラのゴルーチン）の 2 つだけを使う。再エンコードをしない
// ので、処理量は接続数に対して線形で小さい（27 章）。受信は、1 メッセージずつ読み、セッションの接続（Connection）へ渡す。
// 照合・メッセージの検証・破棄は、セッション側の役目。ここは、読み取りの段階の制限だけを課す：
//   - バイナリのみ受理する。テキストは HandleText（致命通知 protocol_violation のうえ切断）
//   - 1 メッセージの大きさの上限（2,097,152 バイト）。SetReadLimit は使わない（超過した時点で、ライブラリが Close コード 1009 を
//     送って終わり、致命通知 message_too_large を先に送れない）。自前で数え、上限 + 1 バイトを読んだ時点で HandleOversize
//     （致命通知のうえ、Close コード 1009）。残りは読まない
//   - 接続通知（hello）の期限（10 秒）は、セッション側が、同じ時計で数える
type Handler struct {
	acceptor Acceptor
	opts     Options
	log      *slog.Logger
	upgrader websocket.Upgrader

	wg sync.WaitGroup

	mu       sync.Mutex
	draining bool
	active   int
	accepted int
	links    map[*link]struct{}
}

// NewHandler は、WebSocket の受け口を作る。acceptor が nil、時計かロガーが無い（ErrInvalidDeps）、設定が不正（ErrInvalidOptions）なら、エラー。
func NewHandler(acceptor Acceptor, opts Options) (*Handler, error) {
	if acceptor == nil {
		return nil, fmt.Errorf("%w: the acceptor is required", ErrInvalidDeps)
	}
	normalized, err := opts.normalized()
	if err != nil {
		return nil, err
	}
	return &Handler{
		acceptor: acceptor,
		opts:     normalized,
		log:      normalized.Logger,
		links:    map[*link]struct{}{},
		upgrader: websocket.Upgrader{
			HandshakeTimeout: normalized.HandshakeTimeout,
			ReadBufferSize:   bufferBytes,
			WriteBufferSize:  bufferBytes,
			// 接続元の Origin を検査しない（常に許可する）。理由：
			//   - この口は、Cookie を読まず、設定もしない。認可は、接続の最初のメッセージ（hello）に載せる接続チケットで行う
			//     （1 回限り。60 秒で失効する。照合で消費する。ログイン済みの利用者の画面だけが、同一オリジンの API から受け取る）
			//   - Origin の検査は、ブラウザが自動で付ける資格情報（Cookie など）を、別のサイトのページが使って、
			//     WebSocket を張る攻撃（クロスサイト WebSocket ハイジャック）を防ぐためのもの。この口には、悪用される資格情報が無い
			//   - gorilla/websocket の既定（CheckOrigin が nil）は、Origin のホストが Host と違えば拒否する。フロントエンド（Vercel）と
			//     中継（Railway）は別のオリジンなので、既定のままでは、正しい利用者も接続できない
			//   - 資格情報を持たない接続が中継の資源を使い切ることは、チケットの照合までの破棄・接続通知の期限（10 秒）・
			//     接続数の上限（MaxConnections）・メッセージの大きさの上限で防ぐ
			CheckOrigin: func(*http.Request) bool { return true },
		},
	}, nil
}

// ServeHTTP は、GET /ws を処理する。WebSocket へ切り替え、接続が終わるまで戻らない。
// 停止の手順（BeginDrain）に入っている、または接続数が上限なら、切り替えずに 503。
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if !h.reserve() {
		w.Header().Set("Retry-After", "1")
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	defer h.release()

	conn, err := h.upgrader.Upgrade(w, r, nil)
	if err != nil {
		// 切り替えに失敗した（WebSocket の要求ではない）。応答は、ライブラリが書いた。要求の内容（クエリ・ヘッダ）は記録しない
		h.log.Debug("the WebSocket upgrade was refused", slog.String("class", "upgrade_refused"))
		return
	}
	h.serve(conn)
}

// serve は、切り替え済みの接続 1 本を、終わるまで扱う。
func (h *Handler) serve(ws *websocket.Conn) {
	sock := gorillaSocket{Conn: ws}
	l := newLink(sock, h.opts.Clock, h.opts, h.log)
	// 相手から届くもの（pong・ping）も、生きている印。ping には、既定の処理（pong を返す）も行う
	ws.SetPongHandler(func(string) error {
		l.touch()
		return nil
	})
	pingHandler := ws.PingHandler()
	ws.SetPingHandler(func(data string) error {
		l.touch()
		return pingHandler(data)
	})

	h.track(l)
	defer h.untrack(l)
	defer l.finish()

	conn := h.accept(l)
	h.countAccepted()
	defer func() {
		if conn != nil {
			h.disconnected(conn)
		}
	}()
	h.readLoop(sock, l, conn)
}

// accept は、セッションの台帳へ、接続を渡す。受け付けられなければ（停止の手順など）、Going Away で閉じ、nil。
func (h *Handler) accept(l *link) (conn Connection) {
	defer func() {
		if recovered := recover(); recovered != nil {
			h.log.Error("accepting a connection panicked", slog.String("panic_type", fmt.Sprintf("%T", recovered)))
			l.abort(reasonPanic)
			conn = nil
		}
	}()
	accepted, err := h.acceptor.Accept(l)
	if err != nil {
		h.log.Debug("the session registry refused the connection", slog.String("class", "refused"))
		l.Close(websocket.CloseGoingAway)
		return nil
	}
	return accepted
}

// disconnected は、WebSocket が閉じたことを、セッションへ知らせる（panic は、記録して、続行する）。
func (h *Handler) disconnected(conn Connection) {
	h.callSession(nil, conn.Disconnected)
}

// readLoop は、受信の繰り返し。接続が終わる（読み取りが失敗する）まで、1 メッセージずつ読んで、セッションへ渡す。
// conn が nil（受け付けられなかった）、または閉じる手順に入ったあとは、メッセージの中身を読まず、セッションへ渡さない
// （次の読み取りが、残りを読み捨てる。相手が Close フレームを返すか、接続を閉じるか、待ちの期限で終わる）。
func (h *Handler) readLoop(sock socket, l *link, conn Connection) {
	for {
		kind, reader, err := sock.NextReader()
		if err != nil {
			return
		}
		l.touch()
		if conn == nil || l.closing() {
			continue
		}
		switch kind {
		case websocket.TextMessage:
			if !h.callSession(l, conn.HandleText) {
				return
			}
		case websocket.BinaryMessage:
			message, oversize, readErr := readMessage(reader, h.opts.MaxMessageBytes)
			if readErr != nil {
				return
			}
			if oversize {
				if !h.callSession(l, conn.HandleOversize) {
					return
				}
				continue
			}
			if !h.callSession(l, func() { conn.Handle(message) }) {
				return
			}
		}
	}
}

// callSession は、セッションの処理を呼ぶ。panic は受けて、記録し（値は写さない。秘密値が入り得る）、l があれば接続を落として false。
func (h *Handler) callSession(l *link, call func()) (ok bool) {
	defer func() {
		if recovered := recover(); recovered != nil {
			h.log.Error("the session panicked while handling a connection", slog.String("panic_type", fmt.Sprintf("%T", recovered)))
			if l != nil {
				l.abort(reasonPanic)
			}
			ok = false
		}
	}()
	call()
	return true
}

// ---- 接続の管理 ----

// reserve は、接続を 1 つ受け付ける枠を確保する。停止の手順に入っている、または上限なら false。
func (h *Handler) reserve() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.draining || h.active >= h.opts.MaxConnections {
		return false
	}
	h.active++
	h.wg.Add(1)
	return true
}

func (h *Handler) release() {
	h.mu.Lock()
	h.active--
	h.mu.Unlock()
	h.wg.Done()
}

func (h *Handler) track(l *link) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.links[l] = struct{}{}
}

func (h *Handler) untrack(l *link) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.links, l)
}

// Active は、処理中の接続の数（切り替えの途中を含む）。
func (h *Handler) Active() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.active
}

func (h *Handler) countAccepted() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.accepted++
}

// Accepted は、セッションの台帳まで届いた接続の総数（受け付けられなかったものを含む。WebSocket への切り替えに失敗したものは含まない）。
// 診断と試験のため。
func (h *Handler) Accepted() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.accepted
}

// BeginDrain は、新しい接続を受け付けなくする（以後の要求は 503）。すでにある接続は、そのまま続ける。何度呼んでもよい。
func (h *Handler) BeginDrain() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.draining = true
}

// Wait は、すべての接続の処理が終わるのを待つ。ctx が終わっても残っている接続は、直ちに落として（Close フレームを送らない）、
// 終わるのを待ち、ctx のエラーを返す。戻ったときには、このパッケージのゴルーチンは残らない。
// 先に BeginDrain を呼ぶこと（呼ばないと、待つ間に新しい接続が増え得る）。
func (h *Handler) Wait(ctx context.Context) error {
	done := make(chan struct{})
	go func() {
		defer close(done)
		h.wg.Wait()
	}()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		h.forceClose()
		<-done
		return ctx.Err()
	}
}

// forceClose は、残っているすべての接続を、直ちに落とす。
func (h *Handler) forceClose() {
	h.mu.Lock()
	links := make([]*link, 0, len(h.links))
	for l := range h.links {
		links = append(links, l)
	}
	h.mu.Unlock()
	for _, l := range links {
		l.abort(reasonForced)
	}
}

// String は、接続の数だけを示す（接続の中身を出さない）。
func (h *Handler) String() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return fmt.Sprintf("wsapi.Handler{active=%d draining=%t}", h.active, h.draining)
}

// GoString は、String と同じ。
func (h *Handler) GoString() string { return h.String() }

// Format は、どの書式動詞でも、String だけを書く。
func (h *Handler) Format(f fmt.State, _ rune) { _, _ = io.WriteString(f, h.String()) }
