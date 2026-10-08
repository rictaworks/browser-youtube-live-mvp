package session

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/frame"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
)

// 試験の土台。台帳・取り込みセッション・接続を、疑似の境界（時計・アプリケーション・事象・RTMPS・ブラウザ）につないで動かす。
// 非同期の作業（照合・準備・接続・心拍の応答）は、settle で、終わるのを待つ。時計は、試験が Advance で進める。

const (
	idA = "11111111-1111-4111-8111-111111111111"
	idB = "22222222-2222-4222-8222-222222222222"
	idC = "33333333-3333-4333-8333-333333333333"

	accountX = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	accountY = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
)

func contextWithTimeout(t testing.TB) (context.Context, context.CancelFunc) {
	t.Helper()
	return context.WithTimeout(context.Background(), 10*time.Second)
}

func decodeJSON(t testing.TB, body []byte, out any) {
	t.Helper()
	if err := json.Unmarshal(body, out); err != nil {
		t.Fatalf("not JSON: %v: %q", err, body)
	}
}

// verifyResult は、照合の結果。reserved 以外（復帰）は、確定済みのプロファイルを持つ。
func verifyResult(id string, epoch int, state contract.BroadcastState) backend.VerifyResult {
	var profile contract.Profile
	if state != contract.BroadcastStateReserved {
		profile = contract.Profile720p
	}
	return backend.VerifyResult{BroadcastID: id, State: state, Epoch: epoch, AccountKey: accountX, Profile: profile, Limits: backend.Limits{TimeLimitSeconds: 3600}}
}

// backendVerifyFor は、アカウントを指定した、新規の配信の照合の結果。
func backendVerifyFor(id string, epoch int, account string) backend.VerifyResult {
	result := verifyResult(id, epoch, contract.BroadcastStateReserved)
	result.AccountKey = account
	return result
}

type harness struct {
	t     *testing.T
	clock *fakeClock
	be    *fakeBackend
	ev    *fakeEvents
	fac   *fakeFactory
	logs  *syncBuffer
	opts  Options
	deps  Deps
	reg   *Registry
}

func newHarness(t *testing.T, mutate ...func(*Options)) *harness {
	t.Helper()
	h := &harness{t: t, clock: newFakeClock(), be: newFakeBackend(), ev: &fakeEvents{}, fac: newFakeFactory(), logs: &syncBuffer{}}
	h.opts = DefaultOptions()
	for _, m := range mutate {
		m(&h.opts)
	}
	logger := slog.New(slog.NewJSONHandler(h.logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	h.deps = Deps{Backend: h.be, Events: h.ev, Publishers: h.fac, Clock: h.clock, Logger: logger, Options: h.opts}
	reg, err := NewRegistry(h.deps)
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	h.reg = reg
	t.Cleanup(func() {
		if t.Failed() {
			t.Logf("session logs:\n%s", h.logText())
		}
	})
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := h.reg.Shutdown(ctx); err != nil {
			t.Errorf("Shutdown: %v", err)
		}
		assertNoLeftoverGoroutines(t)
		if n := h.clock.activeTimers(); n != 0 {
			t.Errorf("%d timers are still active after Shutdown", n)
		}
	})
	return h
}

// replaceEvents は、事象の送り先を差し替えた台帳に取り替える（まだ接続も取り込みセッションも無いときに呼ぶ）。
func (h *harness) replaceEvents(sink EventSink) {
	h.t.Helper()
	ctx, cancel := contextWithTimeout(h.t)
	defer cancel()
	if err := h.reg.Shutdown(ctx); err != nil {
		h.t.Fatalf("Shutdown: %v", err)
	}
	h.deps.Events = sink
	reg, err := NewRegistry(h.deps)
	if err != nil {
		h.t.Fatalf("NewRegistry: %v", err)
	}
	h.reg = reg
}

// settle は、非同期の作業（照合・準備・接続・心拍の応答）が終わり、結果が取り込まれるのを待つ。
func (h *harness) settle() {
	h.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		if h.idle() && h.idle() {
			return
		}
		if time.Now().After(deadline) {
			h.t.Fatal("settle: asynchronous work did not finish")
		}
		runtime.Gosched()
	}
}

// advance は、時計を d 進める。心拍の拍（2 秒）を飛ばさないよう、2 秒ずつ進めて、そのたびに作業の終わりを待つ
// （実際の中継は、2 秒ごとに心拍を送り、応答を受ける。長い時間を一度に進めると、60 秒の応答の喪失が、誤って成立する）。
func (h *harness) advance(d time.Duration) {
	h.t.Helper()
	for d > 0 {
		step := min(d, 2*time.Second)
		h.clock.Advance(step)
		h.settle()
		d -= step
	}
}

// idle は、全セッションの受信の待ち行列を空にし、作業のゴルーチンが無いことを確かめる。
func (h *harness) idle() bool {
	// 作業のゴルーチンの数を、待ち行列を空にする前に読む。0 なら、結果は、すべて待ち行列に積まれている（空にすれば、取り込まれる）。
	// 空にしたことで、新しい作業が始まっていれば、あとの数に表れる
	idle := h.reg.pendingWorkers() == 0
	for _, s := range h.reg.sessionsSnapshot() {
		before := s.workerCount()
		s.barrier()
		if before != 0 || s.workerCount() != 0 {
			idle = false
		}
	}
	return idle
}

// barrierAll は、全セッションの受信の待ち行列を空にする（作業のゴルーチンは待たない。止めた疑似を使う試験用）。
func (h *harness) barrierAll() {
	for _, s := range h.reg.sessionsSnapshot() {
		s.barrier()
	}
}

// newSession は、台帳を通さずに、取り込みセッションを作って動かす（台帳の単体の試験用。登録はしない）。
func (h *harness) newSession(id, account string) *IngestSession {
	h.t.Helper()
	s, err := NewIngestSession(Params{BroadcastID: id, AccountKey: account, State: contract.BroadcastStateReserved}, h.deps)
	if err != nil {
		h.t.Fatalf("NewIngestSession: %v", err)
	}
	s.Start()
	h.t.Cleanup(func() {
		s.Close(CloseReasonShutdown)
		select {
		case <-s.Done():
		case <-time.After(10 * time.Second):
			h.t.Errorf("session %s did not finish", id)
		}
	})
	return s
}

func (h *harness) mustSession(id string) *IngestSession {
	h.t.Helper()
	s, ok := h.reg.Find(id)
	if !ok {
		h.t.Fatalf("no ingest session for %s", id)
	}
	return s
}

// waitDone は、取り込みセッションが完全に終わる（ゴルーチンが残らない）のを待つ。
func (h *harness) waitDone(s *IngestSession) {
	h.t.Helper()
	select {
	case <-s.Done():
	case <-time.After(10 * time.Second):
		h.t.Fatal("the ingest session did not finish")
	}
}

type testConn struct {
	h    *harness
	conn *Connection
	link *fakeLink
}

func (h *harness) connect() *testConn {
	h.t.Helper()
	link := &fakeLink{}
	conn, err := h.reg.Accept(link)
	if err != nil {
		h.t.Fatalf("Accept: %v", err)
	}
	return &testConn{h: h, conn: conn, link: link}
}

func (tc *testConn) sendFrame(f frame.Frame) {
	tc.h.t.Helper()
	message, err := frame.Encode(f)
	if err != nil {
		tc.h.t.Fatalf("Encode: %v", err)
	}
	tc.conn.Handle(message)
}

func (tc *testConn) hello(ticket string) {
	tc.h.t.Helper()
	tc.sendFrame(frame.Frame{Type: contract.FrameTypeHello, Body: []byte(ticket)})
}

// probe は、計測データ 1 つ（メッセージ全体で bodyLen+17 バイト）。
func (tc *testConn) probe(bodyLen int) {
	tc.h.t.Helper()
	tc.sendFrame(frame.Frame{Type: contract.FrameTypeProbe, Body: make([]byte, bodyLen)})
}

func (tc *testConn) start(profile string) {
	tc.h.t.Helper()
	tc.sendFrame(frame.Frame{Type: contract.FrameTypeStart, Body: []byte(startJSON(profile))})
}

func (tc *testConn) startBody(body string) {
	tc.h.t.Helper()
	tc.sendFrame(frame.Frame{Type: contract.FrameTypeStart, Body: []byte(body)})
}

// videoPayload は、AVCC の NAL 列の形の、映像の符号化データ（中身は印）。
func videoPayload(mark byte, size int) []byte {
	payload := make([]byte, size)
	if size >= 5 {
		payload[3] = byte(size - 4)
	}
	for i := 4; i < size; i++ {
		payload[i] = mark
	}
	return payload
}

func audioPayload(mark byte, size int) []byte {
	payload := make([]byte, size)
	for i := range payload {
		payload[i] = mark
	}
	return payload
}

func (tc *testConn) video(ts uint64, keyframe bool, payload []byte) {
	tc.h.t.Helper()
	tc.sendFrame(frame.Frame{Type: contract.FrameTypeVideo, Keyframe: keyframe, TimestampUs: ts, Body: payload})
}

func (tc *testConn) audio(ts uint64, payload []byte) {
	tc.h.t.Helper()
	tc.sendFrame(frame.Frame{Type: contract.FrameTypeAudio, TimestampUs: ts, Body: payload})
}

func (tc *testConn) report(body string) {
	tc.h.t.Helper()
	tc.sendFrame(frame.Frame{Type: contract.FrameTypeReport, Body: []byte(body)})
}

func frameOf(kind contract.FrameType, body string) frame.Frame {
	return frame.Frame{Type: kind, Body: []byte(body)}
}

func (tc *testConn) end(reason string) {
	tc.h.t.Helper()
	tc.sendFrame(frame.Frame{Type: contract.FrameTypeEnd, Body: []byte(`{"reason":"` + reason + `"}`)})
}

// streaming は、送出中の取り込みセッション。
type streaming struct {
	conn *testConn
	sess *IngestSession
	pub  *fakePublisher
}

// bringUp は、新規の配信を、送出（status(confirming) を送り、メディアを受けられる状態）まで進める。
// 照合 → 開始通知 → 準備 → RTMPS の接続 → 確認の窓（5 秒）→ publish_started と status(confirming)。
func (h *harness) bringUp(ticket, id string, epoch int) streaming {
	h.t.Helper()
	return h.bringUpAs(ticket, id, epoch, accountX)
}

// bringUpAs は、アカウントを指定して、bringUp する。
func (h *harness) bringUpAs(ticket, id string, epoch int, account string) streaming {
	h.t.Helper()
	h.be.addTicket(ticket, backendVerifyFor(id, epoch, account))
	conn := h.connect()
	conn.hello(ticket)
	h.settle()
	conn.start("720p")
	h.settle()
	h.clock.Advance(h.opts.PublishConfirmWindow)
	h.settle()
	return streaming{conn: conn, sess: h.mustSession(id), pub: h.fac.last(h.t)}
}

// resumeConnect は、復帰の接続（reserved 以外の状態で照合する）を、accepted まで進める。
func (h *harness) resumeConnect(ticket, id string, epoch int, state contract.BroadcastState) *testConn {
	h.t.Helper()
	h.be.addTicket(ticket, verifyResult(id, epoch, state))
	conn := h.connect()
	conn.hello(ticket)
	h.settle()
	return conn
}

func (h *harness) logText() string { return h.logs.String() }

// expectSequence は、リンクへ送ったメッセージと切断（ack を除く）が、want と一致することを確かめる。
func expectSequence(t testing.TB, link *fakeLink, want ...string) {
	t.Helper()
	got := link.sequence(t)
	if got == nil {
		got = []string{}
	}
	if want == nil {
		want = []string{}
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("link sequence = %v\nwant            %v", got, want)
	}
}

// containsAll は、text が、すべての語を含むか。
func containsAll(text string, words ...string) bool {
	for _, word := range words {
		if !strings.Contains(text, word) {
			return false
		}
	}
	return true
}

func eventKinds(h *harness) string { return fmt.Sprint(h.ev.kinds()) }
