package backend

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// 事象のキュー（契約 internal-api.md の events。requirements.md 6.1・27 章）の試験。
// アプリケーションに到達できない間、事象をメモリのキュー（上限あり）に保持し、指数的な待機で再送する。順序を保つ。
// 時計は注入する（待機を実時間で待たない）。

const (
	idA = "11111111-1111-4111-8111-111111111111"
	idB = "22222222-2222-4222-8222-222222222222"
)

type sentEvent struct {
	id string
	ev EventRequest
}

// fakeSender は、事象の送り先の疑似。results を 1 回の試行ごとに 1 つ使う（尽きたら defaultResult）。
type fakeSender struct {
	mu            sync.Mutex
	attempts      []sentEvent
	delivered     []sentEvent
	results       []error
	defaultResult error
	failFor       map[string]error // 配信ごとの固定の結果（results より優先）
	inflight      int
	maxInflight   int
	gate          chan struct{} // 非 nil なら、Event は閉じられるまで（または ctx が終わるまで）戻らない
	entered       chan struct{} // gate で止まった試行ごとに 1 つ送る（容量を持つ）
}

func newFakeSender() *fakeSender {
	return &fakeSender{entered: make(chan struct{}, 4096)}
}

func (f *fakeSender) Event(ctx context.Context, broadcastID string, ev EventRequest) error {
	f.mu.Lock()
	f.attempts = append(f.attempts, sentEvent{broadcastID, ev})
	f.inflight++
	if f.inflight > f.maxInflight {
		f.maxInflight = f.inflight
	}
	gate := f.gate
	f.mu.Unlock()

	if gate != nil {
		f.entered <- struct{}{}
		select {
		case <-gate:
		case <-ctx.Done():
			f.mu.Lock()
			f.inflight--
			f.mu.Unlock()
			return ctx.Err()
		}
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	f.inflight--
	var result error
	if forced, ok := f.failFor[broadcastID]; ok {
		result = forced
	} else if len(f.results) > 0 {
		result = f.results[0]
		f.results = f.results[1:]
	} else {
		result = f.defaultResult
	}
	if result == nil {
		f.delivered = append(f.delivered, sentEvent{broadcastID, ev})
	}
	return result
}

func (f *fakeSender) deliveredKinds() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	kinds := make([]string, 0, len(f.delivered))
	for _, d := range f.delivered {
		kinds = append(kinds, fmt.Sprintf("%s:%d", d.id[:1], d.ev.Epoch))
	}
	return kinds
}

func (f *fakeSender) attemptCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.attempts)
}

// fakeWaiter は、待機の疑似。auto が真なら、待機はすぐに終わる。偽なら、fire が呼ばれるまで終わらない。
type fakeWaiter struct {
	mu      sync.Mutex
	auto    bool
	waits   []time.Duration
	pending []chan time.Time
}

func (w *fakeWaiter) After(d time.Duration) <-chan time.Time {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.waits = append(w.waits, d)
	ch := make(chan time.Time, 1)
	if w.auto {
		ch <- time.Time{}
	} else {
		w.pending = append(w.pending, ch)
	}
	return ch
}

func (w *fakeWaiter) recorded() []time.Duration {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]time.Duration(nil), w.waits...)
}

func (w *fakeWaiter) fireOne() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.pending) == 0 {
		return false
	}
	w.pending[0] <- time.Time{}
	w.pending = w.pending[1:]
	return true
}

// waitFor は、条件が成り立つのを待つ（実時間で最大 5 秒。ゴルーチンの進行を待つだけで、時計の待機ではない）。
func waitFor(t *testing.T, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for: %s", what)
		}
		runtime.Gosched()
		time.Sleep(100 * time.Microsecond)
	}
}

func testEvent(epoch int) EventRequest {
	return EventRequest{Epoch: epoch, Kind: contract.RelayEventKindResumed, At: time.Unix(int64(epoch), 0)}
}

func newTestQueue(t *testing.T, sender EventSender, waiter Waiter, opts QueueOptions) *EventQueue {
	t.Helper()
	queue, err := NewEventQueue(sender, waiter, opts, slog.New(slog.DiscardHandler))
	if err != nil {
		t.Fatalf("NewEventQueue: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = queue.Shutdown(ctx)
	})
	return queue
}

func unavailable() error { return fmt.Errorf("%w: test", ErrUnavailable) }

func TestNewEventQueueChecksItsArguments(t *testing.T) {
	sender, waiter := newFakeSender(), &fakeWaiter{auto: true}
	discard := slog.New(slog.DiscardHandler) // 捨てる出力先は、明示して渡す（nil は、本番の結線の抜けとして拒否する）
	cases := []struct {
		name    string
		sender  EventSender
		waiter  Waiter
		opts    QueueOptions
		log     *slog.Logger
		wantErr bool
	}{
		{"既定値", sender, waiter, QueueOptions{}, discard, false},
		{"送り先が無い", nil, waiter, QueueOptions{}, discard, true},
		{"待機が無い", sender, nil, QueueOptions{}, discard, true},
		{"ログの出力先が無い", sender, waiter, QueueOptions{}, nil, true},
		{"上限が負", sender, waiter, QueueOptions{MaxEvents: -1}, discard, true},
		{"最初の待機が負", sender, waiter, QueueOptions{InitialBackoff: -time.Second}, discard, true},
		{"待機の上限が負", sender, waiter, QueueOptions{MaxBackoff: -time.Second}, discard, true},
		{"待機の上限が最初より小さい", sender, waiter, QueueOptions{InitialBackoff: 2 * time.Second, MaxBackoff: time.Second}, discard, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := NewEventQueue(c.sender, c.waiter, c.opts, c.log)
			if c.wantErr != (err != nil) {
				t.Fatalf("error = %v, wantErr %v", err, c.wantErr)
			}
			if c.wantErr && !isError(err, ErrInvalidConfig) {
				t.Fatalf("error = %v, want ErrInvalidConfig", err)
			}
		})
	}
}

func TestDefaultQueueOptions(t *testing.T) {
	got := DefaultQueueOptions()
	if got.MaxEvents != 1024 || got.InitialBackoff != 500*time.Millisecond || got.MaxBackoff != 5*time.Second {
		t.Fatalf("DefaultQueueOptions = %+v", got)
	}
}

func TestEventsAreSentInOrderOneAtATime(t *testing.T) {
	sender := newFakeSender()
	queue := newTestQueue(t, sender, &fakeWaiter{auto: true}, QueueOptions{})
	for epoch := 1; epoch <= 20; epoch++ {
		queue.Enqueue(idA, testEvent(epoch))
	}
	waitFor(t, "20 events delivered", func() bool { return len(sender.deliveredKinds()) == 20 })

	for i, kind := range sender.deliveredKinds() {
		if want := fmt.Sprintf("1:%d", i+1); kind != want {
			t.Fatalf("delivery %d = %s, want %s (the order was not kept)", i, kind, want)
		}
	}
	if sender.maxInflight != 1 {
		t.Fatalf("max in-flight = %d, want 1 (the next event is sent after the previous one is acknowledged)", sender.maxInflight)
	}
	if got := queue.Len(); got != 0 {
		t.Fatalf("Len = %d", got)
	}
}

func TestEventsAreHeldAndResentWithExponentialBackoff(t *testing.T) {
	sender := newFakeSender()
	sender.results = []error{unavailable(), unavailable(), unavailable(), unavailable(), unavailable(), unavailable()} // 6 回の不達のあと、成功
	waiter := &fakeWaiter{auto: true}
	queue := newTestQueue(t, sender, waiter, QueueOptions{})
	queue.Enqueue(idA, testEvent(1))
	queue.Enqueue(idA, testEvent(2))
	waitFor(t, "both delivered", func() bool { return len(sender.deliveredKinds()) == 2 })

	// 500 ms から倍にし、上限 5 秒（契約 deadlines.reconnect_backoff_cap_ms と同じ形）
	want := []time.Duration{500 * time.Millisecond, time.Second, 2 * time.Second, 4 * time.Second, 5 * time.Second, 5 * time.Second}
	got := waiter.recorded()
	if len(got) != len(want) {
		t.Fatalf("waits = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("waits = %v, want %v", got, want)
		}
	}
	// 先頭の事象が届くまで、次の事象を送らない（順序を保つ）。先頭は 7 回試行し、そのあとで 2 つ目
	sender.mu.Lock()
	defer sender.mu.Unlock()
	if len(sender.attempts) != 8 {
		t.Fatalf("attempts = %d, want 8 (7 for the first event, 1 for the second)", len(sender.attempts))
	}
	for i := 0; i < 7; i++ {
		if sender.attempts[i].ev.Epoch != 1 {
			t.Fatalf("attempt %d was for epoch %d, want the first event until it is delivered", i, sender.attempts[i].ev.Epoch)
		}
	}
	if sender.attempts[7].ev.Epoch != 2 {
		t.Fatalf("the second event was not sent last")
	}
	// 同じ事象の再送は、同じ内容
	for i := 1; i < 7; i++ {
		if sender.attempts[i].ev != sender.attempts[0].ev {
			t.Fatalf("attempt %d differs from the first (a resend must be identical)", i)
		}
	}
}

func TestBackoffRestartsAfterASuccess(t *testing.T) {
	sender := newFakeSender()
	sender.results = []error{unavailable(), unavailable(), nil, unavailable()}
	waiter := &fakeWaiter{auto: true}
	queue := newTestQueue(t, sender, waiter, QueueOptions{})
	queue.Enqueue(idA, testEvent(1))
	queue.Enqueue(idA, testEvent(2))
	waitFor(t, "both delivered", func() bool { return len(sender.deliveredKinds()) == 2 })

	got := waiter.recorded()
	want := []time.Duration{500 * time.Millisecond, time.Second, 500 * time.Millisecond}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("waits = %v, want %v (the wait restarts from the initial value after a success)", got, want)
	}
}

func TestBackoffCanBeConfigured(t *testing.T) {
	sender := newFakeSender()
	sender.results = []error{unavailable(), unavailable(), unavailable()}
	waiter := &fakeWaiter{auto: true}
	queue := newTestQueue(t, sender, waiter, QueueOptions{InitialBackoff: 10 * time.Millisecond, MaxBackoff: 30 * time.Millisecond})
	queue.Enqueue(idA, testEvent(1))
	waitFor(t, "delivered", func() bool { return len(sender.deliveredKinds()) == 1 })
	want := []time.Duration{10 * time.Millisecond, 20 * time.Millisecond, 30 * time.Millisecond}
	if got := waiter.recorded(); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("waits = %v, want %v", got, want)
	}
}

func TestNotFoundDropsThatBroadcastsEventsOnly(t *testing.T) {
	sender := newFakeSender()
	sender.failFor = map[string]error{idA: fmt.Errorf("%w: gone", ErrNotFound)}
	queue := newTestQueue(t, sender, &fakeWaiter{auto: true}, QueueOptions{})
	queue.Enqueue(idA, testEvent(1))
	queue.Enqueue(idB, testEvent(1))
	queue.Enqueue(idA, testEvent(2))
	queue.Enqueue(idB, testEvent(2))
	waitFor(t, "B delivered", func() bool { return len(sender.deliveredKinds()) == 2 })
	waitFor(t, "queue empty", func() bool { return queue.Len() == 0 })

	if got := sender.deliveredKinds(); fmt.Sprint(got) != "[2:1 2:2]" {
		t.Fatalf("delivered = %v, want only B's events in order", got)
	}
	// A の 2 つ目は、試行すらしない（404 を得た配信の事象は破棄する）
	sender.mu.Lock()
	defer sender.mu.Unlock()
	for _, attempt := range sender.attempts {
		if attempt.id == idA && attempt.ev.Epoch == 2 {
			t.Fatalf("an event of a broadcast that returned 404 was sent")
		}
	}
	if queue.Dropped() != 2 {
		t.Fatalf("Dropped = %d, want 2", queue.Dropped())
	}
}

func TestNonRetryableFailuresDropOnlyThatEvent(t *testing.T) {
	failures := map[string]error{
		"入力の不備":  fmt.Errorf("%w: x", ErrInvalidInput),
		"認証の失敗":  fmt.Errorf("%w: x", ErrUnauthorized),
		"想定外の状態": fmt.Errorf("%w: x", ErrUnexpectedStatus),
		"引数の不備":  fmt.Errorf("%w: x", ErrInvalidArgument),
		"未知のエラー": errors.New("something else"),
	}
	for name, failure := range failures {
		t.Run(name, func(t *testing.T) {
			sender := newFakeSender()
			sender.results = []error{failure} // 1 つ目だけ失敗。以後は成功
			waiter := &fakeWaiter{auto: true}
			queue := newTestQueue(t, sender, waiter, QueueOptions{})
			queue.Enqueue(idA, testEvent(1))
			queue.Enqueue(idA, testEvent(2))
			waitFor(t, "second delivered", func() bool { return len(sender.deliveredKinds()) == 1 })
			if got := sender.deliveredKinds(); fmt.Sprint(got) != "[1:2]" {
				t.Fatalf("delivered = %v", got)
			}
			if got := len(waiter.recorded()); got != 0 {
				t.Fatalf("waited %d times (a non-retryable failure must not be retried)", got)
			}
			if queue.Dropped() != 1 {
				t.Fatalf("Dropped = %d, want 1", queue.Dropped())
			}
		})
	}
}

func TestTheQueueIsBoundedAndDropsTheOldest(t *testing.T) {
	sender := newFakeSender()
	sender.gate = make(chan struct{})
	queue := newTestQueue(t, sender, &fakeWaiter{auto: true}, QueueOptions{MaxEvents: 3})

	queue.Enqueue(idA, testEvent(1))
	<-sender.entered // 1 つ目は送信中（応答待ち）
	for epoch := 2; epoch <= 10; epoch++ {
		queue.Enqueue(idA, testEvent(epoch))
	}
	if got := queue.Len(); got != 4 { // 送信中の 1 つ + 保持している 3 つ
		t.Fatalf("Len = %d, want 4 (1 in flight + 3 held)", got)
	}
	if got := queue.Dropped(); got != 6 {
		t.Fatalf("Dropped = %d, want 6 (events 2 to 7)", got)
	}
	close(sender.gate)
	waitFor(t, "delivered", func() bool { return len(sender.deliveredKinds()) == 4 })
	// 送信中だった 1 つ目と、最新の 3 つ（8・9・10）が、この順に届く
	if got := sender.deliveredKinds(); fmt.Sprint(got) != "[1:1 1:8 1:9 1:10]" {
		t.Fatalf("delivered = %v", got)
	}
}

func TestEnqueueNeverBlocksEvenWhenTheApplicationIsStuck(t *testing.T) {
	sender := newFakeSender()
	sender.gate = make(chan struct{})
	queue := newTestQueue(t, sender, &fakeWaiter{auto: true}, QueueOptions{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		for epoch := 1; epoch <= 5000; epoch++ {
			queue.Enqueue(idA, testEvent(epoch))
		}
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Enqueue blocked")
	}
	close(sender.gate)
}

func TestTheWorkerStopsWhenTheQueueIsEmpty(t *testing.T) {
	sender := newFakeSender()
	queue := newTestQueue(t, sender, &fakeWaiter{auto: true}, QueueOptions{})
	queue.Enqueue(idA, testEvent(1))
	waitFor(t, "delivered", func() bool { return len(sender.deliveredKinds()) == 1 })
	assertNoGoroutines(t, "backend.(*EventQueue)")

	// 空になったあとの事象も、送れる（作業のゴルーチンは、必要になったときに再び始まる）
	queue.Enqueue(idA, testEvent(2))
	waitFor(t, "second delivered", func() bool { return len(sender.deliveredKinds()) == 2 })
	assertNoGoroutines(t, "backend.(*EventQueue)")
}

func TestShutdownWaitsForTheQueueToDrain(t *testing.T) {
	sender := newFakeSender()
	sender.results = []error{unavailable(), unavailable()}
	waiter := &fakeWaiter{} // 手動
	queue := newTestQueue(t, sender, waiter, QueueOptions{})
	queue.Enqueue(idA, testEvent(1))
	queue.Enqueue(idA, testEvent(2))

	result := make(chan error, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		result <- queue.Shutdown(ctx)
	}()
	// 待機を 2 回進めると、事象が届き、Shutdown が戻る
	for fired := 0; fired < 2; {
		if waiter.fireOne() {
			fired++
		} else {
			runtime.Gosched()
		}
	}
	select {
	case err := <-result:
		if err != nil {
			t.Fatalf("Shutdown: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Shutdown did not return")
	}
	if got := sender.deliveredKinds(); fmt.Sprint(got) != "[1:1 1:2]" {
		t.Fatalf("delivered = %v", got)
	}
	assertNoGoroutines(t, "backend.(*EventQueue)")
}

func TestShutdownGivesUpAtTheDeadlineAndDropsTheRest(t *testing.T) {
	sender := newFakeSender()
	sender.defaultResult = unavailable()
	waiter := &fakeWaiter{} // 進めない（アプリケーションが戻らない）
	queue := newTestQueue(t, sender, waiter, QueueOptions{})
	queue.Enqueue(idA, testEvent(1))
	queue.Enqueue(idA, testEvent(2))
	waitFor(t, "first attempt waiting", func() bool { return len(waiter.recorded()) == 1 })

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := queue.Shutdown(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("Shutdown error = %v, want context.Canceled", err)
	}
	assertNoGoroutines(t, "backend.(*EventQueue)")
	if got := queue.Len(); got != 0 {
		t.Fatalf("Len = %d after Shutdown", got)
	}
	if got := queue.Dropped(); got != 2 {
		t.Fatalf("Dropped = %d, want 2", got)
	}
}

func TestEnqueueAfterShutdownIsDropped(t *testing.T) {
	sender := newFakeSender()
	queue := newTestQueue(t, sender, &fakeWaiter{auto: true}, QueueOptions{})
	if err := queue.Shutdown(context.Background()); err != nil {
		t.Fatalf("Shutdown: %v", err)
	}
	queue.Enqueue(idA, testEvent(1))
	if got := sender.attemptCount(); got != 0 {
		t.Fatalf("a closed queue sent an event (%d)", got)
	}
	if queue.Dropped() != 1 {
		t.Fatalf("Dropped = %d, want 1", queue.Dropped())
	}
	assertNoGoroutines(t, "backend.(*EventQueue)")
}

func TestOrderIsKeptPerBroadcastWhenInterleaved(t *testing.T) {
	sender := newFakeSender()
	sender.results = []error{unavailable(), nil, unavailable()}
	queue := newTestQueue(t, sender, &fakeWaiter{auto: true}, QueueOptions{})
	for epoch := 1; epoch <= 5; epoch++ {
		queue.Enqueue(idA, testEvent(epoch))
		queue.Enqueue(idB, testEvent(epoch))
	}
	waitFor(t, "all delivered", func() bool { return len(sender.deliveredKinds()) == 10 })
	var a, b []int
	for _, d := range sender.delivered {
		if d.id == idA {
			a = append(a, d.ev.Epoch)
		} else {
			b = append(b, d.ev.Epoch)
		}
	}
	if fmt.Sprint(a) != "[1 2 3 4 5]" || fmt.Sprint(b) != "[1 2 3 4 5]" {
		t.Fatalf("A = %v, B = %v", a, b)
	}
}

func TestConcurrentEnqueueDeliversEverything(t *testing.T) {
	sender := newFakeSender()
	queue := newTestQueue(t, sender, &fakeWaiter{auto: true}, QueueOptions{MaxEvents: 4096})
	var wg sync.WaitGroup
	for g := 0; g < 20; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 50; i++ {
				queue.Enqueue(idA, testEvent(i+1))
			}
		}()
	}
	wg.Wait()
	waitFor(t, "1000 delivered", func() bool { return len(sender.deliveredKinds()) == 1000 })
	if queue.Dropped() != 0 {
		t.Fatalf("Dropped = %d", queue.Dropped())
	}
}

func TestQueueLogsDoNotContainErrorText(t *testing.T) {
	var logs bytes.Buffer
	sender := newFakeSender()
	sender.results = []error{errors.New("boom " + canarySecret), fmt.Errorf("%w: %s", ErrNotFound, canaryTicket)}
	waiter := &fakeWaiter{auto: true}
	queue, err := NewEventQueue(sender, waiter, QueueOptions{}, slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug})))
	if err != nil {
		t.Fatalf("NewEventQueue: %v", err)
	}
	queue.Enqueue(idA, testEvent(1))
	queue.Enqueue(idB, testEvent(1))
	waitFor(t, "processed", func() bool { return queue.Len() == 0 && sender.attemptCount() == 2 })
	if err := queue.Shutdown(context.Background()); err != nil {
		t.Fatalf("Shutdown: %v", err)
	}
	if strings.Contains(logs.String(), "CANARY") {
		t.Fatalf("the log leaks error text: %s", logs.String())
	}
	if !strings.Contains(logs.String(), idA) {
		t.Fatalf("the log has no broadcast id: %s", logs.String())
	}
}

// assertNoGoroutines は、スタックに substr を含むゴルーチンが残っていないことを確かめる（終わるのを最大 5 秒待つ）。
func assertNoGoroutines(t *testing.T, substr string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		found := goroutinesContaining(substr)
		if len(found) == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("goroutines remain (%q):\n%s", substr, strings.Join(found, "\n---\n"))
		}
		runtime.Gosched()
		time.Sleep(time.Millisecond)
	}
}

func goroutinesContaining(substr string) []string {
	buffer := make([]byte, 1<<20)
	for {
		n := runtime.Stack(buffer, true)
		if n < len(buffer) {
			buffer = buffer[:n]
			break
		}
		buffer = make([]byte, 2*len(buffer))
	}
	var found []string
	for _, block := range strings.Split(string(buffer), "\n\n") {
		if strings.Contains(block, "assertNoGoroutines") || strings.Contains(block, "goroutinesContaining") {
			continue // 検査している自分
		}
		if strings.Contains(block, substr) {
			found = append(found, block)
		}
	}
	return found
}
