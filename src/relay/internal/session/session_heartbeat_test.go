package session

import (
	"fmt"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
)

// 心拍（requirements.md 11.9・13.2。契約 internal-api.md の heartbeat）の試験。
// 2 秒間隔。応答の指示（継続・停止）と状態の通知を処理する。60 秒応答が得られなければ、中継が自ら送出を止める。

func advanceBy(h *harness, step time.Duration, times int) {
	h.t.Helper()
	for i := 0; i < times; i++ {
		h.clock.Advance(step)
		h.settle()
	}
}

func TestHeartbeatIsSentEveryTwoSeconds(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 4, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()

	h.clock.Advance(2*time.Second - time.Millisecond)
	h.settle()
	if got := len(h.be.heartbeats()); got != 0 {
		t.Fatalf("a heartbeat was sent before 2 seconds (%d)", got)
	}
	h.clock.Advance(time.Millisecond)
	h.settle()
	h.clock.Advance(2 * time.Second)
	h.settle()
	h.clock.Advance(2 * time.Second)
	h.settle()

	beats := h.be.heartbeats()
	if len(beats) != 3 {
		t.Fatalf("heartbeats = %d, want 3", len(beats))
	}
	for i, beat := range beats {
		want := backend.HeartbeatRequest{Epoch: 4, Seq: i + 1}
		if !reflect.DeepEqual(beat, want) {
			t.Fatalf("heartbeat %d = %+v, want %+v (nothing is sent yet; no browser report yet)", i, beat, want)
		}
	}
}

// 送出世代が決まる前（照合の結果を得る前）の取り込みセッションは、心拍を送らない。世代 0 の心拍は、アプリケーションに古い世代と
// 受け取られ、stale_epoch の停止の指示で、取り込みセッションを止めかねない。拍の時刻は進み、連番は使わない。
// 世代が決まったあとの最初の心拍は、その世代・連番 1 で送る。
func TestNoHeartbeatIsSentBeforeTheEpochIsKnown(t *testing.T) {
	h := newHarness(t)
	s := h.newSession(idA, accountX) // 台帳を通さずに作った。照合の結果で送出世代が決まるまで、世代は無い
	if err := h.reg.Register(s); err != nil {
		t.Fatalf("Register: %v", err)
	}
	h.advance(10 * time.Second) // 拍が 5 回来る
	if got := h.be.heartbeats(); len(got) != 0 {
		t.Fatalf("%d heartbeats were sent before the epoch was known: %+v", len(got), got)
	}

	h.be.addTicket("t1", verifyResult(idA, 3, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	expectSequence(t, conn.link, "accepted")
	h.advance(2 * time.Second)

	beats := h.be.heartbeats()
	if len(beats) != 1 {
		t.Fatalf("heartbeats = %d, want 1 (the first beat after the epoch is known)", len(beats))
	}
	if beats[0].Epoch != 3 || beats[0].Seq != 1 {
		t.Fatalf("first heartbeat = epoch %d seq %d, want epoch 3 seq 1 (the sequence number is not used up before the epoch is known)", beats[0].Epoch, beats[0].Seq)
	}
}

// どの心拍も、1 以上の世代で送る（照合の結果の世代を得たあとの心拍は、すべて）。
func TestEveryHeartbeatCarriesAPositiveEpoch(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 5)
	s.conn.conn.Disconnected()
	h.settle()
	h.advance(20 * time.Second)
	beats := h.be.heartbeats()
	if len(beats) == 0 {
		t.Fatal("no heartbeat was sent")
	}
	for i, beat := range beats {
		if beat.Epoch != 5 || beat.Seq != i+1 {
			t.Fatalf("heartbeat %d = epoch %d seq %d, want epoch 5 seq %d", i, beat.Epoch, beat.Seq, i+1)
		}
	}
}

func TestHeartbeatCarriesThePublishingFlagAndTheSentBytes(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	before := len(h.be.heartbeats())

	// 25,000 バイトのタグを 3 つ = 75,000 バイトを、2 秒の間に送出する
	for i := 0; i < 3; i++ {
		s.conn.audio(uint64(i)*23220, audioPayload(byte(i+1), 24_998))
	}
	h.settle()
	h.clock.Advance(2 * time.Second)
	h.settle()

	beats := h.be.heartbeats()
	if len(beats) != before+1 {
		t.Fatalf("heartbeats = %d, want %d", len(beats), before+1)
	}
	last := beats[len(beats)-1]
	if !last.Publishing {
		t.Fatal("publishing = false while the media flows")
	}
	if last.SentBytesDelta != 75_000 {
		t.Fatalf("sent_bytes_delta = %d, want 75000 (what was written since the previous heartbeat)", last.SentBytesDelta)
	}
	if last.OutKbps != 300 { // 75,000 バイト × 8 ÷ 2,000 ミリ秒
		t.Fatalf("out_kbps = %d, want 300", last.OutKbps)
	}
	// 積算は、Publisher が書いた量と一致する（月次の送信転送量に使う）
	var total uint64
	for _, beat := range beats {
		total += beat.SentBytesDelta
	}
	if total != s.pub.SentBytes() {
		t.Fatalf("sum of sent_bytes_delta = %d, publisher wrote %d", total, s.pub.SentBytes())
	}
	// 連番は 1 ずつ増える
	for i, beat := range beats {
		if beat.Seq != i+1 {
			t.Fatalf("heartbeat %d has seq %d", i, beat.Seq)
		}
	}
}

func TestHeartbeatDoesNotCountBytesOfAReplacedPublisherTwice(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.audio(0, audioPayload(1, 998))
	h.settle()
	s.pub.terminate(rtmpsDisconnected())
	h.settle()
	h.clock.Advance(2 * time.Second)
	h.settle()
	h.clock.Advance(2 * time.Second)
	h.settle()
	var total uint64
	for _, beat := range h.be.heartbeats() {
		total += beat.SentBytesDelta
	}
	var written uint64
	for _, pub := range h.fac.publishers() {
		written += pub.SentBytes()
	}
	if total != written {
		t.Fatalf("sum of sent_bytes_delta = %d, but the publishers wrote %d in total", total, written)
	}
}

func TestHeartbeatReportsPublishingFalseWhileInterrupted(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.conn.Disconnected() // タブを閉じた
	h.settle()
	h.clock.Advance(2 * time.Second)
	h.settle()
	beats := h.be.heartbeats()
	if len(beats) == 0 {
		t.Fatal("no heartbeat while the browser is away (the control plane must keep hearing from the relay)")
	}
	if beats[len(beats)-1].Publishing {
		t.Fatal("publishing = true while no media flows; the application would take it for a resume")
	}
}

func TestOnlyOneHeartbeatIsInFlight(t *testing.T) {
	h := newHarness(t)
	h.be.heartbeatGate = make(chan struct{})
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()

	h.clock.Advance(2 * time.Second)
	h.barrierAll()
	<-h.be.heartbeatEntered
	for i := 0; i < 3; i++ { // 応答の無い間に、次の拍が来ても、重ねて送らない
		h.clock.Advance(2 * time.Second)
		h.barrierAll()
	}
	if got := len(h.be.heartbeats()); got != 1 {
		t.Fatalf("heartbeats in flight = %d, want 1", got)
	}
	close(h.be.heartbeatGate)
	h.settle()
	h.clock.Advance(2 * time.Second)
	h.settle()
	if got := len(h.be.heartbeats()); got != 2 {
		t.Fatalf("heartbeats = %d, want 2 after the answer arrived", got)
	}
	if h.be.heartbeats()[1].Seq != 2 {
		t.Fatalf("seq = %d, want 2", h.be.heartbeats()[1].Seq)
	}
}

// ---- ブラウザの状態報告 ----

func TestBrowserReportIsCarriedByTheNextHeartbeatWithoutLosingEvents(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()

	conn.report(reportJSON(`[{"kind":"source_added","detail":{"source":"camera"}},{"kind":"bitrate_down","detail":{"from_kbps":4500,"to_kbps":3150}}]`,
		func(m map[string]string) {
			m["backlog"] = "100"
			m["dropped"] = "0"
			m["target"] = "3150"
			m["state"] = `"live"`
		}))
	conn.report(reportJSON(`[{"kind":"video_dropped","detail":{"frames":7}}]`,
		func(m map[string]string) {
			m["backlog"] = "1900"
			m["dropped"] = "7"
			m["target"] = "3000"
			m["state"] = `"degraded"`
		}))
	h.settle()
	h.clock.Advance(2 * time.Second)
	h.settle()

	beats := h.be.heartbeats()
	if len(beats) != 1 || beats[0].Browser == nil {
		t.Fatalf("heartbeats = %+v", beats)
	}
	report := beats[0].Browser
	// 最新の値と、前回の心拍以降の出来事すべて（順序どおり）
	if report.BacklogMs != 1900 || report.DroppedVideoFrames != 7 || report.TargetKbps != 3000 || report.State != contract.StudioStateDegraded {
		t.Fatalf("report = %+v, want the latest values", report)
	}
	var kinds []string
	for _, event := range report.Events {
		kinds = append(kinds, string(event.Kind))
	}
	if got := strings.Join(kinds, ","); got != "source_added,bitrate_down,video_dropped" {
		t.Fatalf("events = %s", got)
	}
	if string(report.Events[1].Detail) != `{"from_kbps":4500,"to_kbps":3150}` {
		t.Fatalf("detail = %s", report.Events[1].Detail)
	}

	// 届いた出来事は、次の心拍に載せない。報告の値は、載せ続ける
	h.clock.Advance(2 * time.Second)
	h.settle()
	second := h.be.heartbeats()[1].Browser
	if second == nil || len(second.Events) != 0 || second.BacklogMs != 1900 {
		t.Fatalf("second heartbeat browser = %+v, want the same values and no events", second)
	}
}

func TestUnansweredHeartbeatIsResentIdenticallyAndEventsAreNotLost(t *testing.T) {
	h := newHarness(t)
	var calls atomic.Int32
	h.be.setHeartbeat(func(backend.HeartbeatRequest) (backend.HeartbeatResponse, error) {
		if calls.Add(1) <= 3 {
			return backend.HeartbeatResponse{}, unreachable()
		}
		return backend.HeartbeatResponse{Command: backend.CommandContinue}, nil
	})
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()

	conn.report(reportJSON(`[{"kind":"source_added","detail":{"source":"camera"}}]`))
	h.settle()
	advanceBy(h, 2*time.Second, 1) // 1 回目（失敗）
	conn.report(reportJSON(`[{"kind":"source_lost","detail":{"source":"camera"}}]`, func(m map[string]string) { m["backlog"] = "55" }))
	h.settle()
	advanceBy(h, 2*time.Second, 2) // 同じ連番・同じ内容の再送が 2 回（どちらも失敗）
	advanceBy(h, 2*time.Second, 1) // 4 回目の再送が成功
	advanceBy(h, 2*time.Second, 1) // 次の心拍（新しい連番）

	beats := h.be.heartbeats()
	if len(beats) < 5 {
		t.Fatalf("heartbeats = %d, want at least 5", len(beats))
	}
	for i := 1; i < 4; i++ {
		if !reflect.DeepEqual(beats[0], beats[i]) {
			t.Fatalf("resend %d differs from the first request:\n%+v\n%+v", i, beats[i], beats[0])
		}
	}
	if beats[0].Seq != 1 || beats[0].Browser == nil || len(beats[0].Browser.Events) != 1 || beats[0].Browser.Events[0].Kind != contract.BrowserEventKindSourceAdded {
		t.Fatalf("first request = %+v", beats[0])
	}
	// 成功のあとの次の心拍は、連番が 1 進み、再送のあいだに届いた出来事だけを載せる
	next := beats[4]
	if next.Seq != 2 || next.Browser == nil || len(next.Browser.Events) != 1 || next.Browser.Events[0].Kind != contract.BrowserEventKindSourceLost {
		t.Fatalf("next request = %+v, want seq 2 carrying only the event that arrived during the resends", next)
	}
	if next.Browser.BacklogMs != 55 {
		t.Fatalf("next request backlog = %d, want the latest report's 55", next.Browser.BacklogMs)
	}
}

func TestBrowserEventsAreBoundedAndDropTheOldest(t *testing.T) {
	h := newHarness(t, func(o *Options) { o.MaxBrowserEvents = 3 })
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	for i := 1; i <= 5; i++ {
		conn.report(reportJSON(fmt.Sprintf(`[{"kind":"video_dropped","detail":{"frames":%d}}]`, i)))
	}
	h.settle()
	h.clock.Advance(2 * time.Second)
	h.settle()
	events := h.be.heartbeats()[0].Browser.Events
	if len(events) != 3 || string(events[0].Detail) != `{"frames":3}` || string(events[2].Detail) != `{"frames":5}` {
		t.Fatalf("events = %+v, want the newest three", events)
	}
}

func TestInvalidReportIsDiscardedWholly(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	conn.report(`{"backlog_ms":-1,"dropped_video_frames":0,"target_kbps":3000,"state":"live","events":[{"kind":"source_added"}]}`)
	conn.report("not json")
	h.settle()
	h.clock.Advance(2 * time.Second)
	h.settle()
	if beats := h.be.heartbeats(); len(beats) != 1 || beats[0].Browser != nil {
		t.Fatalf("heartbeats = %+v: an invalid report must not reach the application, not even its events", beats)
	}
}

// ---- 応答の指示と通知 ----

func TestHeartbeatNoticesAreForwardedAsStatus(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	h.be.setHeartbeat(func(backend.HeartbeatRequest) (backend.HeartbeatResponse, error) {
		return backend.HeartbeatResponse{Command: backend.CommandContinue, Notices: []backend.Notice{
			{State: contract.BroadcastStateLive},
			{State: contract.BroadcastStateLive, Warning: backend.WarningYouTubeStreamUnhealthy},
			{State: contract.BroadcastStateLive, WatchURL: "https://www.youtube.com/watch?v=other", TimeLimitNoticeSeconds: 300},
		}}, nil
	})
	h.clock.Advance(2 * time.Second)
	h.settle()

	statuses := s.conn.link.ofType(t, contract.FrameTypeStatus)
	if len(statuses) != 5 { // awaiting_media・confirming と、通知 3 つ
		t.Fatalf("status count = %d, want 5", len(statuses))
	}
	// 視聴 URL は、準備の完了後は、以降のすべての status に載せる（通知が持たなければ、中継が知っている値）
	assertBodyJSON(t, statuses[2], `{"state":"live","watch_url":"`+dummyWatchURL+`","warning":null,"time_limit_notice_seconds":null,"end_reason":null}`)
	assertBodyJSON(t, statuses[3], `{"state":"live","watch_url":"`+dummyWatchURL+`","warning":"youtube_stream_unhealthy","time_limit_notice_seconds":null,"end_reason":null}`)
	assertBodyJSON(t, statuses[4], `{"state":"live","watch_url":"https://www.youtube.com/watch?v=other","warning":null,"time_limit_notice_seconds":300,"end_reason":null}`)
	if s.sess.State() != StateStreaming {
		t.Fatalf("state = %v: notices do not stop the session", s.sess.State())
	}
}

func TestHeartbeatStopWithAnEndReasonStopsGracefully(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	h.be.setHeartbeat(func(backend.HeartbeatRequest) (backend.HeartbeatResponse, error) {
		return backend.HeartbeatResponse{Command: backend.CommandStop, EndReason: contract.EndReasonTimeLimit, Notices: []backend.Notice{
			{State: contract.BroadcastStateEnded, EndReason: contract.EndReasonTimeLimit},
		}}, nil
	})
	h.clock.Advance(2 * time.Second)
	h.settle()
	h.waitDone(s.sess)

	// ブラウザへは、notices の status（ended）と、fatal（broadcast_ended）。通知に終了の status があれば、重ねて作らない
	expectSequence(t, s.conn.link, "accepted", "status:awaiting_media", "status:confirming", "status:ended", "fatal:broadcast_ended", "close:1000")
	closes, aborts := s.pub.counts()
	if closes != 1 || aborts != 0 {
		t.Fatalf("publisher: Close %d Abort %d; a time limit stops after sending the pending media", closes, aborts)
	}
	if got := h.ev.kinds(); got[len(got)-1] != "session_ended" {
		t.Fatalf("events = %v", got)
	}
	if h.reg.Count() != 0 {
		t.Fatalf("Count = %d", h.reg.Count())
	}
}

func TestHeartbeatStopWithoutAnEndedNoticeBuildsTheEndedStatus(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	h.be.setHeartbeat(func(backend.HeartbeatRequest) (backend.HeartbeatResponse, error) {
		return backend.HeartbeatResponse{Command: backend.CommandStop, EndReason: contract.EndReasonAdminStop}, nil
	})
	h.clock.Advance(2 * time.Second)
	h.settle()
	h.waitDone(s.sess)
	expectSequence(t, s.conn.link, "accepted", "status:awaiting_media", "status:confirming", "status:ended", "fatal:broadcast_ended", "close:1000")
	assertBodyJSON(t, s.conn.link.ofType(t, contract.FrameTypeStatus)[2],
		`{"state":"ended","watch_url":"`+dummyWatchURL+`","warning":null,"time_limit_notice_seconds":null,"end_reason":"admin_stop"}`)
}

func TestHeartbeatStopForAStaleEpochAbortsAtOnce(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	h.be.setHeartbeat(func(backend.HeartbeatRequest) (backend.HeartbeatResponse, error) {
		return backend.HeartbeatResponse{Command: backend.CommandStop, Reason: backend.ReasonStaleEpoch}, nil
	})
	h.clock.Advance(2 * time.Second)
	h.settle()
	h.waitDone(s.sess)

	expectSequence(t, s.conn.link, "accepted", "status:awaiting_media", "status:confirming", "fatal:stale_epoch", "close:1000")
	closes, aborts := s.pub.counts()
	if closes != 0 || aborts != 1 {
		t.Fatalf("publisher: Close %d Abort %d; a stale session must Abort (Close would keep sending old video)", closes, aborts)
	}
}

// 自分が世代を進めたために古くなった心拍の応答は、無視する（新しい世代で、やり直す）。
func TestStaleEpochAnswerToAnOlderHeartbeatIsIgnored(t *testing.T) {
	h := newHarness(t)
	h.be.heartbeatGate = make(chan struct{})
	h.be.setHeartbeat(func(request backend.HeartbeatRequest) (backend.HeartbeatResponse, error) {
		if request.Epoch == 1 {
			return backend.HeartbeatResponse{Command: backend.CommandStop, Reason: backend.ReasonStaleEpoch}, nil
		}
		return backend.HeartbeatResponse{Command: backend.CommandContinue}, nil
	})
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	first := h.connect()
	first.hello("t1")
	h.settle()
	h.clock.Advance(2 * time.Second)
	h.barrierAll()
	<-h.be.heartbeatEntered // 世代 1 の心拍が、応答待ち

	h.be.addTicket("t2", verifyResult(idA, 2, contract.BroadcastStateReserved))
	second := h.connect()
	second.hello("t2")
	deadline := time.Now().Add(5 * time.Second)
	for len(second.link.sequence(t)) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("the second connection was not accepted")
		}
		time.Sleep(time.Millisecond)
	}
	close(h.be.heartbeatGate)
	h.settle()
	session := h.mustSession(idA)
	if session.State() == StateClosed || second.link.isClosed() {
		t.Fatal("the session stopped on a stale_epoch answered to a heartbeat sent before its own epoch change")
	}
	// 次の心拍は、新しい世代で送る。連番は続く
	h.clock.Advance(2 * time.Second)
	h.settle()
	beats := h.be.heartbeats()
	if last := beats[len(beats)-1]; last.Epoch != 2 {
		t.Fatalf("last heartbeat epoch = %d, want 2", last.Epoch)
	}
}

// ---- 心拍の応答の喪失 ----

func TestSessionStopsWhenNoHeartbeatIsAnsweredForSixtySeconds(t *testing.T) {
	h := newHarness(t)
	h.be.setHeartbeat(func(backend.HeartbeatRequest) (backend.HeartbeatResponse, error) {
		return backend.HeartbeatResponse{}, unreachable()
	})
	s := h.bringUp("t1", idA, 1) // 照合から 5 秒後
	start := h.clock.Now().Add(-h.opts.PublishConfirmWindow)

	// 60 秒の手前（59 秒）までは、送出を続ける。メディアの転送を止めない
	for h.clock.Now().Sub(start) < 59*time.Second {
		h.clock.Advance(time.Second)
		h.settle()
		s.conn.audio(uint64(h.clock.Now().Sub(start)/time.Microsecond), audioPayload(1, 10))
		s.conn.video(uint64(h.clock.Now().Sub(start)/time.Microsecond), false, videoPayload(1, 10))
		h.settle()
	}
	if s.sess.State() != StateStreaming {
		t.Fatalf("state = %v at 59 seconds, want streaming (the data plane must not stop within 60 seconds)", s.sess.State())
	}
	if got := len(mediaTags(s.pub.tags())); got < 100 {
		t.Fatalf("media tags = %d: the media must keep flowing while the application is unreachable", got)
	}
	if closes, aborts := s.pub.counts(); closes+aborts != 0 {
		t.Fatalf("publisher stopped at 59 seconds (Close %d Abort %d)", closes, aborts)
	}

	h.clock.Advance(time.Second) // ちょうど 60 秒
	h.settle()
	h.waitDone(s.sess)
	if got := s.conn.link.fatals(t); len(got) != 1 || got[0] != "heartbeat_lost" {
		t.Fatalf("fatal codes = %v, want [heartbeat_lost]", got)
	}
	closes, aborts := s.pub.counts()
	if closes != 0 || aborts != 1 {
		t.Fatalf("publisher: Close %d Abort %d; a lost control plane must Abort (no stop command or epoch check can reach this session)", closes, aborts)
	}
	if got := h.ev.kinds(); got[len(got)-1] != "session_ended" {
		t.Fatalf("events = %v", got)
	}
}

func TestAnAnsweredHeartbeatRestartsTheSixtySecondCount(t *testing.T) {
	h := newHarness(t)
	var answer atomic.Bool
	h.be.setHeartbeat(func(backend.HeartbeatRequest) (backend.HeartbeatResponse, error) {
		if answer.Load() {
			return backend.HeartbeatResponse{Command: backend.CommandContinue}, nil
		}
		return backend.HeartbeatResponse{}, unreachable()
	})
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	session := h.mustSession(idA)

	advanceBy(h, 2*time.Second, 25) // 50 秒、応答なし
	answer.Store(true)
	advanceBy(h, 2*time.Second, 1) // 応答が得られた（数え直し）
	answer.Store(false)
	advanceBy(h, 2*time.Second, 29) // さらに 58 秒、応答なし（最初から数えれば、110 秒）
	if session.State() == StateClosed {
		t.Fatal("the session stopped although a heartbeat had been answered 58 seconds ago")
	}
	advanceBy(h, 2*time.Second, 1) // 60 秒
	h.waitDone(session)
	if got := conn.link.fatals(t); len(got) != 1 || got[0] != "heartbeat_lost" {
		t.Fatalf("fatal codes = %v", got)
	}
}

func TestACommandToStopIsAnAnswerEvenIfTheSessionStops(t *testing.T) {
	// 応答の中身が「停止の指示」でも、応答は応答（数え直す）。停止の処理が優先される
	h := newHarness(t)
	h.be.setHeartbeat(func(backend.HeartbeatRequest) (backend.HeartbeatResponse, error) {
		return backend.HeartbeatResponse{Command: backend.CommandStop, EndReason: contract.EndReasonUserStop}, nil
	})
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	session := h.mustSession(idA)
	h.clock.Advance(2 * time.Second)
	h.settle()
	h.waitDone(session)
	if got := conn.link.fatals(t); len(got) != 1 || got[0] != "broadcast_ended" {
		t.Fatalf("fatal codes = %v, want [broadcast_ended] (not heartbeat_lost)", got)
	}
}
