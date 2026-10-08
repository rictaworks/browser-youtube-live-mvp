package session

import (
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
)

// 取り込みセッションの正常な流れ：計測 → 開始（準備）→ RTMPS の接続 → 確認の窓 → 送出 → 停止。
// 契約 ws-protocol.md の 7.1、requirements.md 10.1・11.8・11.10・23.2。

// summarize は、設定のタグ（時刻 0 のシーケンスヘッダ）を除いた、メディアのタグを「種類@ミリ秒」の文字列にする。
// 映像は、キーフレームを vK、差分を vp。音声は a。
func summarize(tags []publishedTag) []string {
	var out []string
	for _, tag := range mediaTags(tags) {
		switch tag.kind {
		case "video":
			kind := "vp"
			if tag.payload[0]>>4 == 1 {
				kind = "vK"
			}
			out = append(out, fmt.Sprintf("%s@%d", kind, tag.ts))
		case "audio":
			out = append(out, fmt.Sprintf("a@%d", tag.ts))
		}
	}
	return out
}

func expectTags(t *testing.T, pub *fakePublisher, want ...string) {
	t.Helper()
	got := summarize(pub.tags())
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("media tags = %v\nwant         %v", got, want)
	}
}

// ---- 回線計測 ----

func TestProbeResultIsSentThreeSecondsAfterTheFirstProbe(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	session := h.mustSession(idA)

	// メッセージ全体で 1,000,000 バイトを、3 秒の間に 3 回 = 3,000,000 バイト = 8,000 kbps
	conn.probe(1_000_000 - contract.WSFrameHeaderBytes)
	h.settle()
	if session.State() != StateProbing {
		t.Fatalf("state = %v, want probing", session.State())
	}
	h.clock.Advance(time.Second)
	conn.probe(1_000_000 - contract.WSFrameHeaderBytes)
	h.clock.Advance(time.Second)
	conn.probe(1_000_000 - contract.WSFrameHeaderBytes)
	h.clock.Advance(time.Second - time.Millisecond)
	h.settle()
	if got := conn.link.ofType(t, contract.FrameTypeProbeResult); len(got) != 0 {
		t.Fatalf("probe_result was sent after 2.999 seconds")
	}

	h.clock.Advance(time.Millisecond)
	h.settle()
	results := conn.link.ofType(t, contract.FrameTypeProbeResult)
	if len(results) != 1 {
		t.Fatalf("probe_result count = %d, want 1 (at exactly 3 seconds)", len(results))
	}
	assertBodyJSON(t, results[0], `{"throughput_kbps":8000}`)

	// 3 秒より後の計測データは数えず、結果も 1 回だけ
	conn.probe(1_000_000 - contract.WSFrameHeaderBytes)
	h.clock.Advance(10 * time.Second)
	h.settle()
	if got := conn.link.ofType(t, contract.FrameTypeProbeResult); len(got) != 1 {
		t.Fatalf("probe_result count = %d after more probes, want 1", len(got))
	}
}

func TestProbeCountsTheWholeMessageIncludingTheHeader(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	conn.probe(32768 - contract.WSFrameHeaderBytes) // 32,768 バイト × 8 ÷ 3,000 = 87.38 → 87
	h.settle()
	h.clock.Advance(3 * time.Second)
	h.settle()
	results := conn.link.ofType(t, contract.FrameTypeProbeResult)
	if len(results) != 1 {
		t.Fatalf("probe_result count = %d", len(results))
	}
	assertBodyJSON(t, results[0], `{"throughput_kbps":87}`)
}

func TestNoProbeResultWithoutProbeData(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	for i := 0; i < 5; i++ {
		h.clock.Advance(2 * time.Second)
		h.settle()
	}
	if got := conn.link.ofType(t, contract.FrameTypeProbeResult); len(got) != 0 {
		t.Fatalf("probe_result was sent without any probe data")
	}
}

// 計測データの受領量が異常に多い（ErrAbnormal）ときは、受信量の超過（bitrate_exceeded）と同じに扱う。
func TestAbnormalProbeVolumeIsTreatedAsExcessiveIngress(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	session := h.mustSession(idA)

	// 3 秒の上限は 9,000 kbps = 3,375,000 バイト。3,500,000 バイトは、10 秒平均の上限（11,250,000 バイト）には届かない
	conn.probe(1_750_000 - contract.WSFrameHeaderBytes)
	conn.probe(1_750_000 - contract.WSFrameHeaderBytes)
	h.settle()
	if session.State() == StateClosed {
		t.Fatal("the session closed before the measurement was due")
	}
	h.clock.Advance(3 * time.Second)
	h.settle()
	h.waitDone(session)

	expectSequence(t, conn.link, "accepted", "fatal:bitrate_exceeded", "close:1000")
	if got := fmt.Sprint(h.ev.kinds()); got != "[relay_disconnected session_ended]" {
		t.Fatalf("events = %s", got)
	}
}

// ---- 開始（準備）と送出の開始 ----

func TestStartProvisionsConnectsAndWritesTheDecoderConfigurationFirst(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 3, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()

	conn.start("720p")
	h.settle()

	if got := h.be.provisions(); len(got) != 1 || got[0] != (provisionCall{broadcastID: idA, epoch: 3, profile: contract.Profile720p}) {
		t.Fatalf("provision calls = %+v, want one for %s epoch 3 720p", got, idA)
	}
	expectSequence(t, conn.link, "accepted", "status:awaiting_media")
	assertBodyJSON(t, conn.link.ofType(t, contract.FrameTypeStatus)[0],
		`{"state":"awaiting_media","watch_url":"`+dummyWatchURL+`","warning":null,"time_limit_notice_seconds":null,"end_reason":null}`)

	if got := h.fac.openCount(); got != 1 {
		t.Fatalf("Open calls = %d, want 1", got)
	}
	h.fac.mu.Lock()
	open := h.fac.opens[0]
	h.fac.mu.Unlock()
	if open.url != dummyIngestURL || open.key != dummyStreamKey || !open.logger {
		t.Fatalf("Open request = %+v, want the provisioned destination, the key and a logger", open)
	}

	// 映像設定・音声設定・メタデータが、最初のメディアフレームより前に、時刻 0 で届く
	tags := h.fac.last(t).tags()
	if len(tags) != 3 || tags[0].kind != "meta" || tags[1].kind != "video" || tags[2].kind != "audio" {
		t.Fatalf("tags written before any media = %v", describeTags(tags))
	}
	if tags[1].ts != 0 || tags[2].ts != 0 {
		t.Fatalf("decoder configuration timestamps = %d, %d; want 0, 0", tags[1].ts, tags[2].ts)
	}
	wantVideo, _ := base64.StdEncoding.DecodeString(sampleVideoDescriptionB64)
	// FLV の VideoData: キーフレーム・AVC（0x17）、シーケンスヘッダ（0）、構成時間 0（3 バイト）
	if !bytes.Equal(tags[1].payload[:5], []byte{0x17, 0x00, 0x00, 0x00, 0x00}) || !bytes.Equal(tags[1].payload[5:], wantVideo) {
		t.Fatalf("video configuration tag = % x", tags[1].payload)
	}
	// AudioData: AAC（0xAF）、シーケンスヘッダ（0）、AudioSpecificConfig（12 10）
	if !bytes.Equal(tags[2].payload, []byte{0xAF, 0x00, 0x12, 0x10}) {
		t.Fatalf("audio configuration tag = % x", tags[2].payload)
	}
	if !bytes.Contains(tags[0].payload, []byte("onMetaData")) {
		t.Fatalf("the first tag is not onMetaData: % x", tags[0].payload)
	}

	// 接続が保たれると確かめられるまで、送出の開始を知らせない
	if got := h.ev.kinds(); len(got) != 0 {
		t.Fatalf("events = %v: publish_started must wait for the connection to survive the window", got)
	}
	if h.mustSession(idA).State() != StatePreparing {
		t.Fatalf("state = %v, want preparing", h.mustSession(idA).State())
	}

	h.clock.Advance(h.opts.PublishConfirmWindow - time.Millisecond)
	h.settle()
	if got := h.ev.kinds(); len(got) != 0 {
		t.Fatalf("events = %v just before the window ended", got)
	}

	h.clock.Advance(time.Millisecond)
	h.settle()
	if got := h.ev.kinds(); fmt.Sprint(got) != "[publish_started]" {
		t.Fatalf("events = %v, want [publish_started]", got)
	}
	expectSequence(t, conn.link, "accepted", "status:awaiting_media", "status:confirming")
	assertBodyJSON(t, conn.link.ofType(t, contract.FrameTypeStatus)[1],
		`{"state":"confirming","watch_url":"`+dummyWatchURL+`","warning":null,"time_limit_notice_seconds":null,"end_reason":null}`)
	if h.mustSession(idA).State() != StateStreaming {
		t.Fatalf("state = %v, want streaming", h.mustSession(idA).State())
	}
	if e := h.ev.all()[0]; e.id != idA || e.req.Epoch != 3 {
		t.Fatalf("event = %+v, want broadcast %s epoch 3", e, idA)
	}
}

func describeTags(tags []publishedTag) []string {
	out := make([]string, 0, len(tags))
	for _, tag := range tags {
		out = append(out, fmt.Sprintf("%s@%d(%d bytes)", tag.kind, tag.ts, len(tag.payload)))
	}
	return out
}

// 準備は数十秒かかり得る。その間も、ブラウザとの接続（心拍・状態報告）を止めない。
func TestProvisioningDoesNotBlockTheSession(t *testing.T) {
	h := newHarness(t)
	h.be.provisionGate = make(chan struct{})
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	conn.start("720p")
	<-h.be.provisionEntered

	// 準備の最中に、状態報告を受け、心拍を送る
	conn.report(reportJSON(`[{"kind":"source_added","detail":{"source":"camera"}}]`, func(m map[string]string) { m["state"] = `"live"` }))
	// 状態報告を取り込み終えてから、時計を進める。待たずに進めると、取り込みセッションのゴルーチンが遅れた実行環境では、
	// 時計の起床と待ち行列の状態報告が同時に待ち状態になり、どちらが先に選ばれるかが決まらない
	// （起床が先だと、状態報告を載せない心拍が先に送られる）
	h.barrierAll()
	h.clock.Advance(2 * time.Second)
	h.barrierAll()
	deadline := time.Now().Add(5 * time.Second)
	for len(h.be.heartbeats()) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("no heartbeat was sent while the preparation was running")
		}
		time.Sleep(time.Millisecond)
	}
	beat := h.be.heartbeats()[0]
	if beat.Browser == nil || len(beat.Browser.Events) != 1 {
		t.Fatalf("the heartbeat sent during preparation does not carry the browser report: %+v", beat.Browser)
	}

	close(h.be.provisionGate)
	h.settle()
	expectSequence(t, conn.link, "accepted", "status:awaiting_media")
}

func TestProvisioningFailuresEndTheBroadcast(t *testing.T) {
	apiError := func(code string, status int, reason contract.EndReason) error {
		return backend.NewAPIError(contract.InternalCallProvision, status, code, reason)
	}
	cases := []struct {
		name       string
		err        error
		wantStatus string
	}{
		{"終了済み", apiError("broadcast_ended", 409, contract.EndReasonStartTimeout), string(contract.EndReasonStartTimeout)},
		{"先行配信が未清算", apiError("prior_unsettled", 422, contract.EndReasonPriorUnsettled), string(contract.EndReasonPriorUnsettled)},
		{"準備の失敗", apiError("prepare_failed", 502, contract.EndReasonPrepareFailed), string(contract.EndReasonPrepareFailed)},
		{"認可の失効", apiError("authorization_revoked", 409, contract.EndReasonAuthorizationRevoked), string(contract.EndReasonAuthorizationRevoked)},
		{"ライブ未有効（準備の失敗として終了）", apiError("live_not_enabled", 409, contract.EndReasonPrepareFailed), string(contract.EndReasonPrepareFailed)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newHarness(t)
			h.be.setProvision(func(provisionCall) (backend.ProvisionResult, error) { return backend.ProvisionResult{}, c.err })
			h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
			conn := h.connect()
			conn.hello("t1")
			h.settle()
			session := h.mustSession(idA)
			conn.start("720p")
			h.settle()
			h.waitDone(session)

			expectSequence(t, conn.link, "accepted", "status:ended", "fatal:broadcast_ended", "close:1000")
			var status struct {
				State     string  `json:"state"`
				EndReason *string `json:"end_reason"`
			}
			decodeJSON(t, conn.link.ofType(t, contract.FrameTypeStatus)[0].Body, &status)
			if status.EndReason == nil || *status.EndReason != c.wantStatus {
				t.Fatalf("status = %+v, want end_reason %s", status, c.wantStatus)
			}
			if got := h.fac.openCount(); got != 0 {
				t.Fatalf("a publisher was opened after the preparation failed")
			}
			if got := fmt.Sprint(h.ev.kinds()); got != "[session_ended]" {
				t.Fatalf("events = %s", got)
			}
		})
	}
}

func TestProvisioningFailureWithoutAnEndReasonStillClosesTheConnection(t *testing.T) {
	h := newHarness(t)
	// 契約では provision の失敗は終了理由を持つ。持たない応答でも、終了の status は作らず（理由を創作しない）、閉じる
	h.be.setProvision(func(provisionCall) (backend.ProvisionResult, error) {
		return backend.ProvisionResult{}, fmt.Errorf("%w", backend.ErrBroadcastEnded)
	})
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	session := h.mustSession(idA)
	conn.start("720p")
	h.settle()
	h.waitDone(session)
	expectSequence(t, conn.link, "accepted", "fatal:broadcast_ended", "close:1000")
}

func TestUnavailableProvisioningIsRetriedWithBackoff(t *testing.T) {
	h := newHarness(t)
	var attempts []time.Time
	h.be.setProvision(func(provisionCall) (backend.ProvisionResult, error) {
		attempts = append(attempts, h.clock.Now())
		if len(attempts) <= 2 {
			return backend.ProvisionResult{}, unreachable()
		}
		return defaultProvisionResult(), nil
	})
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	start := h.clock.Now()
	conn.start("720p")
	h.settle()
	expectSequence(t, conn.link, "accepted") // 失敗の間は、何も伝えない

	h.clock.Advance(h.opts.RedialInitial) // 最初の待機
	h.settle()
	h.clock.Advance(2 * h.opts.RedialInitial) // 次の待機（倍）
	h.settle()
	expectSequence(t, conn.link, "accepted", "status:awaiting_media")
	if len(attempts) != 3 {
		t.Fatalf("provision attempts = %d, want 3", len(attempts))
	}
	if d := attempts[1].Sub(start); d != h.opts.RedialInitial {
		t.Fatalf("second attempt after %v, want %v", d, h.opts.RedialInitial)
	}
	if d := attempts[2].Sub(attempts[1]); d != 2*h.opts.RedialInitial {
		t.Fatalf("third attempt %v after the second, want %v", d, 2*h.opts.RedialInitial)
	}
}

// 自分が世代を進めたために古くなった準備の失敗は、配信の終わりではない。新しい世代で、やり直す。
func TestStaleEpochOfAnOlderProvisionDoesNotEndTheSession(t *testing.T) {
	h := newHarness(t)
	h.be.provisionGate = make(chan struct{})
	h.be.setProvision(func(call provisionCall) (backend.ProvisionResult, error) {
		if call.epoch == 1 {
			return backend.ProvisionResult{}, backend.NewAPIError(contract.InternalCallProvision, 409, "stale_epoch", "")
		}
		return defaultProvisionResult(), nil
	})
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	first := h.connect()
	first.hello("t1")
	h.settle()
	first.start("720p")
	<-h.be.provisionEntered

	// 準備の最中に、新しい世代の接続を照合する（アプリケーションの世代が進む）
	h.be.addTicket("t2", verifyResult(idA, 2, contract.BroadcastStateAwaitingMedia))
	second := h.connect()
	second.hello("t2")
	deadline := time.Now().Add(5 * time.Second)
	for second.link.isClosed() || len(second.link.messages(t)) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("the second connection was not accepted")
		}
		time.Sleep(time.Millisecond)
	}
	close(h.be.provisionGate) // 世代 1 の準備が、stale_epoch で戻る
	h.settle()
	session := h.mustSession(idA)
	if session.State() == StateClosed {
		t.Fatal("the session ended on a stale_epoch caused by its own epoch change")
	}

	// 新しい接続の開始通知で、新しい世代の準備をやり直す
	second.start("720p")
	h.settle()
	calls := h.be.provisions()
	if len(calls) != 2 || calls[1].epoch != 2 {
		t.Fatalf("provision calls = %+v, want a second call with epoch 2", calls)
	}
	expectSequence(t, second.link, "accepted", "status:awaiting_media")
}

func TestStaleEpochOfTheCurrentProvisionEndsTheSession(t *testing.T) {
	h := newHarness(t)
	h.be.setProvision(func(provisionCall) (backend.ProvisionResult, error) {
		return backend.ProvisionResult{}, backend.NewAPIError(contract.InternalCallProvision, 409, "stale_epoch", "")
	})
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	session := h.mustSession(idA)
	conn.start("720p")
	h.settle()
	h.waitDone(session)
	expectSequence(t, conn.link, "accepted", "fatal:stale_epoch", "close:1000")
}

func TestInvalidStartIsDiscarded(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()

	conn.startBody("not json")
	conn.startBody(startJSON("720p", func(m map[string]string) { m["width"] = "640" }))
	h.settle()
	if got := h.be.provisions(); len(got) != 0 {
		t.Fatalf("an invalid start triggered a provision: %v", got)
	}
	expectSequence(t, conn.link, "accepted")

	conn.start("720p") // そのあと、有効な開始通知は、通常どおり
	h.settle()
	if got := h.be.provisions(); len(got) != 1 {
		t.Fatalf("provision calls = %v", got)
	}
}

func TestStartWithADifferentProfileThanTheConfirmedOneIsDiscarded(t *testing.T) {
	h := newHarness(t)
	conn := h.resumeConnect("t1", idA, 2, contract.BroadcastStateLive) // 確定済みのプロファイルは 720p
	conn.start("480p")
	h.settle()
	if got := h.be.provisions(); len(got) != 0 {
		t.Fatalf("a start with another profile was accepted: %v", got)
	}
}

func TestInvalidDecoderConfigurationIsDiscarded(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	// base64 としては正しいが、AVCDecoderConfigurationRecord ではない（版が 1 ではない）
	conn.startBody(startJSON("720p", func(m map[string]string) {
		m["vdesc"] = `"` + base64.StdEncoding.EncodeToString([]byte{9, 9, 9, 9, 9, 9, 9, 9}) + `"`
	}))
	// 音声設定が短すぎる
	conn.startBody(startJSON("720p", func(m map[string]string) { m["adesc"] = `"` + base64.StdEncoding.EncodeToString([]byte{0x12}) + `"` }))
	h.settle()
	if got := h.be.provisions(); len(got) != 0 {
		t.Fatalf("an invalid decoder configuration triggered a provision: %v", got)
	}
}

func TestRejectedDestinationIsNotRetried(t *testing.T) {
	h := newHarness(t)
	h.fac.failNext(fmt.Errorf("%w: host", ErrDestinationRejected))
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	session := h.mustSession(idA)
	conn.start("720p")
	h.settle()
	h.waitDone(session)

	if got := h.fac.openCount(); got != 1 {
		t.Fatalf("Open calls = %d, want 1 (a rejected destination is not retried)", got)
	}
	expectSequence(t, conn.link, "accepted", "status:awaiting_media", "fatal:publish_failed", "close:1000")
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_failed session_ended]" {
		t.Fatalf("events = %s", got)
	}
}

func TestConnectionFailuresAreRetriedWithBackoff(t *testing.T) {
	h := newHarness(t)
	h.fac.failNext(errors.New("connection refused"), errors.New("connection refused"))
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	conn.start("720p")
	h.settle()
	if got := h.fac.openCount(); got != 1 {
		t.Fatalf("Open calls = %d, want 1 right after the start", got)
	}
	h.clock.Advance(h.opts.RedialInitial - time.Millisecond)
	h.settle()
	if got := h.fac.openCount(); got != 1 {
		t.Fatalf("Open calls = %d before the first wait ended", got)
	}
	h.clock.Advance(time.Millisecond)
	h.settle()
	if got := h.fac.openCount(); got != 2 {
		t.Fatalf("Open calls = %d, want 2 after 500 ms", got)
	}
	h.clock.Advance(2*h.opts.RedialInitial - time.Millisecond)
	h.settle()
	if got := h.fac.openCount(); got != 2 {
		t.Fatalf("Open calls = %d before the doubled wait ended", got)
	}
	h.clock.Advance(time.Millisecond)
	h.settle()
	if got := h.fac.openCount(); got != 3 {
		t.Fatalf("Open calls = %d, want 3 after 500 ms + 1 s", got)
	}
	// 失敗の間は、ブラウザにも、アプリケーションにも、何も知らせない
	expectSequence(t, conn.link, "accepted", "status:awaiting_media")
	if got := h.ev.kinds(); len(got) != 0 {
		t.Fatalf("events = %v", got)
	}
}

// 応答しない受け口との接続は、ゴルーチンを 1 つ残すので、再接続の試行回数に上限を持たせる（#19 のレビューの申し送り）。
func TestRedialAttemptsAreCapped(t *testing.T) {
	h := newHarness(t, func(o *Options) { o.MaxRedialAttempts = 3 })
	h.fac.failNext(errors.New("refused"), errors.New("refused"), errors.New("refused"), errors.New("refused"), errors.New("refused"))
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	session := h.mustSession(idA)
	conn.start("720p")
	h.settle()
	for i := 0; i < 10 && session.State() != StateClosed; i++ {
		h.clock.Advance(h.opts.RedialMax)
		h.settle()
	}
	h.waitDone(session)
	if got := h.fac.openCount(); got != 3 {
		t.Fatalf("Open calls = %d, want exactly MaxRedialAttempts (3)", got)
	}
	expectSequence(t, conn.link, "accepted", "status:awaiting_media", "fatal:publish_failed", "close:1000")
}

// ---- メディア ----

func TestMediaIsForwardedWithoutReencodingAndRebasedToZero(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)

	video := videoPayload(0xA1, 40)
	s.conn.audio(0, audioPayload(0xB1, 20))
	s.conn.video(0, true, video)
	s.conn.video(33333, false, videoPayload(0xA2, 30))
	s.conn.audio(23220, audioPayload(0xB2, 21))
	s.conn.audio(46440, audioPayload(0xB3, 22))
	s.conn.video(66667, false, videoPayload(0xA3, 31))
	h.settle()

	expectTags(t, s.pub, "a@0", "vK@0", "vp@33", "a@23", "a@46", "vp@66")
	media := mediaTags(s.pub.tags())
	// 符号化データは、そのまま（FLV の見出しを前に付けただけ）
	if p := media[1].payload; p[0] != 0x17 || p[1] != 0x01 || !bytes.Equal(p[5:], video) {
		t.Fatalf("keyframe tag = % x", p)
	}
	if p := media[2].payload; p[0] != 0x27 || p[1] != 0x01 || !bytes.Equal(p[5:], videoPayload(0xA2, 30)) {
		t.Fatalf("inter frame tag = % x", p)
	}
	if p := media[0].payload; p[0] != 0xAF || p[1] != 0x01 || !bytes.Equal(p[2:], audioPayload(0xB1, 20)) {
		t.Fatalf("audio tag = % x", p)
	}
}

func TestTheFirstMediaFrameIsTheOriginWhateverItsTime(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	// ブラウザのメディアクロックが 0 から始まるとは限らない
	s.conn.audio(5_000_000, audioPayload(1, 10))
	s.conn.video(5_000_000, true, videoPayload(1, 10))
	s.conn.video(5_033_333, false, videoPayload(2, 10))
	h.settle()
	expectTags(t, s.pub, "a@0", "vK@0", "vp@33")
}

func TestMediaBeforeTheConfirmingStatusIsDiscarded(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	conn.start("720p")
	h.settle() // status(confirming) は、まだ

	conn.video(0, true, videoPayload(1, 10))
	conn.audio(0, audioPayload(1, 10))
	h.settle()
	expectTags(t, h.fac.last(t)) // 何も送出しない

	h.clock.Advance(h.opts.PublishConfirmWindow)
	h.settle()
	conn.video(0, true, videoPayload(1, 10))
	conn.audio(0, audioPayload(1, 10))
	h.settle()
	expectTags(t, h.fac.last(t), "vK@0", "a@0")
}

func TestEmptyMediaPayloadIsDiscarded(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.video(0, true, nil)
	s.conn.audio(0, nil)
	s.conn.audio(0, audioPayload(1, 5))
	h.settle()
	expectTags(t, s.pub, "a@0")
	if s.sess.State() != StateStreaming {
		t.Fatalf("state = %v", s.sess.State())
	}
}

func TestTimeRegressionIsDiscardedPerKind(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.video(100_000, true, videoPayload(1, 10))
	s.conn.video(50_000, false, videoPayload(2, 10))  // 逆行 → 破棄
	s.conn.video(100_000, false, videoPayload(3, 10)) // 同じ時刻は、逆行ではない
	s.conn.audio(40_000, audioPayload(1, 10))         // 種別ごとに独立
	s.conn.audio(30_000, audioPayload(2, 10))         // 逆行 → 破棄
	s.conn.video(900_000, false, videoPayload(4, 10)) // 前方への飛びは、受け入れる
	h.settle()
	// 起点は最初のフレーム（映像 100,000 µs）。音声 40,000 は起点より前なので 0 に引き上げられる
	expectTags(t, s.pub, "vK@0", "vp@0", "a@0", "vp@800")
}

func TestMessagesFromASupersededConnectionAreIgnored(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)

	// 世代が進み、古い接続が閉じられたあとに届いたメッセージは、無視する
	h.be.addTicket("t2", verifyResult(idA, 2, contract.BroadcastStateConfirming))
	newer := h.connect()
	newer.hello("t2")
	h.settle()
	s.conn.audio(0, audioPayload(1, 10))
	s.conn.video(0, true, videoPayload(1, 10))
	s.conn.end("user_stop")
	h.settle()
	expectTags(t, s.pub)
	if s.sess.State() == StateClosed {
		t.Fatal("a stop from a superseded connection ended the session")
	}
}

// ---- 受領応答 ----

func TestAckIsSentEveryHalfSecondOnceBothKindsHaveArrived(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)

	h.clock.Advance(h.opts.AckInterval)
	h.settle()
	if got := s.conn.link.ofType(t, contract.FrameTypeAck); len(got) != 0 {
		t.Fatalf("an ack was sent before any media arrived (a 0 must not be sent)")
	}

	s.conn.video(100_000, true, videoPayload(1, 10))
	h.settle()
	h.clock.Advance(h.opts.AckInterval)
	h.settle()
	if got := s.conn.link.ofType(t, contract.FrameTypeAck); len(got) != 0 {
		t.Fatalf("an ack was sent with only the video seen (the audio time would be 0)")
	}

	s.conn.audio(80_000, audioPayload(1, 10))
	s.conn.video(133_333, false, videoPayload(2, 10))
	s.conn.audio(103_220, audioPayload(2, 10))
	h.settle()
	h.clock.Advance(h.opts.AckInterval)
	h.settle()
	acks := s.conn.link.ofType(t, contract.FrameTypeAck)
	if len(acks) != 1 {
		t.Fatalf("ack count = %d, want 1", len(acks))
	}
	assertBodyJSON(t, acks[0], `{"video_us":133333,"audio_us":103220}`)

	// 0.5 秒ごと。最新の受領済みの時刻
	s.conn.video(166_666, false, videoPayload(3, 10))
	h.settle()
	h.clock.Advance(h.opts.AckInterval)
	h.settle()
	h.clock.Advance(h.opts.AckInterval)
	h.settle()
	acks = s.conn.link.ofType(t, contract.FrameTypeAck)
	if len(acks) != 3 {
		t.Fatalf("ack count = %d, want 3", len(acks))
	}
	assertBodyJSON(t, acks[1], `{"video_us":166666,"audio_us":103220}`)
	assertBodyJSON(t, acks[2], `{"video_us":166666,"audio_us":103220}`)
}

func TestAckDoesNotCountDiscardedFrames(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.video(100_000, true, videoPayload(1, 10))
	s.conn.audio(100_000, audioPayload(1, 10))
	s.conn.video(10_000, false, videoPayload(2, 10)) // 逆行 → 破棄 → 受領済みにしない
	h.settle()
	h.clock.Advance(h.opts.AckInterval)
	h.settle()
	acks := s.conn.link.ofType(t, contract.FrameTypeAck)
	if len(acks) != 1 {
		t.Fatalf("ack count = %d", len(acks))
	}
	assertBodyJSON(t, acks[0], `{"video_us":100000,"audio_us":100000}`)
}

// ---- 抑制指示 ----

func TestThrottleIsSentWhenThePendingMediaExceedsOneAndAHalfSeconds(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.report(reportJSON(`[]`, func(m map[string]string) { m["target"] = "4500"; m["state"] = `"live"` }))
	s.conn.audio(0, audioPayload(1, 10))
	s.conn.video(0, true, videoPayload(1, 10))
	h.settle()

	s.pub.setPending(1500) // ちょうど 1.5 秒分は、超えていない
	s.conn.audio(23220, audioPayload(2, 10))
	h.settle()
	if got := s.conn.link.ofType(t, contract.FrameTypeThrottle); len(got) != 0 {
		t.Fatalf("throttle was sent at exactly 1500 ms")
	}

	s.pub.setPending(1501)
	s.conn.audio(46440, audioPayload(3, 10))
	h.settle()
	throttles := s.conn.link.ofType(t, contract.FrameTypeThrottle)
	if len(throttles) != 1 {
		t.Fatalf("throttle count = %d, want 1", len(throttles))
	}
	assertBodyJSON(t, throttles[0], `{"target_kbps":3150}`) // 報告された目標 4,500 の 70%

	// 1 秒に 1 回まで
	s.conn.audio(69660, audioPayload(4, 10))
	h.settle()
	h.clock.Advance(999 * time.Millisecond)
	s.conn.audio(92880, audioPayload(5, 10))
	h.settle()
	if got := s.conn.link.ofType(t, contract.FrameTypeThrottle); len(got) != 1 {
		t.Fatalf("throttle count = %d within one second", len(got))
	}
	h.clock.Advance(time.Millisecond)
	s.conn.audio(116100, audioPayload(6, 10))
	h.settle()
	if got := s.conn.link.ofType(t, contract.FrameTypeThrottle); len(got) != 2 {
		t.Fatalf("throttle count = %d after one second, want 2", len(got))
	}
}

func TestThrottleTargetNeverFallsBelowTheProfileFloor(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.report(reportJSON(`[]`, func(m map[string]string) { m["target"] = "3100"; m["state"] = `"live"` })) // 70% は 2,170。720p の下限は 3,000
	s.conn.audio(0, audioPayload(1, 10))
	h.settle()
	s.pub.setPending(2000)
	s.conn.audio(23220, audioPayload(2, 10))
	h.settle()
	throttles := s.conn.link.ofType(t, contract.FrameTypeThrottle)
	if len(throttles) != 1 {
		t.Fatalf("throttle count = %d", len(throttles))
	}
	assertBodyJSON(t, throttles[0], `{"target_kbps":3000}`)
}

func TestThrottleUsesTheStartBitrateBeforeAnyReport(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.audio(0, audioPayload(1, 10))
	h.settle()
	s.pub.setPending(2000)
	s.conn.audio(23220, audioPayload(2, 10))
	h.settle()
	throttles := s.conn.link.ofType(t, contract.FrameTypeThrottle)
	if len(throttles) != 1 {
		t.Fatalf("throttle count = %d", len(throttles))
	}
	assertBodyJSON(t, throttles[0], `{"target_kbps":3150}`) // 開始通知の 4,500 の 70%
}

// ---- 停止 ----

func TestEndDrainsThePublisherAndDiscardsTheKeyAndTheBuffers(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.audio(0, audioPayload(1, 10))
	h.settle()

	s.conn.end("user_stop")
	h.settle()
	h.waitDone(s.sess)

	closes, aborts := s.pub.counts()
	if closes != 1 || aborts != 0 {
		t.Fatalf("publisher: Close %d Abort %d; a user stop sends the pending media before disconnecting", closes, aborts)
	}
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started session_ended]" {
		t.Fatalf("events = %s", got)
	}
	// 応答は無い。ブラウザへ致命通知は送らず、接続を通常の切断で閉じる
	expectSequence(t, s.conn.link, "accepted", "status:awaiting_media", "status:confirming", "close:1000")
	if h.reg.Count() != 0 {
		t.Fatalf("Count = %d", h.reg.Count())
	}
	// 配信キー・取り込み先・バッファを破棄している
	if s.sess.key != "" || s.sess.ingestURL != "" || s.sess.pub != nil || s.sess.cfg != nil {
		t.Fatalf("secrets or buffers remain after the session ended: key=%q url=%q pub=%v cfg=%v", s.sess.key, s.sess.ingestURL, s.sess.pub, s.sess.cfg)
	}
	assertNoLeftoverGoroutines(t)
}

func TestEveryEndReasonTheBrowserCanSendStopsTheSession(t *testing.T) {
	for _, reason := range []string{"user_stop", "user_cancel", "insufficient_bandwidth"} {
		t.Run(reason, func(t *testing.T) {
			h := newHarness(t)
			h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
			conn := h.connect()
			conn.hello("t1")
			h.settle()
			session := h.mustSession(idA)
			conn.end(reason)
			h.settle()
			h.waitDone(session)
			// 回線不足・取り消しは、RTMPS に接続する前に終わる。何も接続しない
			if got := h.fac.openCount(); got != 0 {
				t.Fatalf("Open calls = %d", got)
			}
			if got := fmt.Sprint(h.ev.kinds()); got != "[session_ended]" {
				t.Fatalf("events = %s", got)
			}
			expectSequence(t, conn.link, "accepted", "close:1000")
		})
	}
}

func TestInvalidEndIsDiscarded(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.sendFrameBody(t, contract.FrameTypeEnd, `{"reason":"time_limit"}`)
	s.conn.sendFrameBody(t, contract.FrameTypeEnd, `nonsense`)
	h.settle()
	if s.sess.State() != StateStreaming {
		t.Fatalf("state = %v: an invalid end must be discarded", s.sess.State())
	}
}

// 利用者の停止は、Close が最悪で 17 秒ほどかかっても、ほかの接続・セッションを待たせない。
func TestEndDoesNotBlockOtherSessions(t *testing.T) {
	h := newHarness(t)
	first := h.bringUp("t1", idA, 1)
	release := make(chan struct{})
	first.pub.mu.Lock()
	first.pub.closeGate = release
	first.pub.mu.Unlock()

	h.be.addTicket("t2", backendVerifyFor(idB, 1, accountY))
	other := h.connect()
	first.conn.end("user_stop") // Close が戻らない
	other.hello("t2")
	// 別のアカウントの照合は、すぐに終わる（止まった Close を待たない）
	deadline := time.Now().Add(5 * time.Second)
	for len(other.link.sequence(t)) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("another session's connection was blocked by a stop that is still draining")
		}
		time.Sleep(time.Millisecond)
	}
	expectSequence(t, other.link, "accepted")
	close(release)
	h.waitDone(first.sess)
}

func (tc *testConn) sendFrameBody(t *testing.T, kind contract.FrameType, body string) {
	t.Helper()
	tc.sendFrame(frameOf(kind, body))
}
