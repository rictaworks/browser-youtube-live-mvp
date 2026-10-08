package session

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/frame"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
)

// 接続（WebSocket 1 本）の受け口の試験。接続通知（hello）の期限・照合・照合前のメッセージの破棄・プロトコル違反・検証エラー。
// 契約 ws-protocol.md の 1・4・4.1 章、requirements.md 11.9。

func TestHelloTimesOutAfterTenSeconds(t *testing.T) {
	h := newHarness(t)
	conn := h.connect()

	h.clock.Advance(10*time.Second - time.Millisecond)
	expectSequence(t, conn.link) // 9.999 秒では、まだ切らない

	h.clock.Advance(time.Millisecond)
	expectSequence(t, conn.link, "fatal:hello_timeout", "close:1000")
	if got := h.be.verifies(); len(got) != 0 {
		t.Fatalf("the backend was called without a hello: %v", got)
	}
	if h.reg.Count() != 0 {
		t.Fatalf("Count = %d", h.reg.Count())
	}
}

func TestHelloCancelsTheTimeout(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	h.clock.Advance(9 * time.Second)
	conn.hello("t1")
	h.settle()

	h.clock.Advance(30 * time.Second) // 接続通知の期限は、とうに過ぎた
	h.settle()
	for _, entry := range conn.link.sequence(t) {
		if strings.HasPrefix(entry, "fatal") || strings.HasPrefix(entry, "close") {
			t.Fatalf("the connection was closed: %v", conn.link.sequence(t))
		}
	}
}

func TestDisconnectBeforeHelloStopsTheTimer(t *testing.T) {
	h := newHarness(t)
	conn := h.connect()
	conn.conn.Disconnected()
	if n := h.clock.activeTimers(); n != 0 {
		t.Fatalf("%d timers remain after the connection closed", n)
	}
	h.clock.Advance(time.Minute)
	expectSequence(t, conn.link) // 切断のあとは、何も送らない
}

func TestAcceptedAfterAValidHello(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()

	expectSequence(t, conn.link, "accepted")
	accepted := conn.link.ofType(t, contract.FrameTypeAccepted)[0]
	assertBodyJSON(t, accepted, `{"state":"reserved","resume":false,"profile":null,"limits":{"time_limit_seconds":3600}}`)
	if h.reg.Count() != 1 {
		t.Fatalf("Count = %d, want 1", h.reg.Count())
	}
	session := h.mustSession(idA)
	if session.State() != StateVerified || session.Epoch() != 1 || session.BroadcastID() != idA || session.AccountKey() != accountX {
		t.Fatalf("session = state %v epoch %d id %s", session.State(), session.Epoch(), session.BroadcastID())
	}
	if got := h.be.verifies(); len(got) != 1 || got[0] != "t1" {
		t.Fatalf("verify calls = %v", got)
	}
}

func TestAcceptedForAResumedBroadcastCarriesTheProfile(t *testing.T) {
	h := newHarness(t)
	conn := h.resumeConnect("t1", idA, 4, contract.BroadcastStateLive)
	expectSequence(t, conn.link, "accepted")
	assertBodyJSON(t, conn.link.ofType(t, contract.FrameTypeAccepted)[0], `{"state":"live","resume":true,"profile":"720p","limits":{"time_limit_seconds":3600}}`)
	// 中継の再起動後など、取り込みセッションが存在しない場合は、新たに作る。復帰の状態から始める
	if got := h.mustSession(idA).State(); got != StateInterrupted {
		t.Fatalf("state = %v, want interrupted (a session created for a resume waits for the keyframe)", got)
	}
}

func TestInvalidTicketIsFatal(t *testing.T) {
	h := newHarness(t)
	conn := h.connect()
	conn.hello("unknown-ticket")
	h.settle()
	expectSequence(t, conn.link, "fatal:invalid_ticket", "close:1000")
	if h.reg.Count() != 0 {
		t.Fatalf("Count = %d, want 0 (no session for an invalid ticket)", h.reg.Count())
	}
}

func TestVerificationFailuresAreFatalWithTheirCodes(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want string
	}{
		{"無効なチケット", fmt.Errorf("%w", backend.ErrTicketInvalid), "fatal:invalid_ticket"},
		{"終了済み・状態が不適", fmt.Errorf("%w", backend.ErrBroadcastNotAttachable), "fatal:broadcast_ended"},
		{"アプリケーションへ到達できない・5xx", unreachable(), "fatal:internal_error"},
		{"認証の失敗（設定の誤り）", fmt.Errorf("%w", backend.ErrUnauthorized), "fatal:internal_error"},
		{"入力の不備", fmt.Errorf("%w", backend.ErrInvalidInput), "fatal:internal_error"},
		{"応答の不備", fmt.Errorf("%w", backend.ErrInvalidResponse), "fatal:internal_error"},
		{"想定外のステータス", fmt.Errorf("%w", backend.ErrUnexpectedStatus), "fatal:internal_error"},
		{"未知のエラー", fmt.Errorf("boom"), "fatal:internal_error"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newHarness(t)
			h.be.failTicket("t1", c.err)
			conn := h.connect()
			conn.hello("t1")
			h.settle()
			expectSequence(t, conn.link, c.want, "close:1000")
			if h.reg.Count() != 0 {
				t.Fatalf("Count = %d", h.reg.Count())
			}
		})
	}
}

func TestMalformedTicketIsInvalidWithoutCallingTheBackend(t *testing.T) {
	cases := []struct {
		name   string
		ticket string
	}{
		{"空", ""},
		{"空白を含む", "abc def"},
		{"改行を含む", "abc\ndef"},
		{"非 ASCII", "abcé"},
		{"長すぎる", strings.Repeat("a", backend.MaxTicketBytes+1)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newHarness(t)
			conn := h.connect()
			conn.hello(c.ticket)
			h.settle()
			expectSequence(t, conn.link, "fatal:invalid_ticket", "close:1000")
			if got := h.be.verifies(); len(got) != 0 {
				t.Fatalf("the backend was called with a malformed ticket (%d calls)", len(got))
			}
		})
	}
}

func TestMessagesBeforeHelloAreDiscarded(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()

	conn.probe(1000)
	conn.start("720p")
	conn.video(0, true, videoPayload(1, 100))
	conn.audio(0, audioPayload(2, 50))
	conn.report(reportJSON(`[]`))
	conn.end("user_stop")
	h.settle()

	expectSequence(t, conn.link) // 何も返さず、切断もしない
	if got := h.be.verifies(); len(got) != 0 || len(h.be.provisions()) != 0 {
		t.Fatalf("the backend was called by messages before hello: verify %v provision %v", got, h.be.provisions())
	}
	if h.reg.Count() != 0 || len(h.ev.all()) != 0 {
		t.Fatalf("a session or an event was created by messages before hello")
	}

	// そのあとの hello は、通常どおり
	conn.hello("t1")
	h.settle()
	expectSequence(t, conn.link, "accepted")
}

func TestMessagesDuringVerificationAreDiscarded(t *testing.T) {
	h := newHarness(t)
	h.be.verifyGate = make(chan struct{})
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	<-h.be.verifyEntered // 照合の呼び出しの最中

	conn.probe(1000)
	conn.start("720p")
	conn.end("user_stop")
	close(h.be.verifyGate)
	h.settle()

	expectSequence(t, conn.link, "accepted")
	if got := h.be.provisions(); len(got) != 0 {
		t.Fatalf("a start sent during verification was processed: %v", got)
	}
	if got := h.mustSession(idA).State(); got != StateVerified {
		t.Fatalf("state = %v: messages sent during verification must not change it", got)
	}
}

func TestSecondHelloIsAProtocolViolation(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()

	conn.hello("t1")
	h.settle()
	expectSequence(t, conn.link, "accepted", "fatal:protocol_violation", "close:1000")
	if got := len(h.be.verifies()); got != 1 {
		t.Fatalf("verify calls = %d: a second hello must not be verified", got)
	}
	// 接続が切れたので、取り込みセッションは、送信元を失う（配信の終了ではない）
	if h.mustSession(idA).State() == StateClosed {
		t.Fatal("the session was closed by a protocol violation of its connection")
	}
}

func TestSecondHelloWhileVerifyingIsAProtocolViolation(t *testing.T) {
	h := newHarness(t)
	h.be.verifyGate = make(chan struct{})
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	<-h.be.verifyEntered
	conn.hello("t1")
	close(h.be.verifyGate)
	h.settle()

	if got := conn.link.sequence(t); len(got) < 2 || got[0] != "fatal:protocol_violation" || got[1] != "close:1000" {
		t.Fatalf("link sequence = %v, want the protocol violation first", got)
	}
}

func TestTextMessageIsAProtocolViolation(t *testing.T) {
	h := newHarness(t)
	conn := h.connect()
	conn.conn.HandleText()
	expectSequence(t, conn.link, "fatal:protocol_violation", "close:1000")
	if n := h.clock.activeTimers(); n != 0 {
		t.Fatalf("%d timers remain after the connection was closed", n)
	}
}

func TestTextMessageAfterHelloIsAProtocolViolation(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	conn.conn.HandleText()
	h.settle()
	expectSequence(t, conn.link, "accepted", "fatal:protocol_violation", "close:1000")
}

func TestOversizeMessageIsFatalAndClosesWith1009(t *testing.T) {
	h := newHarness(t)
	conn := h.connect()
	// 2 MiB を超えるメッセージ（#21 が、読み取りの段階で数える）
	conn.conn.HandleOversize()
	expectSequence(t, conn.link, "fatal:message_too_large", fmt.Sprintf("close:%d", CloseMessageTooBig))
}

func TestOversizeMessageBytesAreDetectedByTheFrameCheck(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()

	// ヘッダの本文長が上限を超える（本文は付けない。ws-frame-vectors.json の too_large と同じ）
	header := make([]byte, contract.WSFrameHeaderBytes)
	copy(header, []byte{0x42, 0x4C, 0x01, byte(contract.FrameTypeVideo)})
	huge := uint32(contract.WSFrameMaxMessageBytes)
	header[13], header[14], header[15], header[16] = byte(huge>>24), byte(huge>>16), byte(huge>>8), byte(huge)
	conn.conn.Handle(header)
	h.settle()
	expectSequence(t, conn.link, "accepted", "fatal:message_too_large", fmt.Sprintf("close:%d", CloseMessageTooBig))
}

func TestExactlyTheLimitIsNotTooLarge(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()

	// 全体が 2,097,152 バイトちょうどの probe は、受理される（計測データとして数える）
	conn.probe(contract.WSFrameMaxMessageBytes - contract.WSFrameHeaderBytes)
	h.settle()
	expectSequence(t, conn.link, "accepted")
}

func TestInvalidFramesAreDiscardedAndTheConnectionContinues(t *testing.T) {
	good, err := frame.Encode(frame.Frame{Type: contract.FrameTypeProbe, Body: []byte("x")})
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	badMagic := append([]byte(nil), good...)
	badMagic[0] = 0x00
	badVersion := append([]byte(nil), good...)
	badVersion[2] = 2
	unknownType := append([]byte(nil), good...)
	unknownType[3] = 0x55
	wrongDirection := append([]byte(nil), good...)
	wrongDirection[3] = byte(contract.FrameTypeAck)
	lengthMismatch := append([]byte(nil), good...)
	lengthMismatch[16] = 9
	truncated := good[:5]

	cases := []struct {
		name    string
		message []byte
	}{
		{"ヘッダに満たない", truncated},
		{"空", nil},
		{"識別子の誤り", badMagic},
		{"版の誤り", badVersion},
		{"未知の種別", unknownType},
		{"方向の誤り（中継 → ブラウザの種別）", wrongDirection},
		{"本文長の不一致", lengthMismatch},
	}
	for _, c := range cases {
		t.Run(c.name+"（照合前）", func(t *testing.T) {
			h := newHarness(t)
			conn := h.connect()
			conn.conn.Handle(c.message)
			h.settle()
			expectSequence(t, conn.link) // 破棄して、接続は維持する
		})
		t.Run(c.name+"（照合後）", func(t *testing.T) {
			h := newHarness(t)
			h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
			conn := h.connect()
			conn.hello("t1")
			h.settle()
			conn.conn.Handle(c.message)
			h.settle()
			expectSequence(t, conn.link, "accepted")
			// 破棄したあとも、通常どおり処理される
			conn.probe(1000)
			h.settle()
			if got := h.mustSession(idA).State(); got != StateProbing {
				t.Fatalf("state = %v: the connection must keep working after a discarded frame", got)
			}
		})
	}
}

// メッセージごとのログは出さない（毎秒数十のフレーム）。破棄は数え、2 の冪の回だけ、理由つきで記録する。
func TestDiscardsAreCountedAndLoggedSparsely(t *testing.T) {
	h := newHarness(t)
	conn := h.connect()
	for i := 0; i < 100; i++ {
		conn.conn.Handle([]byte("garbage"))
	}
	lines := 0
	for _, line := range strings.Split(strings.TrimSpace(h.logText()), "\n") {
		if strings.Contains(line, "discard") {
			lines++
			if !strings.Contains(line, "truncated_header") {
				t.Fatalf("a discard log line has no reason: %s", line)
			}
		}
	}
	if lines == 0 {
		t.Fatal("discards are not logged at all")
	}
	if lines > 8 {
		t.Fatalf("%d log lines for 100 discarded messages (the log must not be per message)", lines)
	}
}

func TestUnknownTicketIsNotLogged(t *testing.T) {
	h := newHarness(t)
	conn := h.connect()
	conn.hello(dummyTicket)
	h.settle()
	if strings.Contains(h.logText(), "SECRET") {
		t.Fatalf("the log contains the ticket: %s", h.logText())
	}
}

func TestMessagesAfterTheConnectionClosedAreIgnored(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.conn.Disconnected()
	conn.hello("t1")
	h.settle()
	if got := h.be.verifies(); len(got) != 0 {
		t.Fatalf("a message on a closed connection was processed: %v", got)
	}
}

func TestAcceptIsRefusedWhileShuttingDown(t *testing.T) {
	h := newHarness(t)
	ctx, cancel := contextWithTimeout(t)
	defer cancel()
	if err := h.reg.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown: %v", err)
	}
	if _, err := h.reg.Accept(&fakeLink{}); err != ErrShuttingDown {
		t.Fatalf("Accept error = %v, want ErrShuttingDown", err)
	}
}

func TestShutdownClosesConnectionsStillWaitingForHello(t *testing.T) {
	h := newHarness(t)
	conn := h.connect()
	ctx, cancel := contextWithTimeout(t)
	defer cancel()
	if err := h.reg.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown: %v", err)
	}
	// ブラウザは、internal_error で復帰（再接続）を試みる（ws-protocol.md の 8 章）
	expectSequence(t, conn.link, "fatal:internal_error", "close:1000")
	if n := h.clock.activeTimers(); n != 0 {
		t.Fatalf("%d timers remain", n)
	}
}
