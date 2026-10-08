package session

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/frame"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps"
)

// 取り込みセッションと、事象のキュー（internal/backend）をつないだ試験。ほか、小さな確認。

// clockWaiter は、待機（backend.Waiter）を、疑似の時計で動かす。
type clockWaiter struct{ clock *fakeClock }

func (w clockWaiter) After(d time.Duration) <-chan time.Time {
	ch := make(chan time.Time, 1)
	w.clock.AfterFunc(d, func() { ch <- w.clock.Now() })
	return ch
}

// switchableSender は、アプリケーションの事象の口の疑似。up が偽の間は、到達できない。
type switchableSender struct {
	mu        sync.Mutex
	up        bool
	delivered []string
}

func (s *switchableSender) Event(_ context.Context, broadcastID string, event backend.EventRequest) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.up {
		return unreachable()
	}
	text := string(event.Kind)
	if event.Cause != "" {
		text += ":" + string(event.Cause)
	}
	s.delivered = append(s.delivered, fmt.Sprintf("%s@%d", text, event.Epoch))
	return nil
}

func (s *switchableSender) setUp(up bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.up = up
}

func (s *switchableSender) deliveredEvents() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.delivered...)
}

func TestEventsAreHeldWhileTheApplicationIsUnreachableAndDeliveredInOrderAfterwards(t *testing.T) {
	h := newHarness(t)
	sender := &switchableSender{}
	queue, err := backend.NewEventQueue(sender, clockWaiter{h.clock}, backend.QueueOptions{}, slog.New(slog.DiscardHandler))
	if err != nil {
		t.Fatalf("NewEventQueue: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := contextWithTimeout(t)
		defer cancel()
		_ = queue.Shutdown(ctx)
	})
	h.replaceEvents(queue)
	h.be.setHeartbeat(func(backend.HeartbeatRequest) (backend.HeartbeatResponse, error) {
		return backend.HeartbeatResponse{}, unreachable()
	})

	// アプリケーションが不達の間（60 秒の手前まで）も、メディアの転送は止まらず、事象は保持される
	s := h.bringUp("t1", idA, 1)
	firstMedia(s.conn)
	h.settle()
	s.conn.conn.Disconnected()
	h.settle()
	h.advance(30 * time.Second)
	if got := sender.deliveredEvents(); len(got) != 0 {
		t.Fatalf("events were delivered while the application was unreachable: %v", got)
	}
	if got := queue.Len(); got != 2 {
		t.Fatalf("held events = %d, want 2 (publish_started and interrupted)", got)
	}
	if s.sess.State() != StateInterrupted {
		t.Fatalf("state = %v", s.sess.State())
	}

	// アプリケーションが戻る。保持していた事象が、発生順に届く
	sender.setUp(true)
	h.be.setHeartbeat(nil)
	deadline := time.Now().Add(5 * time.Second)
	for len(sender.deliveredEvents()) < 2 {
		if time.Now().After(deadline) {
			t.Fatalf("held events were not resent: %v", sender.deliveredEvents())
		}
		h.clock.Advance(5 * time.Second) // 再送の待機を進める
		time.Sleep(time.Millisecond)
	}
	if got := fmt.Sprint(sender.deliveredEvents()); got != "[publish_started@1 interrupted:browser_disconnected@1]" {
		t.Fatalf("delivered = %s", got)
	}
}

func TestACloseThatReturnsAnErrorDoesNotPreventTheSessionFromEnding(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.pub.mu.Lock()
	s.pub.closeErr = fmt.Errorf("%w: test", errors.New("drain timed out"))
	s.pub.mu.Unlock()

	s.conn.end("user_stop")
	h.waitDone(s.sess)
	if got := fmt.Sprint(h.ev.kinds()); got != "[publish_started session_ended]" {
		t.Fatalf("events = %s: the application must still hear that the session ended", got)
	}
	if h.reg.Count() != 0 {
		t.Fatalf("Count = %d", h.reg.Count())
	}
}

func TestADuplicateStartIsHarmless(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	s.conn.audio(0, audioPayload(1, 20))
	h.settle()
	tagsBefore := len(s.pub.tags())
	s.conn.start("720p")
	s.conn.start("720p")
	h.settle()
	if got := len(h.be.provisions()); got != 1 {
		t.Fatalf("provision calls = %d", got)
	}
	if got := h.fac.openCount(); got != 1 {
		t.Fatalf("Open calls = %d", got)
	}
	if got := len(s.pub.tags()); got != tagsBefore {
		t.Fatalf("tags = %d (was %d): a repeated start with the same configuration writes nothing", got, tagsBefore)
	}
	if s.sess.State() != StateStreaming {
		t.Fatalf("state = %v", s.sess.State())
	}
	expectSequence(t, s.conn.link, "accepted", "status:awaiting_media", "status:confirming")
}

// 閉じている最中の取り込みセッションへの再接続は、その終了を待って、新しい取り込みセッションに結びつく。
func TestAHelloForASessionThatIsStillClosingWaitsAndStartsANewSession(t *testing.T) {
	h := newHarness(t)
	old := h.bringUp("t1", idA, 1)
	release := make(chan struct{})
	old.pub.mu.Lock()
	old.pub.closeGate = release
	old.pub.mu.Unlock()
	old.conn.end("user_stop") // 送り切れないまま、閉じている最中

	h.be.addTicket("t2", verifyResult(idA, 2, contract.BroadcastStateInterrupted))
	conn := h.connect()
	conn.hello("t2")
	time.Sleep(20 * time.Millisecond) // 待っている間は、受理しない
	if got := conn.link.sequence(t); len(got) != 0 {
		t.Fatalf("link sequence = %v while the old session was still closing", got)
	}
	close(release)
	h.waitDone(old.sess)
	h.settle()
	expectSequence(t, conn.link, "accepted")
	renewed := h.mustSession(idA)
	if renewed == old.sess {
		t.Fatal("the closed session was reused")
	}
	if renewed.Epoch() != 2 {
		t.Fatalf("epoch = %d", renewed.Epoch())
	}
}

func TestManySessionsRunIndependently(t *testing.T) {
	const sessions = 30
	const frames = 100
	h := newHarness(t)
	h.be.setProvision(func(call provisionCall) (backend.ProvisionResult, error) {
		result := defaultProvisionResult()
		result.Ingest.StreamKey = backendStreamKey("dummy-key-" + call.broadcastID)
		return result, nil
	})
	type member struct {
		id   string
		conn *testConn
	}
	members := make([]member, sessions)
	for i := range members {
		id := fmt.Sprintf("%08x-0000-4000-8000-%012x", i+1, i+1)
		account := fmt.Sprintf("%064x", i+1)
		ticket := fmt.Sprintf("ticket-%d", i)
		h.be.addTicket(ticket, backendVerifyFor(id, 1, account))
		conn := h.connect()
		conn.hello(ticket)
		members[i] = member{id: id, conn: conn}
	}
	h.settle()
	for _, m := range members {
		m.conn.start("720p")
	}
	h.settle()
	h.clock.Advance(h.opts.PublishConfirmWindow)
	h.settle()
	if h.reg.Count() != sessions {
		t.Fatalf("Count = %d, want %d (each account has its own session)", h.reg.Count(), sessions)
	}

	var wg sync.WaitGroup
	for _, m := range members {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for f := 0; f < frames; f++ {
				for _, input := range []frame.Frame{
					{Type: contract.FrameTypeVideo, Keyframe: f == 0, TimestampUs: uint64(f) * 33333, Body: videoPayload(byte(f), 30)},
					{Type: contract.FrameTypeAudio, TimestampUs: uint64(f) * 23220, Body: audioPayload(byte(f), 20)},
				} {
					message, err := frame.Encode(input)
					if err != nil {
						panic(err)
					}
					m.conn.conn.Handle(message)
				}
			}
		}()
	}
	wg.Wait()
	h.settle()

	for _, m := range members {
		pub := h.fac.forKey("dummy-key-" + m.id)
		if pub == nil {
			t.Fatalf("no publisher for %s", m.id)
		}
		if got := len(mediaTags(pub.tags())); got != 2*frames {
			t.Fatalf("%s: %d media tags, want %d", m.id, got, 2*frames)
		}
		if s := h.mustSession(m.id); s.State() != StateStreaming {
			t.Fatalf("%s: state = %v", m.id, s.State())
		}
	}
}

func backendStreamKey(value string) rtmps.StreamKey { return rtmps.StreamKey(value) }

func TestEachConnectionHasItsOwnIngressWindow(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	for i := 0; i < 5; i++ {
		s.conn.probe(flood)
	}
	h.settle()
	s.conn.conn.Disconnected()
	h.settle()
	resumed := h.resumeConnect("t2", idA, 2, contract.BroadcastStateInterrupted)
	for i := 0; i < 5; i++ {
		resumed.probe(flood) // 新しい接続の窓は、空から始まる（接続ごとに数える）
	}
	h.settle()
	if h.mustSession(idA).State() == StateClosed {
		t.Fatal("a new connection inherited the ingress counted on the previous one")
	}
}

func TestDependenciesAreRequired(t *testing.T) {
	// 捨てる出力先も、明示して渡す（nil は、本番の結線の抜けとして拒否する。ログが黙って捨てられ、異常に気づけなくなるため）
	good := Deps{Backend: newFakeBackend(), Events: &fakeEvents{}, Publishers: newFakeFactory(), Clock: newFakeClock(), Logger: slog.New(slog.DiscardHandler)}
	cases := []struct {
		name   string
		mutate func(d *Deps)
	}{
		{"アプリケーションの境界が無い", func(d *Deps) { d.Backend = nil }},
		{"事象の送り先が無い", func(d *Deps) { d.Events = nil }},
		{"RTMPS の境界が無い", func(d *Deps) { d.Publishers = nil }},
		{"時計が無い", func(d *Deps) { d.Clock = nil }},
		{"ログの出力先が無い", func(d *Deps) { d.Logger = nil }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			deps := good
			c.mutate(&deps)
			if _, err := NewRegistry(deps); !errors.Is(err, ErrInvalidDeps) {
				t.Fatalf("NewRegistry error = %v, want ErrInvalidDeps", err)
			}
			if _, err := NewIngestSession(Params{BroadcastID: idA, AccountKey: accountX}, deps); !errors.Is(err, ErrInvalidDeps) {
				t.Fatalf("NewIngestSession error = %v, want ErrInvalidDeps", err)
			}
		})
	}
	if _, err := NewRegistry(Deps{Backend: good.Backend, Events: good.Events, Publishers: good.Publishers, Clock: good.Clock, Logger: good.Logger, Options: Options{HelloTimeout: -1}}); !errors.Is(err, ErrInvalidOptions) {
		t.Fatalf("invalid options error = %v", err)
	}
	if _, err := NewIngestSession(Params{AccountKey: accountX}, good); !errors.Is(err, ErrInvalidParams) {
		t.Fatalf("missing broadcast id error = %v", err)
	}
	if _, err := NewIngestSession(Params{BroadcastID: idA}, good); !errors.Is(err, ErrInvalidParams) {
		t.Fatalf("missing account key error = %v", err)
	}
}

func TestStateNames(t *testing.T) {
	want := map[State]string{
		StateVerified: "verified", StateProbing: "probing", StatePreparing: "preparing",
		StateStreaming: "streaming", StateInterrupted: "interrupted", StateClosed: "closed", State(99): "unknown",
	}
	for state, name := range want {
		if state.String() != name {
			t.Errorf("State(%d) = %q, want %q", state, state.String(), name)
		}
	}
}

func TestSystemClockSatisfiesTheClockContract(t *testing.T) {
	var clock Clock = SystemClock{}
	before := time.Now()
	if now := clock.Now(); now.Before(before) {
		t.Fatalf("Now went back: %v < %v", now, before)
	}
	var fired atomic.Int32
	timer := clock.AfterFunc(5*time.Millisecond, func() { fired.Add(1) })
	deadline := time.Now().Add(5 * time.Second)
	for fired.Load() == 0 {
		if time.Now().After(deadline) {
			t.Fatal("the timer did not fire")
		}
		time.Sleep(time.Millisecond)
	}
	if timer.Stop() {
		t.Fatal("Stop reported that it stopped a timer that had fired")
	}
	if timer.Reset(5 * time.Millisecond) {
		t.Fatal("Reset reported that the timer was active")
	}
	for fired.Load() < 2 {
		if time.Now().After(deadline) {
			t.Fatal("the timer did not fire again after Reset")
		}
		time.Sleep(time.Millisecond)
	}
	stopped := clock.AfterFunc(time.Hour, func() { t.Error("a stopped timer fired") })
	if !stopped.Stop() {
		t.Fatal("Stop of an active timer returned false")
	}
}
