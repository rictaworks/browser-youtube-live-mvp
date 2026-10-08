package session

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
)

// 秘密値・接続チケット・配信キー・取り込み先を、ログ・エラー・%v に出さない（requirements.md 6.1・10.1・28.1）。
// メッセージごとのログは出さない（異常のみ、配信の識別子つき）。

const (
	// 敵対的な（または、想定外の）エラーの文言。これらを、そのままログへ写してはならない
	hostileDialError  = "dial tcp rtmps.youtube.com:443: key=" + dummyStreamKey + " ticket=" + dummyTicket
	hostileBackendErr = "boom " + dummyTicket + " " + dummyStreamKey + " " + dummyIngestURL
)

func assertNoSecrets(t *testing.T, name, text string) {
	t.Helper()
	for _, secret := range []string{"SECRET", "rtmps.youtube.com", "live2", dummyStreamKey, dummyTicket, dummySecret} {
		if strings.Contains(text, secret) {
			t.Fatalf("%s contains %q:\n%s", name, secret, text)
		}
	}
}

func TestNoSecretIsLoggedOverAWholeBroadcast(t *testing.T) {
	h := newHarness(t)
	// 失敗の文言に秘密値を載せた疑似を使う（本物の通信の失敗の文言には、取り込み先のホスト名などが入り得る）
	h.fac.failNext(fmt.Errorf("%s", hostileDialError))
	var provisionCalls int
	h.be.setProvision(func(provisionCall) (backend.ProvisionResult, error) {
		provisionCalls++
		if provisionCalls == 1 {
			return backend.ProvisionResult{}, fmt.Errorf("%w: %s", backend.ErrUnavailable, hostileBackendErr)
		}
		return defaultProvisionResult(), nil
	})
	h.be.failTicket("bad", fmt.Errorf("%s", hostileBackendErr))
	rejected := h.connect()
	rejected.hello("bad")
	h.settle()

	h.be.addTicket(dummyTicket, verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello(dummyTicket)
	h.settle()
	conn.probe(1000)
	conn.start("720p")
	h.settle()
	h.clock.Advance(h.opts.RedialInitial) // 準備の再試行
	h.settle()
	h.clock.Advance(h.opts.RedialInitial) // 接続の再試行
	h.settle()
	h.clock.Advance(h.opts.PublishConfirmWindow)
	h.settle()
	h.be.setHeartbeat(func(backend.HeartbeatRequest) (backend.HeartbeatResponse, error) {
		return backend.HeartbeatResponse{}, fmt.Errorf("%w: %s", backend.ErrUnavailable, hostileBackendErr)
	})
	conn.audio(0, audioPayload(1, 20))
	conn.video(0, true, videoPayload(1, 30))
	conn.report("not json " + dummyTicket)
	conn.conn.Handle([]byte(dummyStreamKey))
	h.settle()
	h.fac.last(t).terminate(fmt.Errorf("%w: %s", rtmpsDisconnected(), hostileDialError))
	h.settle()
	advanceBy(h, 2*time.Second, 3)
	conn.end("user_stop")
	h.settle()

	logs := h.logText()
	if strings.TrimSpace(logs) == "" {
		t.Fatal("nothing was logged; the check below would pass vacuously")
	}
	assertNoSecrets(t, "the log", logs)
}

func TestLogLinesCarryTheBroadcastId(t *testing.T) {
	h := newHarness(t)
	h.fac.failNext(fmt.Errorf("refused"))
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	conn.start("720p")
	h.settle()
	found := false
	for _, line := range strings.Split(strings.TrimSpace(h.logText()), "\n") {
		if strings.Contains(line, "dial") {
			found = true
			if !strings.Contains(line, idA) {
				t.Fatalf("a failure log line has no broadcast id: %s", line)
			}
		}
	}
	if !found {
		t.Fatalf("the failed dial was not logged: %s", h.logText())
	}
}

func TestOrdinaryTrafficProducesNoPerMessageLogs(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	before := strings.Count(h.logText(), "\n")
	for i := 0; i < 600; i++ { // 20 秒ぶん（30 fps の映像と 43 fps の音声）
		s.conn.video(uint64(i)*33333, i%60 == 0, videoPayload(1, 100))
		s.conn.audio(uint64(i)*23220, audioPayload(1, 50))
		if i%30 == 0 {
			h.clock.Advance(time.Second)
			h.settle()
		}
	}
	h.settle()
	if after := strings.Count(h.logText(), "\n"); after != before {
		t.Fatalf("%d log lines were written for ordinary traffic:\n%s", after-before, h.logText())
	}
}

func TestFormattingTheSessionStructuresNeverExposesSecrets(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	if s.sess.key == "" {
		t.Fatal("the session does not hold the stream key in this test, so the check is vacuous")
	}
	values := map[string]any{
		"*IngestSession": s.sess,
		"*Registry":      h.reg,
		"*Connection":    s.conn.conn,
		"Options":        h.opts,
	}
	for name, value := range values {
		for _, verb := range []string{"%v", "%+v", "%#v", "%s"} {
			assertNoSecrets(t, name+" "+verb, fmt.Sprintf(verb, value))
		}
	}
}
