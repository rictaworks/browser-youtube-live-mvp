package session

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
)

// 中断と復帰（requirements.md 11.10・13.1・13.2・23.4）。
// ブラウザの WebSocket が切れた・フレームが 5 秒届かない・RTMPS が切れた・送出待ちの上限、のいずれかで中断し、
// RTMPS の接続は中断の期限まで保持する。復帰は、キーフレームの到着をもって完了とする。時刻は、欠落を詰めて連続させる。

// firstMedia は、新規の配信の最初の 1 秒に満たないメディア。
//
//	音声 0・映像（キー）0・音声 23,220・映像 33,333・音声 46,440 マイクロ秒 → 出力は 0・0・23・33・46 ミリ秒
func firstMedia(conn *testConn) {
	conn.audio(0, audioPayload(1, 20))
	conn.video(0, true, videoPayload(1, 30))
	conn.audio(23220, audioPayload(2, 20))
	conn.video(33333, false, videoPayload(2, 30))
	conn.audio(46440, audioPayload(3, 20))
}

const firstMediaTags = "a@0 vK@0 a@23 vp@33 a@46"

func tagsString(pub *fakePublisher) string { return joinStrings(summarize(pub.tags())) }

func joinStrings(items []string) string {
	var out bytes.Buffer
	for i, item := range items {
		if i > 0 {
			out.WriteByte(' ')
		}
		out.WriteString(item)
	}
	return out.String()
}

// ---- ブラウザの切断と復帰 ----

func TestBrowserDisconnectInterruptsAndKeepsTheRTMPSConnection(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	firstMedia(s.conn)
	h.settle()

	s.conn.conn.Disconnected()
	h.settle()
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started interrupted:browser_disconnected]" {
		t.Fatalf("events = %s", got)
	}
	if s.sess.State() != StateInterrupted {
		t.Fatalf("state = %v, want interrupted", s.sess.State())
	}
	// 送出（RTMPS）の接続は、中断の期限まで保持する。接続の数も、増やさない
	h.advance(20 * time.Second)
	if closes, aborts := s.pub.counts(); closes+aborts != 0 || s.pub.isClosed() {
		t.Fatalf("the RTMPS connection was closed while the browser was away (Close %d Abort %d)", closes, aborts)
	}
	if got := h.fac.openCount(); got != 1 {
		t.Fatalf("Open calls = %d, want 1", got)
	}
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started interrupted:browser_disconnected]" {
		t.Fatalf("events = %s: the interruption is reported once", got)
	}
}

func TestResumeAfterABrowserDisconnectContinuesTheTimelineWithTheSameCorrection(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	firstMedia(s.conn)
	h.settle()
	s.conn.conn.Disconnected()
	h.settle()
	h.clock.Advance(10 * time.Second)
	h.settle()
	tagsBefore := len(s.pub.tags())

	// 再接続: 新しいチケットを照合する（世代が進む）。accepted は、再開・確定済みのプロファイル
	resumed := h.resumeConnect("t2", idA, 2, contract.BroadcastStateInterrupted)
	expectSequence(t, resumed.link, "accepted")
	assertBodyJSON(t, resumed.link.ofType(t, contract.FrameTypeAccepted)[0], `{"state":"interrupted","resume":true,"profile":"720p","limits":{"time_limit_seconds":3600}}`)
	if s.sess.Epoch() != 2 || h.mustSession(idA) != s.sess {
		t.Fatalf("the same ingest session must continue with the new epoch (epoch %d)", s.sess.Epoch())
	}

	// 設定の再送（開始通知）で、キーフレームを要求する。取り込み先は保持しているので、準備も接続も、やり直さない
	resumed.start("720p")
	h.settle()
	expectSequence(t, resumed.link, "accepted", "keyframe_request")
	if got := len(h.be.provisions()); got != 1 {
		t.Fatalf("provision calls = %d: a resume must not provision again while the destination is held", got)
	}
	if got := h.fac.openCount(); got != 1 {
		t.Fatalf("Open calls = %d: a resume must reuse the RTMPS connection", got)
	}
	if got := len(s.pub.tags()); got != tagsBefore {
		t.Fatalf("tags written = %d (was %d): the decoder configuration is unchanged, so it is not written again", got, tagsBefore)
	}

	// キーフレーム要求のあとも、キーフレームが来るまでの映像・音声は捨てる
	resumed.audio(11_990_000, audioPayload(9, 20))
	resumed.video(11_999_000, false, videoPayload(9, 30))
	h.settle()
	if got := tagsString(s.pub); got != firstMediaTags {
		t.Fatalf("media tags = %s: frames before the keyframe must be discarded", got)
	}
	if s.sess.State() != StateInterrupted {
		t.Fatalf("state = %v: the resume completes on the keyframe", s.sess.State())
	}

	// キーフレームの到着で復帰。欠落を詰め、時刻を連続させる（空白は 1 フレーム分だけ残す）。映像と音声は、同一の補正量
	resumed.video(12_000_000, true, videoPayload(4, 30))
	resumed.audio(12_000_000, audioPayload(4, 20))
	resumed.audio(12_023_220, audioPayload(5, 20))
	resumed.video(12_033_333, false, videoPayload(5, 30))
	h.settle()
	want := firstMediaTags + " vK@79 a@79 a@102 vp@113"
	if got := tagsString(s.pub); got != want {
		t.Fatalf("media tags = %s\nwant        %s", got, want)
	}
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started interrupted:browser_disconnected resumed]" {
		t.Fatalf("events = %s", got)
	}
	if s.sess.State() != StateStreaming {
		t.Fatalf("state = %v, want streaming", s.sess.State())
	}
	if h.reg.Count() != 1 {
		t.Fatalf("Count = %d", h.reg.Count())
	}
}

// ページの再読み込みでは、ブラウザのメディアクロックが 0 から数え直しになる（ws-protocol.md の 5.10・6 章との食い違い。#18 のレビュー）。
// 接続ごとに TimeGuard を新しくするので、時刻の逆行として破棄されず、再基準化は巻き戻らない。
func TestResumeWhenTheBrowserClockRestartsFromZero(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	firstMedia(s.conn)
	h.settle()
	s.conn.conn.Disconnected()
	h.settle()

	resumed := h.resumeConnect("t2", idA, 2, contract.BroadcastStateInterrupted)
	resumed.start("720p")
	h.settle()
	resumed.video(0, true, videoPayload(4, 30)) // 時計が 0 に戻った
	resumed.audio(0, audioPayload(4, 20))
	resumed.audio(23220, audioPayload(5, 20))
	resumed.video(33333, false, videoPayload(5, 30))
	h.settle()

	// 出力は戻らない。直前の最大の出力（46,440 マイクロ秒）から続く
	want := firstMediaTags + " vK@46 a@46 a@69 vp@79"
	if got := tagsString(s.pub); got != want {
		t.Fatalf("media tags = %s\nwant        %s", got, want)
	}
	if s.sess.State() != StateStreaming {
		t.Fatalf("state = %v, want streaming (frames must not be discarded as time regressions)", s.sess.State())
	}

	// ack は、接続ごとに数える。直前の接続の大きな値を引き継がず、新しい接続の最初のメディアまでは送らない
	h.clock.Advance(h.opts.AckInterval)
	h.settle()
	acks := resumed.link.ofType(t, contract.FrameTypeAck)
	if len(acks) != 1 {
		t.Fatalf("ack count = %d, want 1", len(acks))
	}
	assertBodyJSON(t, acks[0], `{"video_us":33333,"audio_us":23220}`)
}

func TestAckIsNotSentOnANewConnectionBeforeItsFirstMedia(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	firstMedia(s.conn)
	h.settle()
	h.clock.Advance(h.opts.AckInterval)
	h.settle()
	if got := len(s.conn.link.ofType(t, contract.FrameTypeAck)); got == 0 {
		t.Fatal("the first connection received no ack")
	}
	s.conn.conn.Disconnected()
	h.settle()

	resumed := h.resumeConnect("t2", idA, 2, contract.BroadcastStateInterrupted)
	resumed.start("720p")
	h.settle()
	for i := 0; i < 4; i++ {
		h.clock.Advance(h.opts.AckInterval)
		h.settle()
	}
	if got := resumed.link.ofType(t, contract.FrameTypeAck); len(got) != 0 {
		t.Fatalf("ack count = %d before the new connection sent media (a 0, or the old connection's values, must not be sent)", len(got))
	}
}

// 再接続した接続で映像設定・音声設定が変わっていれば、新しい設定を、キーフレームの前に書く。
func TestResumeWithAChangedDecoderConfigurationWritesTheNewConfiguration(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	firstMedia(s.conn)
	h.settle()
	s.conn.conn.Disconnected()
	h.settle()
	resumed := h.resumeConnect("t2", idA, 2, contract.BroadcastStateInterrupted)

	changed := base64.StdEncoding.EncodeToString([]byte{1, 0x4D, 0x40, 0x1F, 0xFF, 0xE1, 0x00, 0x01, 0x67, 0x01, 0x00, 0x01, 0x68})
	resumed.startBody(startJSON("720p", func(m map[string]string) { m["vdesc"] = `"` + changed + `"` }))
	h.settle()

	tags := s.pub.tags()
	video, audio := tags[len(tags)-2], tags[len(tags)-1]
	if video.kind != "video" || video.payload[1] != 0 || !bytes.Equal(video.payload[5:], []byte{1, 0x4D, 0x40, 0x1F, 0xFF, 0xE1, 0x00, 0x01, 0x67, 0x01, 0x00, 0x01, 0x68}) {
		t.Fatalf("the second last tag = %s % x, want the new video configuration", video.kind, video.payload)
	}
	if audio.kind != "audio" || audio.payload[1] != 0 {
		t.Fatalf("the last tag = %s % x, want the audio configuration", audio.kind, audio.payload)
	}
	// 設定のタグの時刻は、それまでの最後の出力の時刻（時刻が戻らないように）
	if video.ts != 46 || audio.ts != 46 {
		t.Fatalf("configuration tag timestamps = %d, %d; want 46 (the last output time)", video.ts, audio.ts)
	}
	expectSequence(t, resumed.link, "accepted", "keyframe_request")
}

func TestANewerConnectionClosesTheOlderOneAtOnce(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	firstMedia(s.conn)
	h.settle()

	// 古い接続が、まだ生きている間に、新しい世代の接続を照合する
	newer := h.resumeConnect("t2", idA, 2, contract.BroadcastStateConfirming)

	expectSequence(t, s.conn.link, "accepted", "status:awaiting_media", "status:confirming", "fatal:stale_epoch", "close:1000")
	expectSequence(t, newer.link, "accepted")
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started interrupted:browser_disconnected]" {
		t.Fatalf("events = %s: replacing the connection of a streaming session interrupts it", got)
	}
	// 古い接続の切断の通知が遅れて届いても、新しい接続の状態を壊さない
	s.conn.conn.Disconnected()
	h.settle()
	if s.sess.State() != StateInterrupted {
		t.Fatalf("state = %v", s.sess.State())
	}
	newer.start("720p")
	h.settle()
	expectSequence(t, newer.link, "accepted", "keyframe_request")
}

func TestAConnectionWithAnOlderEpochIsRefused(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 5)
	older := h.resumeConnect("t-old", idA, 4, contract.BroadcastStateLive)
	expectSequence(t, older.link, "fatal:stale_epoch", "close:1000")
	if s.sess.Epoch() != 5 || s.sess.State() != StateStreaming {
		t.Fatalf("epoch %d state %v: an older connection must not disturb the session", s.sess.Epoch(), s.sess.State())
	}
	equal := h.resumeConnect("t-equal", idA, 5, contract.BroadcastStateLive)
	expectSequence(t, equal.link, "fatal:stale_epoch", "close:1000")
}

// 新しい接続が、照合の応答を待つ間に切れても、世代は進める（アプリケーションの世代が進んでいるため）。
func TestANewConnectionThatDiesDuringVerificationStillAdvancesTheEpoch(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	firstMedia(s.conn)
	h.settle()

	gate := make(chan struct{})
	h.be.setVerifyGate(gate)
	h.be.addTicket("t2", verifyResult(idA, 2, contract.BroadcastStateConfirming))
	dying := h.connect()
	dying.hello("t2")
	<-h.be.verifyEntered
	dying.conn.Disconnected()
	close(gate)
	h.settle()

	if s.sess.Epoch() != 2 {
		t.Fatalf("epoch = %d, want 2 (the application advanced it)", s.sess.Epoch())
	}
	expectSequence(t, s.conn.link, "accepted", "status:awaiting_media", "status:confirming", "fatal:stale_epoch", "close:1000")
	if s.sess.State() != StateInterrupted {
		t.Fatalf("state = %v, want interrupted", s.sess.State())
	}
	// 次の接続（世代 3）で、復帰できる
	h.be.setVerifyGate(nil)
	third := h.resumeConnect("t3", idA, 3, contract.BroadcastStateInterrupted)
	third.start("720p")
	h.settle()
	expectSequence(t, third.link, "accepted", "keyframe_request")
}

func TestSessionClosesWhenTheInterruptionLimitPasses(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.conn.Disconnected()
	h.settle()

	h.advance(h.opts.InterruptionLimit - time.Millisecond)
	if s.sess.State() != StateInterrupted {
		t.Fatalf("state = %v just before the limit, want interrupted", s.sess.State())
	}
	h.clock.Advance(time.Millisecond)
	h.settle()
	h.waitDone(s.sess)

	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started interrupted:browser_disconnected session_ended]" {
		t.Fatalf("events = %s", got)
	}
	if h.reg.Count() != 0 {
		t.Fatalf("Count = %d", h.reg.Count())
	}
	if closes, aborts := s.pub.counts(); closes+aborts != 1 {
		t.Fatalf("publisher: Close %d Abort %d, want it stopped exactly once", closes, aborts)
	}
}

func TestApplicationCanStopAnInterruptedSession(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.conn.Disconnected()
	h.settle()
	h.be.setHeartbeat(func(backend.HeartbeatRequest) (backend.HeartbeatResponse, error) {
		return backend.HeartbeatResponse{Command: backend.CommandStop, EndReason: contract.EndReasonConnectionLost}, nil
	})
	h.clock.Advance(2 * time.Second)
	h.settle()
	h.waitDone(s.sess)
	if got := h.ev.kinds(); got[len(got)-1] != "session_ended" {
		t.Fatalf("events = %v", got)
	}
	// ブラウザが居なくても、停止できる。切断のあとなので、リンクへは何も送らない
	if got := s.conn.link.sequence(t); len(got) != 3 {
		t.Fatalf("link sequence = %v: nothing may be sent to a connection that is gone", got)
	}
}

// ---- RTMPS の切断と再接続 ----

func TestRTMPSDisconnectInterruptsReconnectsAndWaitsForAKeyframe(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	firstMedia(s.conn)
	h.settle()

	s.pub.terminate(rtmpsDisconnected()) // YouTube 側の切断
	h.settle()

	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started interrupted:rtmps_disconnected]" {
		t.Fatalf("events = %s", got)
	}
	if got := h.fac.openCount(); got != 2 {
		t.Fatalf("Open calls = %d, want 2 (a reconnection is attempted at once)", got)
	}
	second := h.fac.last(t)
	if second == s.pub {
		t.Fatal("the same publisher was reused after it closed")
	}
	// 新しい接続の最初に、メタデータと設定が、時刻 0 で届く
	tags := second.tags()
	if len(tags) != 3 || tags[0].kind != "meta" || tags[1].kind != "video" || tags[1].payload[1] != 0 || tags[2].kind != "audio" || tags[2].payload[1] != 0 {
		t.Fatalf("tags on the new connection = %v, want metadata and both configurations", describeTags(tags))
	}
	if tags[1].ts != 0 || tags[2].ts != 0 {
		t.Fatalf("configuration timestamps = %d, %d; want 0", tags[1].ts, tags[2].ts)
	}
	// 再接続できたら、ブラウザへキーフレーム要求を送る
	expectSequence(t, s.conn.link, "accepted", "status:awaiting_media", "status:confirming", "keyframe_request")

	// キーフレームが来るまで、映像・音声を捨てる
	s.conn.audio(1_990_000, audioPayload(9, 20))
	s.conn.video(1_999_000, false, videoPayload(9, 30))
	h.settle()
	if got := tagsString(second); got != "" {
		t.Fatalf("media tags on the new connection = %s: frames before the keyframe must be discarded", got)
	}
	if s.sess.State() != StateInterrupted {
		t.Fatalf("state = %v", s.sess.State())
	}

	// キーフレームの到着で復帰。RTMPS の接続ごとに、時刻は 0 起点へ再基準化する
	s.conn.video(2_000_000, true, videoPayload(4, 30))
	s.conn.audio(2_000_000, audioPayload(4, 20))
	s.conn.audio(2_023_220, audioPayload(5, 20))
	s.conn.video(2_033_333, false, videoPayload(5, 30))
	h.settle()
	if got := tagsString(second); got != "vK@0 a@0 a@23 vp@33" {
		t.Fatalf("media tags on the new connection = %s, want an origin of 0", got)
	}
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started interrupted:rtmps_disconnected resumed]" {
		t.Fatalf("events = %s", got)
	}
	if s.sess.State() != StateStreaming {
		t.Fatalf("state = %v, want streaming", s.sess.State())
	}
}

func TestRTMPSReconnectionIsRetriedWithBackoffWithinTheLimit(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	h.fac.failNext(fmt.Errorf("refused"), fmt.Errorf("refused"))
	s.pub.terminate(rtmpsDisconnected())
	h.settle()
	if got := h.fac.openCount(); got != 2 {
		t.Fatalf("Open calls = %d, want 2 (the first attempt is immediate and fails)", got)
	}
	h.clock.Advance(h.opts.RedialInitial)
	h.settle()
	if got := h.fac.openCount(); got != 3 {
		t.Fatalf("Open calls = %d, want 3 after 500 ms", got)
	}
	h.clock.Advance(2 * h.opts.RedialInitial)
	h.settle()
	if got := h.fac.openCount(); got != 4 {
		t.Fatalf("Open calls = %d, want 4 after a further 1 s", got)
	}
	// 再接続できるまでは、キーフレーム要求を送らない
	expectSequence(t, s.conn.link, "accepted", "status:awaiting_media", "status:confirming", "keyframe_request")
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started interrupted:rtmps_disconnected]" {
		t.Fatalf("events = %s: failed attempts are not reported again", got)
	}
}

func TestFrameFloodWhileTheRTMPSConnectionIsDownIsDiscarded(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	gate := make(chan struct{})
	h.fac.setGate(gate) // 再接続が終わらない
	s.pub.terminate(rtmpsDisconnected())
	h.barrierAll()
	<-h.fac.entered

	s.conn.audio(100, audioPayload(1, 20))
	s.conn.video(100, true, videoPayload(1, 30))
	h.barrierAll()
	for _, line := range s.conn.link.sequence(t) {
		if line == "keyframe_request" {
			t.Fatal("keyframe_request was sent before the RTMPS connection was re-established")
		}
	}
	close(gate)
	h.settle()
	expectSequence(t, s.conn.link, "accepted", "status:awaiting_media", "status:confirming", "keyframe_request")
	if got := tagsString(h.fac.last(t)); got != "" {
		t.Fatalf("media tags = %s: frames received while the connection was down must be discarded", got)
	}
}

func TestPublishRejectedIsAFailureOfTheConnectionNotTheEndOfTheBroadcast(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	conn.start("720p")
	h.settle()
	// publish の直後（確認の窓の内）に切れた。配信キーの不正・使用中の可能性
	first := h.fac.last(t)
	first.terminate(rtmpsRejected())
	h.settle()

	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_failed:rtmps_disconnected]" {
		t.Fatalf("events = %s, want publish_failed (publish_started must not have been announced)", got)
	}
	// 配信の終了の根拠にはしない。期限内に再接続する。窓の間に切れたので、待機を置く
	if got := h.fac.openCount(); got != 1 {
		t.Fatalf("Open calls = %d, want 1 (a connection that closed inside the window is retried after a wait)", got)
	}
	if h.mustSession(idA).State() == StateClosed {
		t.Fatal("the session closed on a rejected publish")
	}
	h.clock.Advance(h.opts.RedialInitial)
	h.settle()
	if got := h.fac.openCount(); got != 2 {
		t.Fatalf("Open calls = %d, want 2 after the wait", got)
	}
	// 新しい接続が、確認の窓を過ぎても保たれれば、そこで初めて送出の開始を知らせる
	h.advance(h.opts.PublishConfirmWindow)
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_failed:rtmps_disconnected publish_started]" {
		t.Fatalf("events = %s", got)
	}
	expectSequence(t, conn.link, "accepted", "status:awaiting_media", "status:confirming")
}

func TestPublishRejectedAfterTheAnnouncementInterruptsAndReconnects(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.pub.terminate(rtmpsRejected())
	h.settle()
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started publish_failed:rtmps_disconnected]" {
		t.Fatalf("events = %s", got)
	}
	if got := h.fac.openCount(); got != 2 {
		t.Fatalf("Open calls = %d, want 2", got)
	}
	expectSequence(t, s.conn.link, "accepted", "status:awaiting_media", "status:confirming", "keyframe_request")
}

func TestAConnectionThatClosesWithinTheWindowIsNeverAnnounced(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	conn.start("720p")
	h.settle()
	h.clock.Advance(h.opts.PublishConfirmWindow - time.Millisecond)
	h.settle()
	h.fac.last(t).terminate(rtmpsDisconnected()) // 窓の終わる直前に切れた
	h.settle()
	h.clock.Advance(time.Millisecond)
	h.settle()
	for _, kind := range h.ev.kinds() {
		if kind == "publish_started" {
			t.Fatalf("events = %v: a connection that closed inside the window must not be announced", h.ev.kinds())
		}
	}
}

// ---- 送出待ちの上限 ----

func TestBufferLimitIsAPublishFailureAndTheConnectionIsReestablished(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	firstMedia(s.conn)
	h.settle()

	s.pub.failWrites(rtmpsOverflow()) // 次の書き込みで、送出待ちが 3 秒分の上限に達する
	s.conn.video(66666, false, videoPayload(6, 30))
	h.settle()

	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started publish_failed:buffer_overflow]" {
		t.Fatalf("events = %s", got)
	}
	if got := h.fac.openCount(); got != 2 {
		t.Fatalf("Open calls = %d, want 2", got)
	}
	expectSequence(t, s.conn.link, "accepted", "status:awaiting_media", "status:confirming", "keyframe_request")

	// 復帰の扱いは、切断の場合と同じ（キーフレームの到着で復帰）
	s.conn.video(100_000, true, videoPayload(7, 30))
	s.conn.audio(100_000, audioPayload(7, 20))
	h.settle()
	if got := tagsString(h.fac.last(t)); got != "vK@0 a@0" {
		t.Fatalf("media tags on the new connection = %s", got)
	}
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started publish_failed:buffer_overflow resumed]" {
		t.Fatalf("events = %s", got)
	}
}

func TestPendingAtTheLimitCountsAsAnOverflowEvenIfTheWriteSucceeded(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.audio(0, audioPayload(1, 20))
	h.settle()
	s.pub.setPending(contract.RelayEgressBufferLimitMs) // 3,000 ミリ秒ちょうどは、上限に達している
	s.conn.audio(23220, audioPayload(2, 20))
	h.settle()
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started publish_failed:buffer_overflow]" {
		t.Fatalf("events = %s", got)
	}
	if !s.pub.isClosed() {
		t.Fatal("the buffered media must be discarded (the old publisher stopped)")
	}
}

func TestPendingJustBelowTheLimitOnlyThrottles(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.audio(0, audioPayload(1, 20))
	h.settle()
	s.pub.setPending(contract.RelayEgressBufferLimitMs - 1)
	s.conn.audio(23220, audioPayload(2, 20))
	h.settle()
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started]" {
		t.Fatalf("events = %s", got)
	}
	if got := len(s.conn.link.ofType(t, contract.FrameTypeThrottle)); got != 1 {
		t.Fatalf("throttle count = %d, want 1", got)
	}
}

// ---- 映像・音声の途絶 ----

func TestFramesMissingForFiveSecondsInterruptTheSession(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	firstMedia(s.conn)
	h.settle()

	h.clock.Advance(5*time.Second - time.Millisecond)
	h.settle()
	if s.sess.State() != StateStreaming {
		t.Fatalf("state = %v at 4.999 seconds, want streaming", s.sess.State())
	}
	h.clock.Advance(time.Millisecond)
	h.settle()

	if s.sess.State() != StateInterrupted {
		t.Fatalf("state = %v at 5 seconds, want interrupted", s.sess.State())
	}
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started interrupted:media_stalled]" {
		t.Fatalf("events = %s", got)
	}
	// ブラウザは接続したままなので、キーフレームを要求する。RTMPS の接続は、そのまま
	expectSequence(t, s.conn.link, "accepted", "status:awaiting_media", "status:confirming", "keyframe_request")
	if got := h.fac.openCount(); got != 1 || s.pub.isClosed() {
		t.Fatalf("the RTMPS connection must be kept on a media stall (Open calls %d)", got)
	}

	// キーフレームの到着で復帰。欠落（5 秒）を詰めて、時刻を連続させる
	s.conn.video(5_000_000, true, videoPayload(8, 30))
	s.conn.audio(5_000_000, audioPayload(8, 20))
	h.settle()
	if got := tagsString(s.pub); got != firstMediaTags+" vK@79 a@79" {
		t.Fatalf("media tags = %s", got)
	}
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started interrupted:media_stalled resumed]" {
		t.Fatalf("events = %s", got)
	}
}

func TestOnlyOneKindMissingForFiveSecondsIsAStall(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.audio(0, audioPayload(1, 20))
	s.conn.video(0, true, videoPayload(1, 30))
	h.settle()
	for i := 1; i <= 5; i++ {
		h.clock.Advance(time.Second)
		s.conn.audio(uint64(i)*1_000_000, audioPayload(1, 20)) // 音声だけが届き続ける
		h.settle()
	}
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started interrupted:media_stalled]" {
		t.Fatalf("events = %s: a missing video must be detected even while the audio arrives", got)
	}
}

func TestNoStallIsDetectedBeforeTheMediaStarts(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	for i := 0; i < 10; i++ {
		h.clock.Advance(time.Second)
		h.settle()
	}
	if got := h.ev.kinds(); len(got) != 0 {
		t.Fatalf("events = %v: the stall check starts when the media may flow", got)
	}
}

func TestNoStallWhileWaitingForTheKeyframeOfAResume(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.conn.Disconnected()
	h.settle()
	h.advance(30 * time.Second)
	for _, kind := range h.ev.kinds() {
		if kind == "interrupted:media_stalled" {
			t.Fatalf("events = %v: an interruption already in progress must not report a stall", h.ev.kinds())
		}
	}
}

// ---- 中継の再起動後（取り込みセッションが存在しない） ----

func TestARestartedRelayRebuildsTheSessionFromAResumeHello(t *testing.T) {
	h := newHarness(t)
	h.be.setProvision(func(provisionCall) (backend.ProvisionResult, error) {
		result := defaultProvisionResult()
		result.State = contract.BroadcastStateLive // 復帰での再要求は、現在の状態を返す
		return result, nil
	})
	conn := h.resumeConnect("t1", idA, 7, contract.BroadcastStateLive)
	expectSequence(t, conn.link, "accepted")

	// 設定の再送で、準備を呼び、取り込み先を再取得して、RTMPS へ接続する
	conn.start("720p")
	h.settle()
	if got := h.be.provisions(); len(got) != 1 || got[0] != (provisionCall{broadcastID: idA, epoch: 7, profile: contract.Profile720p}) {
		t.Fatalf("provision calls = %+v", got)
	}
	if got := h.fac.openCount(); got != 1 {
		t.Fatalf("Open calls = %d", got)
	}
	// 配信はすでに確定しているので、送出の開始（publish_started）も status(confirming) も伝えない。キーフレームを要求する
	expectSequence(t, conn.link, "accepted", "keyframe_request")
	h.clock.Advance(h.opts.PublishConfirmWindow)
	h.settle()
	if got := h.ev.kinds(); len(got) != 0 {
		t.Fatalf("events = %v: the application already knows this broadcast is live", got)
	}

	conn.video(40_000, true, videoPayload(1, 30))
	conn.audio(40_000, audioPayload(1, 20))
	h.settle()
	if got := tagsString(h.fac.last(t)); got != "vK@0 a@0" {
		t.Fatalf("media tags = %s, want the new connection's origin of 0", got)
	}
	if got := fmt.Sprint(h.ev.kinds()); got != "[resumed]" {
		t.Fatalf("events = %s", got)
	}
	if h.mustSession(idA).State() != StateStreaming {
		t.Fatalf("state = %v", h.mustSession(idA).State())
	}
}

func TestARestartedRelayThatFindsTheBroadcastStillAwaitingMediaAnnouncesTheStart(t *testing.T) {
	h := newHarness(t)
	conn := h.resumeConnect("t1", idA, 3, contract.BroadcastStateAwaitingMedia)
	conn.start("720p")
	h.settle()
	h.clock.Advance(h.opts.PublishConfirmWindow)
	h.settle()
	// 送出は始まっていなかったので、開始を伝える。再開の接続なので、キーフレームを要求する
	expectSequence(t, conn.link, "accepted", "status:awaiting_media", "status:confirming", "keyframe_request")
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started]" {
		t.Fatalf("events = %s", got)
	}
	conn.video(0, true, videoPayload(1, 30))
	h.settle()
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started resumed]" {
		t.Fatalf("events = %s", got)
	}
}

func TestIfTheBrowserLeavesBeforeTheStartIsAnnouncedItIsAnnouncedOnReturn(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	conn.start("720p")
	h.settle()
	conn.conn.Disconnected() // 確認の窓の間に、ブラウザが居なくなった
	h.settle()
	h.clock.Advance(h.opts.PublishConfirmWindow)
	h.settle()
	// 接続は保たれたので、送出の開始は伝える。ブラウザへの status は、戻ってきたとき
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started]" {
		t.Fatalf("events = %s", got)
	}

	back := h.resumeConnect("t2", idA, 2, contract.BroadcastStateConfirming)
	back.start("720p")
	h.settle()
	expectSequence(t, back.link, "accepted", "status:confirming", "keyframe_request")
}

// ---- 復帰の回数と時間 ----

func TestEachResumeIsReportedOnce(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	media := uint64(0)
	for round := 1; round <= 3; round++ {
		s.pub.terminate(rtmpsDisconnected())
		h.settle()
		pub := h.fac.last(t)
		media += 10_000_000
		s.conn.video(media, true, videoPayload(byte(round), 30))
		s.conn.audio(media, audioPayload(byte(round), 20))
		h.settle()
		s.pub = pub
		// 接続が確認の窓を過ぎても保たれる（安定する）まで、映像と音声を送り続ける
		for second := 1; second <= 5; second++ {
			h.clock.Advance(time.Second)
			media += 1_000_000
			s.conn.video(media, false, videoPayload(byte(round), 30))
			s.conn.audio(media, audioPayload(byte(round), 20))
			h.settle()
		}
	}
	want := "[publish_started interrupted:rtmps_disconnected resumed interrupted:rtmps_disconnected resumed interrupted:rtmps_disconnected resumed]"
	if got := fmt.Sprint(h.ev.kinds()); got != want {
		t.Fatalf("events = %s\nwant     %s", got, want)
	}
}

// 動けないまま過ぎた再試行の時刻で、イベントループが空回りしない（CPU を使い続けない）。
func TestTheLoopDoesNotSpinWhileItCannotAct(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.conn.Disconnected() // ブラウザが居ない
	h.settle()
	s.pub.terminate(rtmpsDisconnected()) // その間に、RTMPS も切れた。ブラウザが戻るまで、再接続できない
	h.settle()

	before := s.sess.steps.Load()
	time.Sleep(100 * time.Millisecond) // 時計は進めない。実時間だけが過ぎる
	h.settle()
	if after := s.sess.steps.Load(); after-before > 10 {
		t.Fatalf("the loop ran %d times in 100 ms without anything to do (it is spinning)", after-before)
	}
}

// 窓の間に切れる接続を、続けざまに繰り返さない（受け口を叩き続けない）。待機を倍にし、連続の失敗の上限で、閉じる。
func TestRepeatedQuickRTMPSFailuresBackOffAndEventuallyGiveUp(t *testing.T) {
	h := newHarness(t, func(o *Options) { o.MaxRedialAttempts = 5 })
	s := h.bringUp("t1", idA, 1)
	s.pub.terminate(rtmpsDisconnected()) // 安定した接続の切断は、すぐに再接続する
	h.settle()
	if got := h.fac.openCount(); got != 2 {
		t.Fatalf("Open calls = %d, want 2", got)
	}

	waits := []time.Duration{500 * time.Millisecond, time.Second, 2 * time.Second, 4 * time.Second}
	for i, wait := range waits {
		h.fac.last(t).terminate(rtmpsRejected()) // 接続した直後に切られる
		h.settle()
		wantOpens := 2 + i
		if got := h.fac.openCount(); got != wantOpens {
			t.Fatalf("round %d: Open calls = %d, want %d (a wait of %v comes first)", i, got, wantOpens, wait)
		}
		h.clock.Advance(wait - time.Millisecond)
		h.settle()
		if got := h.fac.openCount(); got != wantOpens {
			t.Fatalf("round %d: Open calls = %d before the wait of %v ended", i, got, wait)
		}
		h.clock.Advance(time.Millisecond)
		h.settle()
		if got := h.fac.openCount(); got != wantOpens+1 {
			t.Fatalf("round %d: Open calls = %d, want %d after the wait of %v", i, got, wantOpens+1, wait)
		}
	}
	h.fac.last(t).terminate(rtmpsRejected()) // 5 回目の連続の失敗
	h.settle()
	h.waitDone(s.sess)
	if got := s.conn.link.fatals(t); len(got) != 1 || got[0] != "publish_failed" {
		t.Fatalf("fatal codes = %v, want [publish_failed]", got)
	}
}

// 窓を過ぎて保たれた接続は、安定したものとして、連続の失敗の数を戻す。
func TestAStableConnectionResetsTheFailureCount(t *testing.T) {
	h := newHarness(t, func(o *Options) { o.MaxRedialAttempts = 3 })
	s := h.bringUp("t1", idA, 1)
	for round := 0; round < 4; round++ { // 上限（3）を超える回数、失敗しては安定する
		s.pub.terminate(rtmpsDisconnected())
		h.settle()
		current := h.fac.last(t)
		current.terminate(rtmpsRejected()) // すぐ切れる（失敗 1）
		h.settle()
		h.clock.Advance(h.opts.RedialInitial)
		h.settle()
		current = h.fac.last(t)
		s.conn.video(uint64(round+1)*100_000_000, true, videoPayload(1, 30))
		s.conn.audio(uint64(round+1)*100_000_000, audioPayload(1, 20))
		h.settle()
		for second := 1; second <= 5; second++ { // 安定するまで保たれる
			h.clock.Advance(time.Second)
			s.conn.video(uint64(round+1)*100_000_000+uint64(second)*1_000_000, false, videoPayload(1, 30))
			s.conn.audio(uint64(round+1)*100_000_000+uint64(second)*1_000_000, audioPayload(1, 20))
			h.settle()
		}
		s.pub = current
	}
	if s.sess.State() == StateClosed {
		t.Fatal("the session gave up although every failure was followed by a stable connection")
	}
}
