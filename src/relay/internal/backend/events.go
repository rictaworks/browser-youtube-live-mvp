package backend

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"
)

// 事象の保持と再送（requirements.md 6.1・27 章。契約 internal-api.md の events）。
//
// データ面（メディアの転送）は、制御面（アプリケーション）の 60 秒以内の不達で止まらない。そのため、アプリケーションへ到達できない間、
// 事象はメモリのキュー（上限あり）に保持し、指数的な待機で再送する。事象は、発生順に 1 つずつ送り、204 を得てから次を送る（順序を保つ）。
// 同じ事象の再送は、冪等（アプリケーションは、古い送出世代・終了済みの配信の事象を無視する）。

const (
	// DefaultMaxEvents は、保持する事象の既定の上限。事象は状態の変化のときだけ起きる（1 配信で数十件）ので、十分に大きい。
	DefaultMaxEvents = 1024
	// DefaultInitialBackoff は、再送の最初の待機。倍々に増やす。
	DefaultInitialBackoff = 500 * time.Millisecond
	// DefaultMaxBackoff は、再送の待機の上限（契約 deadlines.reconnect_backoff_cap_ms と同じ 5 秒）。アプリケーションの復旧から、
	// 事象が届くまでの遅れを、この長さに抑える。
	DefaultMaxBackoff = 5 * time.Second

	backoffFactor = 2
)

// EventSender は、事象を 1 回送る（*Client が満たす）。
type EventSender interface {
	Event(ctx context.Context, broadcastID string, event EventRequest) error
}

// Waiter は、待機（再送の間隔）。時計を注入するための境界で、試験は疑似の実装を使う。
type Waiter interface {
	// After は、d が経ったら値が届くチャネルを返す。
	After(d time.Duration) <-chan time.Time
}

// QueueOptions は、EventQueue の設定。ゼロの欄は既定値。負は ErrInvalidConfig。
type QueueOptions struct {
	// MaxEvents は、保持する事象の上限（送信中の 1 件を除く）。超えたら、古いものから捨てる（最新の状態を残す）。
	MaxEvents int
	// InitialBackoff は、再送の最初の待機。
	InitialBackoff time.Duration
	// MaxBackoff は、再送の待機の上限。
	MaxBackoff time.Duration
}

// DefaultQueueOptions は、既定の設定。
func DefaultQueueOptions() QueueOptions {
	return QueueOptions{MaxEvents: DefaultMaxEvents, InitialBackoff: DefaultInitialBackoff, MaxBackoff: DefaultMaxBackoff}
}

func (o QueueOptions) normalized() (QueueOptions, error) {
	defaults := DefaultQueueOptions()
	if o.MaxEvents < 0 || o.InitialBackoff < 0 || o.MaxBackoff < 0 {
		return QueueOptions{}, fmt.Errorf("%w: a queue option is negative", ErrInvalidConfig)
	}
	if o.MaxEvents == 0 {
		o.MaxEvents = defaults.MaxEvents
	}
	if o.InitialBackoff == 0 {
		o.InitialBackoff = defaults.InitialBackoff
	}
	if o.MaxBackoff == 0 {
		o.MaxBackoff = defaults.MaxBackoff
	}
	if o.MaxBackoff < o.InitialBackoff {
		return QueueOptions{}, fmt.Errorf("%w: the maximum backoff is shorter than the initial backoff", ErrInvalidConfig)
	}
	return o, nil
}

// backoff は、attempt 回目（0 始まり）の失敗のあとの待機。最初の待機を倍々にし、上限で止める。
func (o QueueOptions) backoff(attempt int) time.Duration {
	wait := o.InitialBackoff
	for i := 0; i < attempt; i++ {
		if wait >= o.MaxBackoff/backoffFactor { // 次の倍が上限以上（桁あふれもここで避ける）
			return o.MaxBackoff
		}
		wait *= backoffFactor
	}
	return min(wait, o.MaxBackoff)
}

type queued struct {
	id    string
	event EventRequest
}

// 送信の結果の分類。
type outcome int

const (
	outcomeDelivered outcome = iota // 届いた
	outcomeRetry                    // 到達できない・一時的な失敗。待って再送する
	outcomeGone                     // 配信が無い（404）。その配信の事象をすべて捨てる
	outcomeDrop                     // 再送しても変わらない失敗。この事象だけ捨てる
	outcomeStop                     // 呼び出しの取り消し（停止）
)

// classify は、Event の結果を分類する。ログには、この分類だけを出す（エラーの文言は、出さない）。
func classify(err error) (outcome, string) {
	switch {
	case err == nil:
		return outcomeDelivered, "delivered"
	case errors.Is(err, context.Canceled):
		return outcomeStop, "canceled"
	case errors.Is(err, ErrUnavailable):
		return outcomeRetry, "unavailable"
	case errors.Is(err, ErrNotFound):
		return outcomeGone, "not_found"
	case errors.Is(err, ErrUnauthorized):
		return outcomeDrop, "unauthorized"
	case errors.Is(err, ErrInvalidInput):
		return outcomeDrop, "invalid_input"
	case errors.Is(err, ErrUnexpectedStatus):
		return outcomeDrop, "unexpected_status"
	case errors.Is(err, ErrInvalidArgument):
		return outcomeDrop, "invalid_argument"
	default:
		return outcomeDrop, "unknown"
	}
}

// EventQueue は、事象の保持と再送。ゴルーチンから並行に呼んでよい。
//
// 作業のゴルーチンは、キューに事象があるときだけ動く（空になれば終わり、次の Enqueue で始まる）。Enqueue は、呼び出し元を
// ブロックしない。アプリケーションの不達が続いて上限を超えたら、古い事象から捨てる（最新の状態を残す）。
// 404（not_found）を得た配信の事象は、その配信のものをすべて捨てる（永久に再送して、キューを詰まらせない）。
// 再送しても変わらない失敗（認証の失敗・入力の不備・想定外のステータス）は、その事象だけを捨てて、次へ進む。
type EventQueue struct {
	sender EventSender
	waiter Waiter
	opts   QueueOptions
	log    *slog.Logger

	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup

	mu       sync.Mutex
	items    []queued
	inflight *queued
	running  bool
	closing  bool
	idle     chan struct{} // 作業のゴルーチンが終わったら閉じる
	dropped  int
}

// NewEventQueue は、事象のキューを作る。sender・waiter・log が nil、設定が不正なら ErrInvalidConfig。
// log は必須（事象の捨て・再送の記録が、黙って捨てられ、異常に気づけなくならないように。捨ててよい試験は、捨てる出力先を明示して渡す）。
func NewEventQueue(sender EventSender, waiter Waiter, opts QueueOptions, log *slog.Logger) (*EventQueue, error) {
	if sender == nil || waiter == nil || log == nil {
		return nil, fmt.Errorf("%w: the sender, the waiter and the logger are required", ErrInvalidConfig)
	}
	normalized, err := opts.normalized()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &EventQueue{sender: sender, waiter: waiter, opts: normalized, log: log, ctx: ctx, cancel: cancel}, nil
}

// Enqueue は、事象をキューへ積む。呼び出し元をブロックしない。閉じたキューへの事象は、捨てる。
func (q *EventQueue) Enqueue(broadcastID string, event EventRequest) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closing {
		q.dropLocked(broadcastID, event, "closed")
		return
	}
	q.items = append(q.items, queued{id: broadcastID, event: event})
	for len(q.items) > q.opts.MaxEvents {
		oldest := q.items[0]
		q.items[0] = queued{}
		q.items = q.items[1:]
		q.dropLocked(oldest.id, oldest.event, "overflow")
	}
	if !q.running {
		q.running = true
		q.idle = make(chan struct{})
		q.wg.Add(1)
		go q.run()
	}
}

// Len は、まだ届いていない事象の数（送信中の 1 件を含む）。
func (q *EventQueue) Len() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	n := len(q.items)
	if q.inflight != nil {
		n++
	}
	return n
}

// Dropped は、捨てた事象の数（上限を超えた・配信が無い・再送しても変わらない失敗・閉じたあと）。
func (q *EventQueue) Dropped() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.dropped
}

// Shutdown は、新しい事象を受け付けなくし、キューが空になる（すべて届く）のを待つ。ctx が終わったら、待つのをやめて作業を止め、
// 残りを捨てて ctx のエラーを返す。戻ったあとに、このキューのゴルーチンは残らない。何度呼んでもよい。
func (q *EventQueue) Shutdown(ctx context.Context) error {
	q.mu.Lock()
	q.closing = true
	idle := q.idle
	running := q.running
	q.mu.Unlock()

	var result error
	if running {
		select {
		case <-idle:
		case <-ctx.Done():
			result = ctx.Err()
		}
	}
	q.cancel()
	q.wg.Wait()

	q.mu.Lock()
	defer q.mu.Unlock()
	if q.inflight != nil {
		q.dropLocked(q.inflight.id, q.inflight.event, "shutdown")
		q.inflight = nil
	}
	for _, item := range q.items {
		q.dropLocked(item.id, item.event, "shutdown")
	}
	q.items = nil
	return result
}

// run は、作業のゴルーチン。キューが空になるか、停止するまで、先頭から 1 つずつ送る。
func (q *EventQueue) run() {
	defer q.wg.Done()
	defer func() {
		// 想定外の panic で、中継全体を落とさない。キューは止まるが、メディアの転送は続く
		if recovered := recover(); recovered != nil {
			q.log.Error("event queue worker panicked", slog.String("panic_type", fmt.Sprintf("%T", recovered)))
			q.mu.Lock()
			defer q.mu.Unlock()
			if q.inflight != nil {
				q.dropLocked(q.inflight.id, q.inflight.event, "panic")
				q.inflight = nil
			}
			q.running = false
			close(q.idle)
		}
	}()
	for {
		item, ok := q.pop()
		if !ok {
			return
		}
		q.deliver(item)
	}
}

// pop は、先頭の事象を取り出して送信中にする。空か停止なら、作業を終える印を付けて false。
func (q *EventQueue) pop() (queued, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.ctx.Err() != nil || len(q.items) == 0 {
		q.running = false
		close(q.idle)
		return queued{}, false
	}
	head := q.items[0]
	q.items[0] = queued{}
	q.items = q.items[1:]
	q.inflight = &head
	return head, true
}

// deliver は、1 つの事象が届くまで（または捨てるまで）送る。
func (q *EventQueue) deliver(item queued) {
	for attempt := 0; ; attempt++ {
		err := q.sender.Event(q.ctx, item.id, item.event)
		result, class := classify(err)
		switch result {
		case outcomeDelivered:
			q.settle(item.id, 0, false)
			return
		case outcomeStop:
			return // 停止。残りは Shutdown が数えて捨てる
		case outcomeGone:
			q.log.Warn("events dropped: the application does not know the broadcast",
				slog.String("broadcast_id", item.id), slog.String("class", class))
			q.settle(item.id, 0, true)
			return
		case outcomeDrop:
			q.log.Error("event dropped: the application rejected it and a resend would not change that",
				slog.String("broadcast_id", item.id), slog.String("kind", string(item.event.Kind)), slog.String("class", class))
			q.settle(item.id, 1, false)
			return
		}
		// outcomeRetry: 待って再送する。最初の失敗と、2 の冪の回の失敗だけ記録する（不達が続いても、ログを埋めない）
		if attempt&(attempt+1) == 0 {
			q.log.Warn("event not delivered yet; holding it and retrying",
				slog.String("broadcast_id", item.id), slog.String("kind", string(item.event.Kind)),
				slog.Int("attempt", attempt+1), slog.String("class", class))
		}
		select {
		case <-q.waiter.After(q.opts.backoff(attempt)):
		case <-q.ctx.Done():
			return
		}
	}
}

// settle は、送信中の事象の後始末。届いた（dropped=0）、この事象だけ捨てた（dropped=1）、または配信が無い（goneBroadcast）。
func (q *EventQueue) settle(broadcastID string, dropped int, goneBroadcast bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.inflight = nil
	q.dropped += dropped
	if !goneBroadcast {
		return
	}
	q.dropped++ // 送信中だった 1 件
	kept := q.items[:0]
	for _, item := range q.items {
		if item.id == broadcastID {
			q.dropped++
			continue
		}
		kept = append(kept, item)
	}
	for i := len(kept); i < len(q.items); i++ {
		q.items[i] = queued{}
	}
	q.items = kept
}

// dropLocked は、事象を捨てた記録をつける。ログは、2 の冪の回だけ（捨てるのが続いても、ログを埋めない）。
func (q *EventQueue) dropLocked(broadcastID string, event EventRequest, why string) {
	q.dropped++
	if q.dropped&(q.dropped-1) == 0 {
		q.log.Warn("event dropped", slog.String("broadcast_id", broadcastID), slog.String("kind", string(event.Kind)),
			slog.String("why", why), slog.Int("dropped_total", q.dropped))
	}
}
