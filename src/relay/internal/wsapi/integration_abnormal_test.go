package wsapi_test

import (
	"encoding/binary"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/session"
)

// 中継層の結合試験：異常系。

func fatalIs(code string) func(map[string]any) bool {
	return func(body map[string]any) bool { return body["code"] == code }
}

// rawHeader は、17 バイトのヘッダ（識別子・版・種別・属性・時刻・本文長）を、値を指定して組み立てる（壊れたフレームを作る）。
func rawHeader(magic0, magic1, version, kind byte, bodyLength uint32) []byte {
	header := make([]byte, contract.WSFrameHeaderBytes)
	header[0], header[1], header[2], header[3] = magic0, magic1, version, kind
	binary.BigEndian.PutUint32(header[contract.WSFrameHeaderFieldsBodyLengthOffset:], bodyLength)
	return header
}

// attached は、hello から accepted まで進めた接続。
func (e *relayEnv) attached(n int) (*wsClient, string) {
	e.t.Helper()
	bid := broadcastID(n)
	ticket := fmt.Sprintf("dummy-ticket-%d-SECRET", n)
	e.app.addTicket(ticket, bid, "reserved", accountKey(n))
	c := e.dial()
	c.hello(ticket)
	c.waitFor(contract.FrameTypeAccepted, nil)
	return c, bid
}

func TestAnUnknownTicketIsFatalAndTheConnectionIsClosed(t *testing.T) {
	env := newRelayEnv(t)
	c := env.dial()
	c.hello("dummy-unknown-ticket-SECRET")
	c.waitFor(contract.FrameTypeFatal, fatalIs("invalid_ticket"))
	if code := c.waitClosed(); code != 1000 {
		t.Errorf("close code = %d; want 1000", code)
	}
	if verifies := env.app.callsOf("verify"); len(verifies) != 1 {
		t.Errorf("verify calls = %d; want 1", len(verifies))
	}
	// 使用済みのチケットも、同じ（1 回限り）
	bid := broadcastID(1)
	env.app.addTicket("dummy-ticket-1-SECRET", bid, "reserved", accountKey(1))
	first := env.dial()
	first.hello("dummy-ticket-1-SECRET")
	first.waitFor(contract.FrameTypeAccepted, nil)
	second := env.dial()
	second.hello("dummy-ticket-1-SECRET")
	second.waitFor(contract.FrameTypeFatal, fatalIs("invalid_ticket"))
	if code := second.waitClosed(); code != 1000 {
		t.Errorf("close code of the reused ticket = %d; want 1000", code)
	}
}

func TestATicketOfAnEndedBroadcastIsRefused(t *testing.T) {
	env := newRelayEnv(t)
	env.app.addTicket("dummy-ticket-ended-SECRET", broadcastID(9), "ended", accountKey(9))
	c := env.dial()
	c.hello("dummy-ticket-ended-SECRET")
	c.waitFor(contract.FrameTypeFatal, fatalIs("broadcast_ended"))
	if code := c.waitClosed(); code != 1000 {
		t.Errorf("close code = %d; want 1000", code)
	}
}

func TestAnUnreachableApplicationAtVerificationIsAnInternalErrorAndTheTicketIsNotConsumed(t *testing.T) {
	env := newRelayEnv(t)
	bid := broadcastID(1)
	env.app.addTicket("dummy-ticket-1-SECRET", bid, "reserved", accountKey(1))
	env.app.setDown(true)
	c := env.dial()
	c.hello("dummy-ticket-1-SECRET")
	c.waitFor(contract.FrameTypeFatal, fatalIs("internal_error"))
	if code := c.waitClosed(); code != 1000 {
		t.Errorf("close code = %d; want 1000", code)
	}
	// 復旧したら、同じチケットで接続できる（アプリケーションには、届いていないので、消費されていない）
	env.app.setDown(false)
	again := env.dial()
	again.hello("dummy-ticket-1-SECRET")
	again.waitFor(contract.FrameTypeAccepted, nil)
}

func TestNoHelloForTenSecondsClosesTheConnection(t *testing.T) {
	env := newRelayEnv(t)
	c := env.dial()
	env.clock.Advance(9 * time.Second)
	time.Sleep(50 * time.Millisecond)
	if frames := c.snapshot(); len(frames) != 0 {
		t.Fatalf("received %v after 9 seconds; want nothing yet", frames)
	}
	env.clock.Advance(time.Second)
	c.waitFor(contract.FrameTypeFatal, fatalIs("hello_timeout"))
	if code := c.waitClosed(); code != 1000 {
		t.Errorf("close code = %d; want 1000", code)
	}
	if verifies := env.app.callsOf("verify"); len(verifies) != 0 {
		t.Errorf("verify calls = %d; want none (there was no hello)", len(verifies))
	}
}

func TestAHelloInTimeCancelsTheHelloTimeout(t *testing.T) {
	env := newRelayEnv(t)
	c, _ := env.attached(1)
	env.clock.Advance(30 * time.Second)
	time.Sleep(50 * time.Millisecond)
	if fatals := c.fatals(); len(fatals) != 0 {
		t.Fatalf("fatals = %v; an attached connection must not be closed by the hello timeout", fatals)
	}
}

func TestMessagesBeforeHelloAreDiscardedAndTheConnectionContinues(t *testing.T) {
	env := newRelayEnv(t)
	bid := broadcastID(1)
	env.app.addTicket("dummy-ticket-1-SECRET", bid, "reserved", accountKey(1))
	c := env.dial()
	c.send(contract.FrameTypeProbe, false, 0, make([]byte, 1000))
	c.send(contract.FrameTypeStart, false, 0, startBody("720p"))
	c.send(contract.FrameTypeVideo, true, 0, videoPayload(0, 100))
	c.hello("dummy-ticket-1-SECRET")
	c.waitFor(contract.FrameTypeAccepted, nil)
	if state := env.session(bid).State(); state != session.StateVerified {
		t.Fatalf("session state = %v; want verified (nothing sent before hello counts)", state)
	}
	if fatals := c.fatals(); len(fatals) != 0 {
		t.Fatalf("fatals = %v", fatals)
	}
	if provisions := env.app.callsOf("provision"); len(provisions) != 0 {
		t.Fatalf("provision calls = %d; want none (the start before hello is discarded)", len(provisions))
	}
}

func TestASecondHelloIsAProtocolViolation(t *testing.T) {
	env := newRelayEnv(t)
	c, _ := env.attached(1)
	c.hello("dummy-ticket-1-SECRET")
	c.waitFor(contract.FrameTypeFatal, fatalIs("protocol_violation"))
	if code := c.waitClosed(); code != 1000 {
		t.Errorf("close code = %d; want 1000", code)
	}
}

func TestATextFrameIsAProtocolViolation(t *testing.T) {
	env := newRelayEnv(t)
	c, _ := env.attached(1)
	if err := c.conn.WriteMessage(websocket.TextMessage, []byte(`{"hello":"world"}`)); err != nil {
		t.Fatalf("write: %v", err)
	}
	c.waitFor(contract.FrameTypeFatal, fatalIs("protocol_violation"))
	if code := c.waitClosed(); code != 1000 {
		t.Errorf("close code = %d; want 1000", code)
	}
}

// 2 MiB 以下（上限ちょうど）は受け付け、上限を 1 バイトでも超えると、fatal(message_too_large) を先に送ってから、
// Close コード 1009 で切る
func TestAMessageAtTheLimitIsAcceptedAndOneByteOverIsFatalWithCloseCode1009(t *testing.T) {
	env := newRelayEnv(t)
	c, bid := env.attached(1)

	atLimit := make([]byte, contract.WSFrameMaxMessageBytes-contract.WSFrameHeaderBytes)
	c.send(contract.FrameTypeProbe, false, 0, atLimit)
	env.waitState(bid, session.StateProbing)
	env.clock.Advance(3 * time.Second)
	result := c.waitFor(contract.FrameTypeProbeResult, nil).json()
	if want := contract.WSFrameMaxMessageBytes * 8 / 3000; intOf(t, result["throughput_kbps"]) != want {
		t.Errorf("probe_result = %v; want %d kbps from the message at the limit", result, want)
	}
	if fatals := c.fatals(); len(fatals) != 0 {
		t.Fatalf("a message exactly at the limit produced fatals %v", fatals)
	}

	_ = c.tryRaw(make([]byte, contract.WSFrameMaxMessageBytes+1))
	c.waitFor(contract.FrameTypeFatal, fatalIs("message_too_large"))
	if code := c.waitClosed(); code != 1009 {
		t.Errorf("close code = %d; want 1009", code)
	}
	// 切断は、致命通知のあと（致命通知が先に届いた）
	if got := c.describe(); len(got) < 2 || !strings.HasPrefix(got[len(got)-1], "fatal") {
		t.Errorf("frames = %v; want the fatal to be the last frame before the close", got)
	}
}

// ヘッダの本文長だけで 2 MiB 超を宣言し、本文を送らない接続も、上限 + 1 バイトを受けた時点で切る（本文を待ち続けない）
func TestAnOversizeMessageThatNeverEndsIsCutAsSoonAsTheLimitIsPassed(t *testing.T) {
	env := newRelayEnv(t)
	c, _ := env.attached(1)
	writer, err := c.conn.NextWriter(websocket.BinaryMessage)
	if err != nil {
		t.Fatalf("NextWriter: %v", err)
	}
	// 上限を超える量（クライアントの書き込みの緩衝 256 KiB のフレームが、さらに 2 つ流れる量）を書く
	if _, err := writer.Write(make([]byte, contract.WSFrameMaxMessageBytes+2*(1<<18))); err != nil {
		t.Fatalf("write: %v", err)
	}
	// （writer.Close は呼ばない：メッセージは終わらない）
	c.waitFor(contract.FrameTypeFatal, fatalIs("message_too_large"))
	if code := c.waitClosed(); code != 1009 {
		t.Errorf("close code = %d; want 1009", code)
	}
}

// 長さ・種別・方向・版・識別子に逸脱するメッセージは、破棄して、接続を続ける
func TestBrokenFramesAreDiscardedAndTheConnectionContinues(t *testing.T) {
	env := newRelayEnv(t)
	c, bid := env.attached(1)
	broken := map[string][]byte{
		"ヘッダに満たない":       {0x42, 0x4C, 0x01},
		"識別子が違う":         rawHeader(0x00, 0x00, 1, byte(contract.FrameTypeProbe), 0),
		"版が違う":           rawHeader(0x42, 0x4C, 2, byte(contract.FrameTypeProbe), 0),
		"種別が未知":          rawHeader(0x42, 0x4C, 1, 0x55, 0),
		"方向が逆（中継から送る種別）": rawHeader(0x42, 0x4C, 1, byte(contract.FrameTypeAccepted), 0),
		"本文長が合わない（不足）":   append(rawHeader(0x42, 0x4C, 1, byte(contract.FrameTypeProbe), 100), make([]byte, 10)...),
		"本文長が合わない（超過）":   append(rawHeader(0x42, 0x4C, 1, byte(contract.FrameTypeProbe), 2), make([]byte, 10)...),
		"空のメッセージ":        {},
	}
	for name, message := range broken {
		if err := c.tryRaw(message); err != nil {
			t.Fatalf("%s: write: %v", name, err)
		}
	}
	// 本文の JSON が壊れた開始通知・状態報告・終了通知も、破棄する（接続も、配信も、そのまま）
	c.send(contract.FrameTypeStart, false, 0, []byte(`{"profile":"720p"`))
	c.send(contract.FrameTypeStart, false, 0, []byte(`{"profile":"9999p"}`))
	c.send(contract.FrameTypeReport, false, 0, []byte(`not json`))
	c.send(contract.FrameTypeEnd, false, 0, []byte(`{"reason":"admin_stop"}`))

	// そのあとの正しいメッセージは、これまでどおり処理される
	c.send(contract.FrameTypeProbe, false, 0, make([]byte, 5000))
	env.waitState(bid, session.StateProbing)
	env.clock.Advance(3 * time.Second)
	c.waitFor(contract.FrameTypeProbeResult, nil)
	if fatals := c.fatals(); len(fatals) != 0 {
		t.Fatalf("fatals = %v; broken messages are discarded, not fatal", fatals)
	}
	if provisions := env.app.callsOf("provision"); len(provisions) != 0 {
		t.Fatalf("provision calls = %d; a broken start must not start the preparation", len(provisions))
	}
	if !strings.Contains(env.logs.String(), "message discarded") {
		t.Errorf("the discards were not logged: %s", env.logs.String())
	}
}

// 新しい世代の接続を照合すると、古い接続は直ちに閉じられる（fatal(stale_epoch)）。RTMPS の接続は保たれる
func TestAnOlderConnectionIsClosedAtOnceWhenANewerEpochConnects(t *testing.T) {
	env := newRelayEnv(t)
	l := env.startBroadcast(1)
	env.app.addTicket("dummy-ticket-newer-SECRET", l.bid, "live", accountKey(1))
	newer := env.dial()
	newer.hello("dummy-ticket-newer-SECRET")
	accepted := newer.waitFor(contract.FrameTypeAccepted, nil).json()
	if accepted["resume"] != true || accepted["profile"] != "720p" || accepted["state"] != "live" {
		t.Fatalf("accepted = %v; want resume true, profile 720p, state live", accepted)
	}
	l.client.waitFor(contract.FrameTypeFatal, fatalIs("stale_epoch"))
	if code := l.client.waitClosed(); code != 1000 {
		t.Errorf("close code of the older connection = %d; want 1000", code)
	}
	if l.peer.isClosed() {
		t.Error("the RTMPS connection was closed by the epoch change; it must be kept for the resume")
	}
	eventually(t, "the interruption was reported", func() bool { return contains(env.app.eventKinds(l.bid), "interrupted:browser_disconnected") })
	// 古い世代の接続は、もう何も送れない（送っても、取り込みセッションには届かない）
	tags := l.peer.count()
	_ = l.client.tryRaw([]byte("late"))
	time.Sleep(30 * time.Millisecond)
	if got := l.peer.count(); got != tags {
		t.Errorf("tags changed from %d to %d after the older connection was closed", tags, got)
	}
}

// 同一アカウントの新しい配信を照合した時点で、そのアカウントの他の配信の取り込みセッションを、すべて閉じる
func TestANewBroadcastOfTheSameAccountClosesTheOldOne(t *testing.T) {
	env := newRelayEnv(t)
	old := env.startBroadcast(1)
	old.sendMedia(10)

	secondID := broadcastID(2)
	env.app.addTicket("dummy-ticket-second-SECRET", secondID, "reserved", accountKey(1)) // 同じアカウント
	second := env.dial()
	second.hello("dummy-ticket-second-SECRET")
	second.waitFor(contract.FrameTypeAccepted, nil)

	old.client.waitFor(contract.FrameTypeFatal, fatalIs("broadcast_ended"))
	if code := old.client.waitClosed(); code != 1000 {
		t.Errorf("close code = %d; want 1000", code)
	}
	eventually(t, "the old RTMPS connection was cut", old.peer.isClosed)
	eventually(t, "session_ended of the old broadcast", func() bool { return contains(env.app.eventKinds(old.bid), "session_ended") })
	if _, ok := env.relay.Registry().Find(old.bid); ok {
		t.Error("the old ingest session is still registered")
	}
}

// 別のアカウントの配信は、閉じない
func TestABroadcastOfAnotherAccountIsNotClosed(t *testing.T) {
	env := newRelayEnv(t)
	first := env.startBroadcast(1)
	first.sendMedia(10)
	env.app.addTicket("dummy-ticket-other-SECRET", broadcastID(2), "reserved", accountKey(2))
	other := env.dial()
	other.hello("dummy-ticket-other-SECRET")
	other.waitFor(contract.FrameTypeAccepted, nil)
	time.Sleep(30 * time.Millisecond)
	if first.peer.isClosed() || len(first.client.fatals()) != 0 {
		t.Error("a broadcast of a different account was closed")
	}
	first.sendMedia(10) // 変わらず送出できる
}

// 受信ビットレートが、10 秒平均でプロファイルの上限の 1.5 倍（720p は 9,000 kbps）を超えると、致命通知のうえ切断し、
// 事象 relay_disconnected を送る。当該配信への再接続は受け付けない
func TestExcessiveIngressDisconnectsAndTheBroadcastCannotReconnect(t *testing.T) {
	env := newRelayEnv(t)
	l := env.startBroadcast(1)
	for i := 0; i < 6; i++ { // 6 枚 × 1.9 MB = 約 11.4 MB > 11.25 MB（9,000 kbps × 10 秒）
		if err := l.client.tryRaw(bigVideo(l.originUs+videoTimeUs(i), i == 0, 1_900_000)); err != nil {
			break // 切断されたあとの書き込み
		}
	}
	l.client.waitFor(contract.FrameTypeFatal, fatalIs("bitrate_exceeded"))
	if code := l.client.waitClosed(); code != 1000 {
		t.Errorf("close code = %d; want 1000", code)
	}
	eventually(t, "the RTMPS connection was cut", l.peer.isClosed)
	eventually(t, "the events were reported", func() bool { return contains(env.app.eventKinds(l.bid), "session_ended") })
	kinds := env.app.eventKinds(l.bid)
	disconnected, ended := indexOf(kinds, "relay_disconnected"), indexOf(kinds, "session_ended")
	if disconnected < 0 || disconnected > ended {
		t.Errorf("events = %v; want relay_disconnected before session_ended", kinds)
	}

	eventually(t, "the session left the registry and the ban was recorded", func() bool { return env.relay.Registry().Count() == 0 })
	env.app.addTicket("dummy-ticket-again-SECRET", l.bid, "live", accountKey(1))
	again := env.dial()
	again.hello("dummy-ticket-again-SECRET")
	again.waitFor(contract.FrameTypeFatal, fatalIs("bitrate_exceeded"))
	if code := again.waitClosed(); code != 1000 {
		t.Errorf("close code of the refused reconnection = %d; want 1000", code)
	}
}

func bigVideo(timestampUs uint64, keyframe bool, bodyBytes int) []byte {
	message := rawHeader(0x42, 0x4C, 1, byte(contract.FrameTypeVideo), uint32(bodyBytes))
	if keyframe {
		message[contract.WSFrameHeaderFieldsAttributesOffset] = 1
	}
	binary.BigEndian.PutUint64(message[contract.WSFrameHeaderFieldsTimestampUsOffset:], timestampUs)
	body := make([]byte, bodyBytes)
	binary.BigEndian.PutUint32(body, uint32(bodyBytes-4))
	return append(message, body...)
}

func indexOf(values []string, want string) int {
	for i, value := range values {
		if value == want {
			return i
		}
	}
	return -1
}

// 準備の失敗で配信が終了したとき：status(ended・end_reason) → fatal(broadcast_ended) → 切断。RTMPS には接続しない
func TestPreparationFailuresEndTheBroadcastWithTheirReason(t *testing.T) {
	cases := []struct {
		name      string
		status    int
		code      string
		endReason string
		want      string
	}{
		{"準備の失敗", 502, "prepare_failed", "prepare_failed", "prepare_failed"},
		{"先行配信が未清算", 422, "prior_unsettled", "prior_unsettled", "prior_unsettled"},
		{"認可の失効", 409, "authorization_revoked", "authorization_revoked", "authorization_revoked"},
		{"ライブ未有効（準備の失敗として終了）", 409, "live_not_enabled", "prepare_failed", "prepare_failed"},
		{"配信が終了済み（実際の終了理由）", 409, "broadcast_ended", "time_limit", "time_limit"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			env := newRelayEnv(t)
			env.app.setProvision(func(string, int) (int, map[string]any) {
				return tc.status, errorBody(tc.code, map[string]any{"end_reason": tc.endReason})
			})
			c, bid := env.attached(1)
			c.send(contract.FrameTypeStart, false, 0, startBody("720p"))
			ended := c.waitFor(contract.FrameTypeStatus, statusIs("ended")).json()
			if ended["end_reason"] != tc.want {
				t.Errorf("status(ended) = %v; want end_reason %s", ended, tc.want)
			}
			c.waitFor(contract.FrameTypeFatal, fatalIs("broadcast_ended"))
			if code := c.waitClosed(); code != 1000 {
				t.Errorf("close code = %d; want 1000", code)
			}
			if got := c.describe(); len(got) != 3 || !strings.HasPrefix(got[0], "accepted") || !strings.Contains(got[1], `"ended"`) || !strings.HasPrefix(got[2], "fatal") {
				t.Errorf("frames = %v; want accepted, status(ended), fatal", got)
			}
			if env.rtmp.peerCount() != 0 {
				t.Error("the relay connected to the receiver although the preparation failed")
			}
			eventually(t, "session_ended", func() bool { return contains(env.app.eventKinds(bid), "session_ended") })
			env.assertNoSecretsLogged()
		})
	}
}

// 古い送出世代で準備を呼ぶと 409(stale_epoch)。中継は、新しい世代の接続があるものとして、fatal(stale_epoch) のうえ閉じる
func TestProvisionWithAStaleEpochClosesWithStaleEpoch(t *testing.T) {
	env := newRelayEnv(t)
	env.app.setProvision(func(id string, epoch int) (int, map[string]any) {
		return 409, errorBody("stale_epoch", nil)
	})
	c, _ := env.attached(1)
	c.send(contract.FrameTypeStart, false, 0, startBody("720p"))
	c.waitFor(contract.FrameTypeFatal, fatalIs("stale_epoch"))
	if code := c.waitClosed(); code != 1000 {
		t.Errorf("close code = %d; want 1000", code)
	}
}
