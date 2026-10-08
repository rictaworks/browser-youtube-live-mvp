package session

import (
	"errors"
	"fmt"
	"io"
	"log/slog"
	"sync"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/frame"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
)

// connState は、接続（WebSocket 1 本）の状態。
type connState int

const (
	// connAwaitingHello は、接続通知（hello）待ち。接続から 10 秒以内に hello が無ければ、致命通知 hello_timeout のうえ切断する。
	connAwaitingHello connState = iota + 1
	// connVerifying は、hello を受け、アプリケーションの照合の応答を待っている。照合の完了前に受信したメッセージは破棄する。
	connVerifying
	// connAttached は、照合に成功し、取り込みセッションの送信元になった（または、なろうとしている）。
	connAttached
	// connClosed は、閉じた。
	connClosed
)

// Connection は、ブラウザとの WebSocket の接続 1 本の受け口（#21 の wsapi が、接続ごとに 1 つ持つ）。
//
// 接続の直後から、接続通知（hello）の期限（10 秒）を数える。hello を受けたら、接続チケットを照合し（アプリケーション）、
// 台帳を通して、取り込みセッションの送信元になる。照合の完了前に受信したメッセージは破棄し、hello の 2 回目・テキストの
// メッセージは致命通知 protocol_violation のうえ切断する。長さ・種別・方向の整合に逸脱するメッセージは、破棄して数える
// （接続は維持する）。1 メッセージが 2 MiB を超える接続は、致命通知 message_too_large のうえ、Close コード 1009 で切断する。
//
// Handle・HandleText・HandleOversize・Disconnected は、接続の受信のゴルーチン（1 本）から呼ぶ。
type Connection struct {
	reg  *Registry
	link BrowserLink
	log  *slog.Logger

	mu       sync.Mutex
	state    connState
	hello    Timer
	sess     *IngestSession
	discards map[string]int
}

func newConnection(reg *Registry, link BrowserLink) *Connection {
	c := &Connection{reg: reg, link: link, log: reg.deps.Logger, state: connAwaitingHello, discards: map[string]int{}}
	c.mu.Lock()
	c.hello = reg.deps.Clock.AfterFunc(reg.opts.HelloTimeout, c.onHelloTimeout)
	c.mu.Unlock()
	return c
}

// Handle は、受信した 1 メッセージ（バイナリ。ヘッダ 17 バイト + 本文）を処理する。message の所有は、この接続に移る
// （非同期に処理するので、呼び出し元は、あとで書き換えない）。
func (c *Connection) Handle(message []byte) {
	f, err := frame.Decode(message)
	if err != nil {
		c.onInvalidFrame(err)
		return
	}
	c.mu.Lock()
	state, sess := c.state, c.sess
	c.mu.Unlock()
	switch state {
	case connAwaitingHello:
		if f.Type != contract.FrameTypeHello {
			c.discard("before_hello")
			return
		}
		c.beginVerify(f.Body)
	case connVerifying:
		if f.Type == contract.FrameTypeHello {
			c.fatalAndClose(contract.FatalCodeProtocolViolation, CloseNormal)
			return
		}
		c.discard("before_verified")
	case connAttached:
		if f.Type == contract.FrameTypeHello {
			c.fatalAndClose(contract.FatalCodeProtocolViolation, CloseNormal)
			return
		}
		sess.submit(c, frameMessage{frame: f, wire: len(message)})
	}
}

// HandleText は、テキストのメッセージを受けた（バイナリのみ受理する）。致命通知 protocol_violation のうえ切断する。
func (c *Connection) HandleText() {
	c.fatalAndClose(contract.FatalCodeProtocolViolation, CloseNormal)
}

// HandleOversize は、1 メッセージが上限（2 MiB）を超えた（#21 が、読み取りの段階で、本文を読み切る前に数える）。
// 致命通知 message_too_large のうえ、Close コード 1009 で切断する。
func (c *Connection) HandleOversize() {
	c.fatalAndClose(contract.FatalCodeMessageTooLarge, CloseMessageTooBig)
}

// Disconnected は、WebSocket が閉じた（ブラウザの切断・読み取りの失敗）ことを知らせる。送信元だった接続なら、取り込みセッションは
// 中断として扱う（RTMPS の接続は、中断の期限まで保持する）。何度呼んでもよい。
func (c *Connection) Disconnected() {
	c.mu.Lock()
	already := c.state == connClosed
	c.state = connClosed
	c.stopHelloLocked()
	sess := c.sess
	c.mu.Unlock()
	c.reg.forgetConn(c)
	if !already && sess != nil {
		sess.sourceClosed(c)
	}
}

// onInvalidFrame は、検証に通らなかったメッセージを処理する。大きさの超過は切断。それ以外は、破棄して数え、接続を維持する。
func (c *Connection) onInvalidFrame(err error) {
	code, known := frame.CodeOf(err)
	if known && code == frame.CodeTooLarge {
		c.fatalAndClose(contract.FatalCodeMessageTooLarge, CloseMessageTooBig)
		return
	}
	reason := "invalid_frame"
	if known {
		reason = string(code)
	}
	c.discard(reason)
}

// discard は、メッセージを破棄したことを数える。記録は、2 の冪の回だけ、理由つきで（メッセージごとには出さない）。
func (c *Connection) discard(reason string) {
	c.mu.Lock()
	c.discards[reason]++
	count := c.discards[reason]
	c.mu.Unlock()
	if count&(count-1) == 0 {
		c.log.Warn("message discarded", slog.String("reason", reason), slog.Int("count", count))
	}
}

// beginVerify は、hello の本文（接続チケット）を検査し、照合を始める。チケットとして不正な本文は、アプリケーションを呼ばずに、
// 無効なチケットとして扱う。
func (c *Connection) beginVerify(body []byte) {
	ticket, err := backend.NewTicket(body)
	if err != nil {
		c.fatalAndClose(contract.FatalCodeInvalidTicket, CloseNormal)
		return
	}
	c.mu.Lock()
	if c.state != connAwaitingHello {
		c.mu.Unlock()
		return
	}
	c.state = connVerifying
	c.stopHelloLocked()
	c.mu.Unlock()
	c.reg.verifyAsync(c, ticket)
}

// onVerified は、照合の結果を処理する。成功なら、台帳を通して取り込みセッションの送信元になる。
// 無効なチケットは fatal(invalid_ticket)、終了済み・状態が不適は fatal(broadcast_ended)、到達できない・5xx・想定外は
// fatal(internal_error)（ブラウザは、新しいチケットで再接続する）。どれも、切断する。
func (c *Connection) onVerified(result backend.VerifyResult, err error) {
	switch {
	case err == nil:
		c.reg.attach(c, result)
	case errors.Is(err, backend.ErrTicketInvalid):
		c.fatalAndClose(contract.FatalCodeInvalidTicket, CloseNormal)
	case errors.Is(err, backend.ErrBroadcastNotAttachable):
		c.fatalAndClose(contract.FatalCodeBroadcastEnded, CloseNormal)
	default:
		c.log.Warn("the ticket could not be verified", slog.String("class", errorClass(err)))
		c.fatalAndClose(contract.FatalCodeInternalError, CloseNormal)
	}
}

// onHelloTimeout は、接続から接続通知の期限が経った。hello が無ければ、致命通知 hello_timeout のうえ切断する。
func (c *Connection) onHelloTimeout() {
	c.mu.Lock()
	waiting := c.state == connAwaitingHello
	c.mu.Unlock()
	if waiting {
		c.fatalAndClose(contract.FatalCodeHelloTimeout, CloseNormal)
	}
}

// stopHelloLocked は、接続通知の期限のタイマーを止める（c.mu を持って呼ぶ）。
func (c *Connection) stopHelloLocked() {
	if c.hello != nil {
		c.hello.Stop()
		c.hello = nil
	}
}

// markAttached は、取り込みセッションの送信元になったことを記録する（accepted を送る前に呼ぶ）。
func (c *Connection) markAttached(s *IngestSession) {
	c.mu.Lock()
	c.sess = s
	if c.state != connClosed {
		c.state = connAttached
	}
	c.mu.Unlock()
	c.reg.forgetConn(c)
}

func (c *Connection) isClosed() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.state == connClosed
}

// fatalAndClose は、致命通知を送り、接続を閉じる。送信元だった接続なら、取り込みセッションへ知らせる（中断として扱う）。
func (c *Connection) fatalAndClose(code contract.FatalCode, closeCode int) {
	c.mu.Lock()
	if c.state == connClosed {
		c.mu.Unlock()
		return
	}
	c.state = connClosed
	c.stopHelloLocked()
	sess := c.sess
	c.mu.Unlock()
	c.reg.forgetConn(c)
	c.sendFatal(code)
	c.link.Close(closeCode)
	if sess != nil {
		sess.sourceClosed(c)
	}
}

// shutdownLink は、取り込みセッション（のループ）が、この接続へ致命通知を送って閉じる。取り込みセッションへは知らせない
// （すでに知っている。ループから、ループへ積むと、待ち行列が満ちたときに止まる）。
func (c *Connection) shutdownLink(code contract.FatalCode) {
	c.mu.Lock()
	if c.state == connClosed {
		c.mu.Unlock()
		return
	}
	c.mu.Unlock()
	c.sendFatal(code)
	c.closeLink(CloseNormal)
}

// closeLink は、接続を閉じたものにして、リンクを閉じる。
func (c *Connection) closeLink(code int) {
	c.mu.Lock()
	c.state = connClosed
	c.stopHelloLocked()
	c.mu.Unlock()
	c.reg.forgetConn(c)
	c.link.Close(code)
}

func (c *Connection) sendFatal(code contract.FatalCode) {
	message, err := encodeFatal(code)
	if err != nil {
		c.log.Error("a fatal message could not be encoded", slog.String("class", errorClass(err)))
		return
	}
	_ = c.link.Send(message)
}

// String は、接続の状態だけを示す。
func (c *Connection) String() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return fmt.Sprintf("session.Connection{state=%d}", c.state)
}

// GoString は、String と同じ。
func (c *Connection) GoString() string { return c.String() }

// Format は、どの書式動詞でも、String だけを書く。
func (c *Connection) Format(f fmt.State, _ rune) { _, _ = io.WriteString(f, c.String()) }
