package wsapi_test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/session"
)

// 中継層の結合試験（issue #21）：実際の WebSocket のクライアント → Gin の GET /ws → 取り込みセッション → 内部通信
// （疑似のアプリケーション）・RTMPS（疑似の受け口。TLS・自己署名）。時計だけを注入する。

const timeLayout = "2006-01-02T15:04:05-07:00"

func intOf(t *testing.T, value any) int {
	t.Helper()
	number, ok := value.(float64)
	if !ok {
		t.Fatalf("%v (%T) is not a number", value, value)
	}
	return int(number)
}

// 正常な流れ：hello → accepted → probe → probe_result → start → status（awaiting_media・confirming）→ video・audio →
// 受け口に届いたタグ（種別・キーフレーム・0 起点に再基準化した時刻・設定タグが最初）→ ack・心拍 → end → 受け口の切断・事象
func TestAFullBroadcastFromHelloToEnd(t *testing.T) {
	env := newRelayEnv(t)
	bid := broadcastID(1)
	ticket := "dummy-ticket-1-SECRET"
	env.app.addTicket(ticket, bid, "reserved", accountKey(1))
	client := env.dial()

	// hello → 照合 → accepted
	client.hello(ticket)
	accepted := client.waitFor(contract.FrameTypeAccepted, nil).json()
	if accepted["state"] != "reserved" || accepted["resume"] != false || accepted["profile"] != nil {
		t.Errorf("accepted = %v; want state reserved, resume false, profile null", accepted)
	}
	if limits, _ := accepted["limits"].(map[string]any); intOf(t, limits["time_limit_seconds"]) != 3600 {
		t.Errorf("accepted limits = %v; want time_limit_seconds 3600", accepted["limits"])
	}
	verifies := env.app.callsOf("verify")
	if len(verifies) != 1 || verifies[0].body["ticket"] != ticket {
		t.Fatalf("verify calls = %v; want exactly one with the ticket from hello", verifies)
	}

	// probe → 3 秒後に probe_result（受け取ったメッセージ全体の大きさから）
	client.send(contract.FrameTypeProbe, false, 0, make([]byte, 32768))
	env.waitState(bid, session.StateProbing)
	env.clock.Advance(3 * time.Second)
	probe := client.waitFor(contract.FrameTypeProbeResult, nil).json()
	if want := (32768 + contract.WSFrameHeaderBytes) * 8 / 3000; intOf(t, probe["throughput_kbps"]) != want {
		t.Errorf("probe_result = %v; want throughput_kbps %d", probe, want)
	}

	// start → 準備（疑似のアプリケーション）→ status(awaiting_media)・視聴 URL
	client.send(contract.FrameTypeStart, false, 0, startBody("720p"))
	awaiting := client.waitFor(contract.FrameTypeStatus, statusIs("awaiting_media")).json()
	if awaiting["watch_url"] != watchURL {
		t.Errorf("status(awaiting_media) = %v; want the watch URL", awaiting)
	}
	provisions := env.app.callsFor("provision", bid)
	if len(provisions) != 1 || intOf(t, provisions[0].body["epoch"]) != 1 || provisions[0].body["profile"] != "720p" {
		t.Fatalf("provision calls = %v; want one with epoch 1 and profile 720p", provisions)
	}

	// RTMPS の接続：配信キーで publish し、最初にメタデータ・映像設定・音声設定のタグ（時刻 0）が届く
	key := streamKeyOf(bid)
	eventually(t, "the relay connected to the receiver", func() bool { return env.rtmp.peerByKey(key) != nil })
	peer := env.rtmp.peerByKey(key)
	eventually(t, "the three header tags arrived", func() bool { return peer.count() >= 3 })
	headers := peer.snapshot()[:3]
	if headers[0].kind != "meta" || headers[1].kind != "video" || headers[2].kind != "audio" {
		t.Fatalf("first tags = %s, %s, %s; want meta, video, audio", headers[0].kind, headers[1].kind, headers[2].kind)
	}
	if headers[1].ts != 0 || headers[2].ts != 0 || headers[1].payload[1] != 0 || headers[2].payload[1] != 0 {
		t.Errorf("decoder configuration tags = %+v / %+v; want sequence headers at time 0", headers[1], headers[2])
	}

	// 確認の窓（5 秒）のあと：status(confirming)・publish_started
	env.clock.Advance(session.DefaultOptions().PublishConfirmWindow)
	client.waitFor(contract.FrameTypeStatus, statusIs("confirming"))
	eventually(t, "publish_started", func() bool { return contains(env.app.eventKinds(bid), "publish_started") })

	// 映像・音声（ブラウザのクロックは、7 秒から始まる）。受け口に届いたタグ：再エンコードせず、0 起点に再基準化した時刻
	l := &live{env: env, client: client, bid: bid, account: 1, key: key, peer: peer, originUs: 7_000_000}
	l.sendMedia(90)
	var videoTags, audioTags []rtmpRecord
	for _, record := range mediaOnly(peer.snapshot()) {
		if record.kind == "video" {
			videoTags = append(videoTags, record)
		} else {
			audioTags = append(audioTags, record)
		}
	}
	if len(videoTags) != l.videoSent || len(audioTags) != l.audioSent {
		t.Fatalf("receiver got %d video and %d audio tags; want %d and %d", len(videoTags), len(audioTags), l.videoSent, l.audioSent)
	}
	for i, tag := range videoTags {
		wantFirstByte := byte(0x27) // 非キーフレーム・AVC
		size := 300
		if i%30 == 0 {
			wantFirstByte, size = 0x17, 2000 // キーフレーム・AVC
		}
		if tag.payload[0] != wantFirstByte || tag.payload[1] != 1 {
			t.Fatalf("video tag %d header = %#x %#x; want %#x 0x01", i, tag.payload[0], tag.payload[1], wantFirstByte)
		}
		if !bytes.Equal(tag.payload[5:], videoPayload(i, size)) {
			t.Fatalf("video tag %d: the encoded data differs from what the browser sent (the relay must not touch it)", i)
		}
		if want := uint32(videoTimeUs(i) / 1000); tag.ts != want {
			t.Fatalf("video tag %d time = %d ms; want %d ms (rebased to start at 0)", i, tag.ts, want)
		}
	}
	for j, tag := range audioTags {
		if tag.payload[0] != 0xAF || tag.payload[1] != 1 || !bytes.Equal(tag.payload[2:], audioPayload(j, 40)) {
			t.Fatalf("audio tag %d differs from what the browser sent", j)
		}
		if want := uint32(audioTimeUs(j) / 1000); tag.ts != want {
			t.Fatalf("audio tag %d time = %d ms; want %d ms (rebased to start at 0)", j, tag.ts, want)
		}
	}

	// 受領応答：受け取った最新のメディア時刻（再基準化前の、ブラウザの時刻）。0.5 秒間隔
	l.waitAcked()

	// 状態報告 → 次の心拍に載る。心拍は 2 秒間隔：送出世代・連番・送出中・送出量
	report := `{"backlog_ms":120,"dropped_video_frames":3,"target_kbps":3150,"state":"degraded",` +
		`"events":[{"kind":"bitrate_down","detail":{"from_kbps":4500,"to_kbps":3150}},{"kind":"degraded_started"}]}`
	client.send(contract.FrameTypeReport, false, 0, []byte(report))
	l.sendMedia(1) // 状態報告より後に送ったフレームが届けば、状態報告は処理済み
	carriesReport := func() bool {
		for _, call := range env.app.callsFor("heartbeat", bid) {
			if browser, ok := call.body["browser"].(map[string]any); ok && intOf(t, browser["backlog_ms"]) == 120 {
				return true
			}
		}
		return false
	}
	// 心拍は 2 秒間隔。前の心拍の応答待ちの間は重ねて送らないので、載るまで、2 秒ずつ進める（映像・音声の途絶 5 秒に達しない範囲）
	for round := 0; round < 2 && !carriesReport(); round++ {
		env.clock.Advance(2 * time.Second)
		for waited := 0; waited < 300 && !carriesReport(); waited++ {
			time.Sleep(time.Millisecond)
		}
	}
	eventually(t, "a heartbeat carries the report", carriesReport)
	heartbeats := env.app.callsFor("heartbeat", bid)
	last := heartbeats[len(heartbeats)-1].body
	if intOf(t, last["epoch"]) != 1 || last["publishing"] != true || intOf(t, last["seq"]) < 1 {
		t.Errorf("heartbeat = %v; want epoch 1, publishing true, seq >= 1", last)
	}
	var sent int
	for _, call := range heartbeats {
		sent += intOf(t, call.body["sent_bytes_delta"])
	}
	if sent <= 0 {
		t.Errorf("the heartbeats reported %d bytes sent; want the volume sent to RTMPS", sent)
	}
	for i := 1; i < len(heartbeats); i++ { // 連番は 1 ずつ増える（応答があるたびに）
		if intOf(t, heartbeats[i].body["seq"]) != intOf(t, heartbeats[i-1].body["seq"])+1 {
			t.Errorf("heartbeat seq %v after %v; want +1", heartbeats[i].body["seq"], heartbeats[i-1].body["seq"])
		}
	}
	var withEvents map[string]any
	for _, call := range heartbeats {
		if browser, ok := call.body["browser"].(map[string]any); ok && intOf(t, browser["backlog_ms"]) == 120 {
			withEvents = browser
			break
		}
	}
	events, _ := withEvents["events"].([]any)
	if len(events) != 2 || withEvents["state"] != "degraded" {
		t.Errorf("heartbeat browser report = %v; want state degraded and both events", withEvents)
	}

	// end(user_stop)：送出待ちを送り切ってから RTMPS を切り、事象 session_ended を送る。応答（致命通知）は無い
	tagsBefore := peer.count()
	client.send(contract.FrameTypeEnd, false, 0, []byte(`{"reason":"user_stop"}`))
	if code := client.waitClosed(); code != 1000 {
		t.Errorf("close code = %d; want 1000", code)
	}
	eventually(t, "the receiver saw the connection close", peer.isClosed)
	eventually(t, "session_ended", func() bool { return contains(env.app.eventKinds(bid), "session_ended") })
	if got := peer.count(); got != tagsBefore {
		t.Errorf("receiver tag count changed from %d to %d during the stop", tagsBefore, got)
	}
	if kinds := env.app.eventKinds(bid); fmt.Sprint(kinds) != "[publish_started session_ended]" {
		t.Errorf("events = %v; want [publish_started session_ended]", kinds)
	}
	if fatals := client.fatals(); len(fatals) != 0 {
		t.Errorf("fatals = %v; a user's own stop is not answered with a fatal", fatals)
	}
	eventually(t, "the session left the registry", func() bool { return env.relay.Registry().Count() == 0 })
	env.assertNoSecretsLogged()
	if !strings.Contains(env.logs.String(), "chunkSize") {
		t.Log("note: the go-rtmp chunk size line did not appear in the log (it is logged below the production level)")
	}
}

// 中継の再起動後などで、復帰の接続から始まる場合（取り込みセッションが無い）：照合の状態が live なら、accepted は resume=true・
// 確定済みのプロファイル。start のあと、準備を呼び直し、接続し、キーフレームを要求する
func TestAResumeHelloToARestartedRelayRebuildsTheSession(t *testing.T) {
	env := newRelayEnv(t)
	bid := broadcastID(5)
	env.app.addTicket("dummy-ticket-resume-SECRET", bid, "live", accountKey(5))
	client := env.dial()
	client.hello("dummy-ticket-resume-SECRET")
	accepted := client.waitFor(contract.FrameTypeAccepted, nil).json()
	if accepted["state"] != "live" || accepted["resume"] != true || accepted["profile"] != "720p" {
		t.Fatalf("accepted = %v; want state live, resume true, profile 720p", accepted)
	}
	client.send(contract.FrameTypeStart, false, 0, startBody("720p"))
	key := streamKeyOf(bid)
	eventually(t, "the relay called provision again and connected", func() bool { return env.rtmp.peerByKey(key) != nil })
	if provisions := env.app.callsFor("provision", bid); len(provisions) != 1 {
		t.Fatalf("provision calls = %d; want 1", len(provisions))
	}
	client.waitFor(contract.FrameTypeKeyframeRequest, nil)

	// キーフレームから送り直す。キーフレームの到着をもって復帰（事象 resumed）
	l := &live{env: env, client: client, bid: bid, account: 5, key: key, peer: env.rtmp.peerByKey(key), originUs: 0}
	l.sendMedia(10)
	eventually(t, "resumed was reported", func() bool { return contains(env.app.eventKinds(bid), "resumed") })
}

// 心拍の応答が 60 秒得られないと、中継は自ら送出を止める。その手前の 59 秒までは、メディアの転送を続ける
func TestHeartbeatLossStopsTheBroadcastAtSixtySecondsButNotBefore(t *testing.T) {
	env := newRelayEnv(t)
	l := env.startBroadcast(1)
	l.sendMedia(60)

	// 最後に応答を得た時刻を、はっきりさせる：通知（status）を載せた心拍の応答が、ブラウザへ転送されたこと
	env.app.queueNotice(l.bid, map[string]any{"state": "live", "watch_url": watchURL, "warning": nil, "time_limit_notice_seconds": nil, "end_reason": nil})
	env.clock.Advance(2 * time.Second)
	l.client.waitFor(contract.FrameTypeStatus, statusIs("live"))
	anchor := env.clock.Now()

	// アプリケーションが不達になる。2 秒ごとに時計を進め、そのたびに 2 秒ぶんのメディアを送る
	env.app.setDown(true)
	for elapsed := 2 * time.Second; elapsed <= 58*time.Second; elapsed += 2 * time.Second {
		env.clock.Advance(2 * time.Second)
		l.sendMedia(60)
	}
	assertAlive := func(label string, wantElapsed time.Duration) {
		t.Helper()
		if got := env.clock.Now().Sub(anchor); got != wantElapsed {
			t.Fatalf("%s: %v have passed since the last answered heartbeat", label, got)
		}
		if l.peer.isClosed() {
			t.Fatalf("%s: the RTMPS connection was closed", label)
		}
		if fatals := l.client.fatals(); len(fatals) != 0 {
			t.Fatalf("%s: the browser received fatals %v", label, fatals)
		}
	}
	assertAlive("58 seconds", 58*time.Second)

	env.clock.Advance(time.Second) // 59 秒
	l.sendMedia(30)                // 59 秒の時点でも、メディアは RTMPS へ流れる
	assertAlive("59 seconds", 59*time.Second)

	env.clock.Advance(time.Second) // 60 秒
	l.client.waitFor(contract.FrameTypeFatal, func(body map[string]any) bool { return body["code"] == "heartbeat_lost" })
	if code := l.client.waitClosed(); code != 1000 {
		t.Errorf("close code = %d; want 1000", code)
	}
	eventually(t, "the RTMPS connection was cut", l.peer.isClosed)

	// 事象 session_ended は、アプリケーションが不達の間、保持される。復旧したら、再送される
	eventually(t, "the event is waiting to be resent", func() bool { return env.waiter.pendingCount() >= 1 })
	if contains(env.app.eventKinds(l.bid), "session_ended") {
		t.Fatal("session_ended reached the application while it was unreachable")
	}
	env.app.setDown(false)
	env.waiter.fireAll()
	eventually(t, "session_ended was delivered after recovery", func() bool { return contains(env.app.eventKinds(l.bid), "session_ended") })
	env.assertNoSecretsLogged()
}

// アプリケーションが不達の間（60 秒未満）も、メディアは流れ続け、事象は保持されて、復旧後に発生順で再送される
func TestMediaContinuesAndEventsAreResentWhileTheApplicationIsUnreachable(t *testing.T) {
	env := newRelayEnv(t)
	l := env.startBroadcast(1)
	l.sendMedia(30)
	env.app.setDown(true)

	// 映像・音声が 5 秒届かない：中断（media_stalled）。ブラウザへ、キーフレームを要求する。事象は、アプリケーションへ届かない
	for i := 0; i < 3; i++ {
		env.clock.Advance(2 * time.Second)
	}
	l.client.waitFor(contract.FrameTypeKeyframeRequest, nil)
	stalledAt := env.clock.Now()

	// ブラウザがキーフレームから送り直す：復帰（resumed）。メディアは受け口へ流れ続ける
	tagsBefore := l.peer.count()
	l.client.send(contract.FrameTypeVideo, true, l.originUs+videoTimeUs(l.videoSent), videoPayload(l.videoSent, 2000))
	l.videoSent++
	eventually(t, "media flows to the receiver during the outage", func() bool { return l.peer.count() > tagsBefore })
	l.sendMedia(30)
	env.clock.Advance(2 * time.Second)
	l.sendMedia(30)

	eventually(t, "the events are waiting to be resent", func() bool { return env.waiter.pendingCount() >= 1 })
	if kinds := env.app.eventKinds(l.bid); fmt.Sprint(kinds) != "[publish_started]" {
		t.Fatalf("events at the application during the outage = %v; want only the one delivered before", kinds)
	}
	if l.peer.isClosed() {
		t.Fatal("the RTMPS connection was closed during the outage")
	}

	// 復旧：保持した事象が、発生順に届く。時刻は、観測した時刻のまま（古い時刻）
	env.app.setDown(false)
	env.waiter.fireAll()
	want := "[publish_started interrupted:media_stalled resumed]"
	eventually(t, "the held events were resent in order", func() bool { return fmt.Sprint(env.app.eventKinds(l.bid)) == want })
	for _, call := range env.app.callsFor("event", l.bid) {
		if call.body["kind"] != "interrupted" {
			continue
		}
		at, err := time.Parse(timeLayout, call.body["at"].(string))
		if err != nil {
			t.Fatalf("event time %q: %v", call.body["at"], err)
		}
		if at.After(stalledAt) || !at.After(stalledAt.Add(-10*time.Second)) {
			t.Errorf("event time = %v; want the time it was observed (not later than %v)", at, stalledAt)
		}
	}
	// 復旧後は、心拍の応答も戻る
	before := len(env.app.callsOf("heartbeat"))
	env.clock.Advance(2 * time.Second)
	eventually(t, "heartbeats resume", func() bool { return len(env.app.callsOf("heartbeat")) > before })
}

// ブラウザの切断 → 復帰：RTMPS の接続は保持される。再接続（新しい世代）で、古い接続は排除され、時刻が連続する
// （ブラウザのクロックが 0 から数え直しでも、出力は戻らず、空白は詰まる）
func TestBrowserDisconnectAndResumeKeepTheOutputTimelineContinuous(t *testing.T) {
	env := newRelayEnv(t)
	l := env.startBroadcast(1)
	l.sendMedia(60)
	beforeResume := mediaOnly(l.peer.snapshot())
	var maxOutMs uint32
	var maxOutUs uint64
	for _, tag := range beforeResume {
		maxOutMs = max(maxOutMs, tag.ts)
	}
	maxOutUs = max(videoTimeUs(l.videoSent-1), audioTimeUs(l.audioSent-1)) // 起点（最初のフレームの時刻）からの経過

	// ブラウザが切れる（タブを閉じる・回線の喪失）：中断。RTMPS は保持
	l.client.close()
	eventually(t, "the interruption was reported", func() bool { return contains(env.app.eventKinds(l.bid), "interrupted:browser_disconnected") })
	if l.peer.isClosed() {
		t.Fatal("the RTMPS connection was closed when the browser disconnected")
	}

	// 新しい接続チケットで復帰：accepted は resume=true・確定済みのプロファイル。start を再送すると、キーフレームを要求される
	env.app.addTicket("dummy-ticket-resume-2-SECRET", l.bid, "interrupted", accountKey(1))
	second := env.dial()
	second.hello("dummy-ticket-resume-2-SECRET")
	accepted := second.waitFor(contract.FrameTypeAccepted, nil).json()
	if accepted["resume"] != true || accepted["profile"] != "720p" || accepted["state"] != "interrupted" {
		t.Fatalf("accepted = %v; want resume true, profile 720p, state interrupted", accepted)
	}
	second.send(contract.FrameTypeStart, false, 0, startBody("720p"))
	second.waitFor(contract.FrameTypeKeyframeRequest, nil)

	// キーフレームから送る。ブラウザのクロックは 0 から（ページの再読み込み）
	resumed := &live{env: env, client: second, bid: l.bid, account: 1, key: l.key, peer: l.peer, originUs: 0}
	tagsBefore := l.peer.count()
	resumed.pushMedia(60)
	eventually(t, "the resumed media reached the receiver", func() bool { return l.peer.count() >= tagsBefore+resumed.videoSent+resumed.audioSent })
	eventually(t, "resumed was reported", func() bool { return contains(env.app.eventKinds(l.bid), "resumed") })

	after := mediaOnly(l.peer.snapshot())[len(beforeResume):]
	var afterVideo, afterAudio []rtmpRecord
	for _, tag := range after {
		if tag.kind == "video" {
			afterVideo = append(afterVideo, tag)
		} else {
			afterAudio = append(afterAudio, tag)
		}
	}
	// 復帰後の最初のキーフレームは、復帰前の最大の出力の時刻から続く（空白を詰める）。以後、間隔を保つ
	if first := afterVideo[0].ts; first != maxOutMs {
		t.Errorf("first video time after the resume = %d ms; want %d ms (continuing from the largest output before)", first, maxOutMs)
	}
	for k, tag := range afterVideo {
		if want := uint32((maxOutUs + videoTimeUs(k)) / 1000); tag.ts != want {
			t.Fatalf("resumed video tag %d time = %d ms; want %d ms", k, tag.ts, want)
		}
	}
	for j, tag := range afterAudio {
		if want := uint32((maxOutUs + audioTimeUs(j)) / 1000); tag.ts != want {
			t.Fatalf("resumed audio tag %d time = %d ms; want %d ms (the same correction as video)", j, tag.ts, want)
		}
	}
	// 全体を通して、種類ごとに、時刻が戻らない
	last := map[string]uint32{}
	for i, tag := range mediaOnly(l.peer.snapshot()) {
		if tag.ts < last[tag.kind] {
			t.Fatalf("tag %d (%s) time %d went back from %d", i, tag.kind, tag.ts, last[tag.kind])
		}
		last[tag.kind] = tag.ts
	}
	if kinds := env.app.eventKinds(l.bid); fmt.Sprint(kinds) != "[publish_started interrupted:browser_disconnected resumed]" {
		t.Errorf("events = %v; want [publish_started interrupted:browser_disconnected resumed]", kinds)
	}
	if l.peer.isClosed() {
		t.Error("the RTMPS connection was closed across the resume")
	}
}

// アプリケーションが心拍の応答で停止を指示すると、送出待ちを送り切ってから切り、ブラウザへ status(ended)・fatal(broadcast_ended)
func TestAStopCommandFromTheApplicationEndsTheBroadcast(t *testing.T) {
	env := newRelayEnv(t)
	l := env.startBroadcast(1)
	l.sendMedia(30)
	env.app.stopHeartbeatsWith(l.bid, "admin_stop")
	env.clock.Advance(2 * time.Second)
	ended := l.client.waitFor(contract.FrameTypeStatus, statusIs("ended")).json()
	if ended["end_reason"] != "admin_stop" {
		t.Errorf("status(ended) = %v; want end_reason admin_stop", ended)
	}
	l.client.waitFor(contract.FrameTypeFatal, func(body map[string]any) bool { return body["code"] == "broadcast_ended" })
	if code := l.client.waitClosed(); code != 1000 {
		t.Errorf("close code = %d; want 1000", code)
	}
	eventually(t, "the receiver saw the connection close", l.peer.isClosed)
	eventually(t, "session_ended", func() bool { return contains(env.app.eventKinds(l.bid), "session_ended") })
}

// 通知（心拍の応答の notices）は、順に status としてブラウザへ転送される
func TestNoticesFromTheApplicationAreForwardedToTheBrowser(t *testing.T) {
	env := newRelayEnv(t)
	l := env.startBroadcast(1)
	env.app.queueNotice(l.bid, map[string]any{"state": "live", "watch_url": watchURL, "warning": nil, "time_limit_notice_seconds": nil, "end_reason": nil})
	env.app.queueNotice(l.bid, map[string]any{"state": "live", "watch_url": watchURL, "warning": "youtube_stream_unhealthy", "time_limit_notice_seconds": 300, "end_reason": nil})
	env.clock.Advance(2 * time.Second)
	l.client.waitFor(contract.FrameTypeStatus, statusIs("live"))
	warning := l.client.waitFor(contract.FrameTypeStatus, statusIs("live")).json()
	if warning["warning"] != "youtube_stream_unhealthy" || intOf(t, warning["time_limit_notice_seconds"]) != 300 {
		t.Errorf("second notice = %v; want the warning and the time limit notice", warning)
	}
	encoded, _ := json.Marshal(warning)
	if !strings.Contains(string(encoded), "watch_url") {
		t.Errorf("status = %s; want the watch URL in every status after preparation", encoded)
	}
}
