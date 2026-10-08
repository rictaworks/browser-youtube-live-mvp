package session

import (
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/frame"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
)

// 取り込みセッションの閉じ方：受信量の超過・同時の Close・強制の切断・panic・接続や準備の最中の終了。
// 終了時に、配信キーとバッファを破棄し、ゴルーチンが残らない。

const flood = contract.WSFrameMaxMessageBytes - contract.WSFrameHeaderBytes // 全体が 2,097,152 バイトのメッセージの本文

// wireSize は、フレームを符号化したときの、メッセージ全体の大きさ（バイト）。
func wireSize(t *testing.T, f frame.Frame) int {
	t.Helper()
	message, err := frame.Encode(f)
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	return len(message)
}

func TestExcessiveIngressWhileStreamingDisconnectsAbortsAndBans(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.audio(0, audioPayload(1, 20))
	h.settle()

	// 720p の上限は、映像ビットレートの上限 6,000 kbps の 1.5 倍 = 9,000 kbps = 10 秒で 11,250,000 バイト
	for i := 0; i < 5; i++ {
		s.conn.probe(flood)
	}
	h.settle()
	if s.sess.State() != StateStreaming {
		t.Fatalf("state = %v after 10.5 MB, want streaming", s.sess.State())
	}
	s.conn.probe(flood) // 12.58 MB
	h.settle()
	h.waitDone(s.sess)

	expectSequence(t, s.conn.link, "accepted", "status:awaiting_media", "status:confirming", "fatal:bitrate_exceeded", "close:1000")
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started relay_disconnected session_ended]" {
		t.Fatalf("events = %s", got)
	}
	closes, aborts := s.pub.counts()
	if closes != 0 || aborts != 1 {
		t.Fatalf("publisher: Close %d Abort %d; an offending connection is cut without sending its buffer", closes, aborts)
	}
	again := h.resumeConnect("t2", idA, 2, contract.BroadcastStateLive)
	expectSequence(t, again.link, "fatal:bitrate_exceeded", "close:1000")
}

func TestIngressExactlyAtTheLimitIsNotExcessive(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.audio(0, audioPayload(1, 20))
	for i := 0; i < 5; i++ {
		s.conn.probe(flood)
	}
	// 上限ちょうど（11,250,000 バイト）にする。この接続で、すでに受けたもの（開始通知と音声 1 つ）を引く
	used := wireSize(t, frameOf(contract.FrameTypeStart, startJSON("720p"))) + wireSize(t, frame.Frame{Type: contract.FrameTypeAudio, Body: audioPayload(1, 20)})
	s.conn.probe(11_250_000 - 5*contract.WSFrameMaxMessageBytes - used - contract.WSFrameHeaderBytes)
	h.settle()
	if s.sess.State() != StateStreaming {
		t.Fatalf("state = %v at exactly the limit, want streaming", s.sess.State())
	}
	s.conn.probe(0) // 17 バイトでも、超えれば切る
	h.settle()
	h.waitDone(s.sess)
	if got := s.conn.link.fatals(t); len(got) != 1 || got[0] != "bitrate_exceeded" {
		t.Fatalf("fatal codes = %v", got)
	}
}

func TestIngressOlderThanTenSecondsDoesNotCount(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	for i := 0; i < 5; i++ {
		s.conn.probe(flood)
	}
	h.settle() // 受けた時刻を、時計を進める前に確定させる
	for second := 1; second <= 10; second++ {
		h.clock.Advance(time.Second)
		s.conn.audio(uint64(second)*1_000_000, audioPayload(1, 20))
		s.conn.video(uint64(second)*1_000_000, second == 1, videoPayload(1, 30))
		h.settle()
	}
	for i := 0; i < 5; i++ { // 10 秒前の分は、窓から出ている
		s.conn.probe(flood)
	}
	h.settle()
	if s.sess.State() != StateStreaming {
		t.Fatalf("state = %v: bytes older than the 10-second window must not count", s.sess.State())
	}
}

func TestIngressLimitFollowsTheConfirmedProfile(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	conn.start("480p")
	h.settle()
	h.clock.Advance(h.opts.PublishConfirmWindow)
	h.settle()
	session := h.mustSession(idA)

	// 480p の上限は 2,500 × 1.5 = 3,750 kbps = 10 秒で 4,687,500 バイト。2 メッセージ（4.19 MB）までは届く
	conn.probe(flood)
	conn.probe(flood)
	h.settle()
	if session.State() != StateStreaming {
		t.Fatalf("state = %v after 4.19 MB, want streaming", session.State())
	}
	conn.probe(flood)
	h.settle()
	h.waitDone(session)
	if got := conn.link.fatals(t); len(got) != 1 || got[0] != "bitrate_exceeded" {
		t.Fatalf("fatal codes = %v, want bitrate_exceeded at 6.29 MB for 480p", got)
	}
}

func TestCloseIsIdempotentAndSafeToCallConcurrently(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.sess.Close(CloseReasonShutdown)
			s.conn.conn.Handle([]byte("garbage")) // 閉じている最中の受信も、ブロックしない
		}()
	}
	wg.Wait()
	h.waitDone(s.sess)
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started session_ended]" {
		t.Fatalf("events = %s, want exactly one session_ended", got)
	}
	if closes, aborts := s.pub.counts(); closes != 1 || aborts != 0 {
		t.Fatalf("publisher: Close %d Abort %d", closes, aborts)
	}
	if h.reg.Count() != 0 {
		t.Fatalf("Count = %d", h.reg.Count())
	}
}

func TestAForcedCloseEscalatesAGracefulOneThatDoesNotFinish(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	release := make(chan struct{})
	s.pub.mu.Lock()
	s.pub.closeGate = release // 送り切れない
	s.pub.mu.Unlock()
	defer close(release)

	s.sess.Close(CloseReasonShutdown)
	deadline := time.Now().Add(5 * time.Second)
	for {
		if closes, _ := s.pub.counts(); closes == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the graceful close did not start")
		}
		time.Sleep(time.Millisecond)
	}
	select {
	case <-s.sess.Done():
		t.Fatal("the session finished although the publisher could not drain")
	default:
	}
	s.sess.Close(CloseReasonForced)
	h.waitDone(s.sess)
	if _, aborts := s.pub.counts(); aborts != 1 {
		t.Fatalf("Abort calls = %d, want 1", aborts)
	}
}

// go-rtmp は更新が止まっており、panic が出得る。セッション側で受けて、失敗として扱い、中継全体を落とさない（#19 のレビューの申し送り）。
func TestAPanicInThePublisherIsRecoveredAndClosesOnlyThatSession(t *testing.T) {
	h := newHarness(t)
	other := h.bringUpAs("t2", idB, 1, accountY) // 別のアカウント（先に立ち上げる。立ち上げの時計の進みで、映像の途絶が起きてもよい）
	s := h.bringUp("t1", idA, 1)
	s.pub.setPanicOnWrite()
	s.conn.audio(0, audioPayload(1, 20))
	h.settle()
	h.waitDone(s.sess)

	expectSequence(t, s.conn.link, "accepted", "status:awaiting_media", "status:confirming", "fatal:internal_error", "close:1000")
	if !containsAll(h.logText(), "panic", idA) {
		t.Fatalf("the panic was not logged with the broadcast id: %s", h.logText())
	}
	if h.reg.Count() != 1 || other.sess.State() == StateClosed {
		t.Fatalf("Count = %d, other session %v: the other session must keep running", h.reg.Count(), other.sess.State())
	}
	if closes, aborts := other.pub.counts(); closes+aborts != 0 {
		t.Fatalf("the other session's publisher was stopped (Close %d Abort %d)", closes, aborts)
	}
	if _, aborts := s.pub.counts(); aborts == 0 {
		t.Fatal("the failed publisher was not aborted")
	}
}

func TestClosingWhileDialingAbortsTheConnectionThatCompletesLater(t *testing.T) {
	h := newHarness(t)
	gate := make(chan struct{})
	h.fac.setGate(gate)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	session := h.mustSession(idA)
	conn.start("720p")
	h.barrierAll()
	<-h.fac.entered // 接続の最中

	session.Close(CloseReasonShutdown)
	close(gate)
	h.waitDone(session)
	pubs := h.fac.publishers()
	if len(pubs) != 1 {
		t.Fatalf("publishers = %d", len(pubs))
	}
	if closes, aborts := pubs[0].counts(); closes+aborts == 0 {
		t.Fatal("the connection that completed after the session closed was left open")
	}
	if got := fmt.Sprint(h.ev.kinds()); got != "[session_ended]" {
		t.Fatalf("events = %s", got)
	}
}

func TestClosingWhileProvisioningCancelsTheCall(t *testing.T) {
	h := newHarness(t)
	h.be.provisionGate = make(chan struct{}) // 開かない。取り消しで解ける
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	session := h.mustSession(idA)
	conn.start("720p")
	h.barrierAll()
	<-h.be.provisionEntered

	conn.end("user_cancel")
	h.waitDone(session) // 準備の呼び出しが取り消されて、ゴルーチンが残らない
	if got := h.fac.openCount(); got != 0 {
		t.Fatalf("Open calls = %d", got)
	}
}

func TestSendFailureToTheBrowserIsTreatedAsADisconnect(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.link.failSends(ErrLinkClosed)
	h.clock.Advance(2 * h.opts.AckInterval) // 受領応答を送ろうとして、失敗する
	s.conn.audio(0, audioPayload(1, 20))
	s.conn.video(0, true, videoPayload(1, 20))
	h.settle()
	h.clock.Advance(2 * h.opts.AckInterval)
	h.settle()
	if s.sess.State() != StateInterrupted {
		t.Fatalf("state = %v, want interrupted (the browser link is gone)", s.sess.State())
	}
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started interrupted:browser_disconnected]" {
		t.Fatalf("events = %s", got)
	}
}

func TestMessagesAfterTheSessionFinishedAreIgnoredWithoutBlocking(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.sess.Close(CloseReasonShutdown)
	h.waitDone(s.sess)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 5000; i++ { // 待ち行列の大きさ（既定 1,024）を超えて送っても、止まらない
			s.conn.audio(uint64(i), audioPayload(1, 10))
		}
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Handle blocked on a finished session")
	}
}

func TestEverythingTheSessionHeldIsDroppedWhenItEnds(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.report(reportJSON(`[{"kind":"source_added"}]`))
	s.conn.audio(0, audioPayload(1, 20))
	h.settle()
	s.sess.Close(CloseReasonSuperseded)
	h.waitDone(s.sess)
	if s.sess.key != "" || s.sess.ingestURL != "" || s.sess.pub != nil || s.sess.cfg != nil || s.sess.report != nil || len(s.sess.browserEvents) != 0 {
		t.Fatal("the session still holds the stream key, the destination, the publisher or buffered data after it ended")
	}
}

func TestCloseReasonsAreDistinct(t *testing.T) {
	seen := map[CloseReason]bool{}
	for _, reason := range []CloseReason{CloseReasonSuperseded, CloseReasonShutdown, CloseReasonForced} {
		if reason == "" || seen[reason] || strings.Contains(string(reason), " ") {
			t.Fatalf("close reason %q is empty, duplicated or not a code", reason)
		}
		seen[reason] = true
	}
}

// panickingEvents は、事象を積むと panic する送り先（想定外の失敗の再現）。
type panickingEvents struct{}

func (panickingEvents) Enqueue(string, backend.EventRequest) { panic("event sink: simulated panic") }

// 事象の送り先が panic しても、取り込みセッションは、半端な状態で残らない（台帳から外れ、Done が閉じ、待つ側を止めない）。
func TestAPanicWhileFinishingStillReleasesTheSession(t *testing.T) {
	h := newHarness(t)
	h.replaceEvents(panickingEvents{})
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	session := h.mustSession(idA)
	conn.end("user_stop")
	h.waitDone(session)
	if h.reg.Count() != 0 {
		t.Fatalf("Count = %d: the session stayed registered", h.reg.Count())
	}
	if !containsAll(h.logText(), "panic") {
		t.Fatalf("the panic was not logged: %s", h.logText())
	}
}
