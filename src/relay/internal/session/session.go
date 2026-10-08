package session

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/buffer"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/liveness"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/rebase"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/watchdog"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/flv"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps"
)

// State は、取り込みセッションの状態（issue #20）。接続通知待ち（hello の期限 10 秒）は、接続（Connection）の状態。
type State int32

const (
	// StateVerified は、照合済み（accepted を返した。計測も開始通知も、まだ）。
	StateVerified State = iota + 1
	// StateProbing は、計測（最初の計測データを受けた）。
	StateProbing
	// StatePreparing は、開始（開始通知を受けた。準備・RTMPS の接続・確認の窓の最中）。
	StatePreparing
	// StateStreaming は、送出（RTMPS で送出中。status(confirming) を送り、メディアを受けている）。
	StateStreaming
	// StateInterrupted は、中断（ブラウザの切断・映像や音声の途絶・RTMPS の切断・送出待ちの上限）。キーフレームの到着で復帰する。
	StateInterrupted
	// StateClosed は、終了。
	StateClosed
)

func (s State) String() string {
	switch s {
	case StateVerified:
		return "verified"
	case StateProbing:
		return "probing"
	case StatePreparing:
		return "preparing"
	case StateStreaming:
		return "streaming"
	case StateInterrupted:
		return "interrupted"
	case StateClosed:
		return "closed"
	}
	return "unknown"
}

// CloseReason は、Close の理由（台帳・停止の手順が、取り込みセッションを閉じるとき）。
type CloseReason string

const (
	// CloseReasonSuperseded は、同一アカウントの新しい取り込みセッションを照合した（10.5）。バッファを破棄して直ちに切る（Abort）。
	CloseReasonSuperseded CloseReason = "superseded"
	// CloseReasonShutdown は、中継の停止。送出待ちを送り切ってから切る。ブラウザへは internal_error（復帰を試みる）。
	CloseReasonShutdown CloseReason = "shutdown"
	// CloseReasonForced は、強制。送り切るのを待たず、直ちに切る（停止の猶予を過ぎた）。
	CloseReasonForced CloseReason = "forced"
)

// phase は、取り込みセッションの内部の段階。
type phase int

const (
	phaseIdle        phase = iota // 開始通知の前
	phasePreparing                // 開始通知を受け、準備・接続・確認の窓の最中（まだ、送出を始めていない）
	phaseStreaming                // 送出中
	phaseInterrupted              // 中断
	phaseClosed
)

// Params は、取り込みセッションの作成の引数（照合の結果から）。
type Params struct {
	// BroadcastID は、配信レコードの識別子。
	BroadcastID string
	// AccountKey は、アカウントを区別する不透明な値（照合の結果）。同一アカウントの他のセッションを閉じるときの等値の比較だけに使う。
	AccountKey string
	// State は、照合のときの配信レコードの状態。reserved は新規。awaiting_media は、準備のあとで送出が始まる前。
	// confirming・live・interrupted は、復帰（中継の再起動後など、取り込みセッションが存在しなかった場合）。
	State contract.BroadcastState
	// Profile は、確定済みのプロファイル（復帰のとき）。
	Profile contract.Profile
}

// item は、取り込みセッションのイベントループが処理する 1 件。
type item struct {
	run  func()        // 処理。nil なら、時計の進みの確認だけ
	sync chan struct{} // 非 nil なら、処理と期限の評価が済んだら閉じる（試験が、処理の完了を待つため）
}

// 時刻の再基準化と時計に関する定数。
const (
	// maxMediaTimeUs は、受け入れるメディア時刻の上限（マイクロ秒）。FLV の時刻（32 ビットのミリ秒）に収まる範囲。
	// これを超える時刻は、ブラウザのクロックとして現実的ではなく、同種別の「最新の時刻」を押し上げて、以後の正しいフレームを
	// 逆行として破棄させるため、受け入れない。
	maxMediaTimeUs = uint64(1<<32-1) * 1000

	// livenessStop は、心拍の応答が得られないまま、これだけ経ったら、送出を止める（relay.heartbeat_lost_stop_seconds）。
	livenessStop = contract.RelayHeartbeatLostStopSeconds * time.Second
	// probeWindow は、最初の計測データから結果を返すまで（line_probe.duration_seconds）。
	probeWindow = contract.LineProbeDurationSeconds * time.Second

	postBackoffFactor = 2
)

// IngestSession は、配信レコードごとの取り込みセッション（requirements.md 11.9・24.3）。
//
// ブラウザからのメッセージ（計測データ・開始通知・映像・音声・状態報告・終了通知）を処理し、RTMPS の接続と配信キー（メモリのみ）を
// 保持し、アプリケーションと内部通信（準備・心拍・事象）で連携する。照合のたびに送出世代を進め、送信元（WebSocket）を新しい世代の
// 接続へ差し替える（SwapSource）。ブラウザが切れても RTMPS の接続は、中断の期限まで保持する。
//
// # 並行性
//
// 状態を持つ型（TimeGuard・TimestampRebaser・IngressPolicer・MediaWatchdog・ProbeMeter・buffer.Policy・HeartbeatLiveness）は
// 並行に呼べないので、取り込みセッションごとに 1 つのゴルーチン（イベントループ）が、すべての状態を扱う。ほかのゴルーチンは、
// 待ち行列へ処理を積むだけ（post）。アプリケーションの呼び出し（準備は数十秒かかり得る）・RTMPS の接続・後始末は、
// 別のゴルーチンで行い、結果を待ち行列に戻す。Publisher の終了は、ループ自身が、そのチャネルを見張る。そのため、準備や接続の最中も、ブラウザからのメッセージ・心拍・受領応答は止まらない。
// ループは、処理を 1 件するたびに、期限（心拍・受領応答・計測・無通信・中断の上限・再接続・心拍の応答の喪失）を評価する。
// 期限の評価は、時計の読みだけに基づく（タイマーは、ループを起こすだけ）。
//
// # ブラウザの接続との対応
//
// issue の OnHello は Connection（接続通知の期限・照合・照合前のメッセージの破棄・hello の 2 回目）と台帳の attach、
// SwapSource が担う。OnProbe・OnStart・OnMedia・OnReport・OnEnd は、Connection が種別で振り分け、このループの
// onProbe・onStart・onMedia・onReport・onEnd が処理する。
type IngestSession struct {
	id         string
	accountKey string
	deps       Deps
	opts       Options
	log        *slog.Logger

	registryRef atomic.Pointer[Registry]

	inbox      chan item
	wake       chan struct{}
	closeReq   chan CloseReason
	abortReq   chan struct{}
	loopExited chan struct{}
	done       chan struct{}
	ctx        context.Context
	cancel     context.CancelFunc
	wg         sync.WaitGroup
	workers    atomic.Int32
	startOnce  sync.Once
	forceOnce  sync.Once

	stateValue atomic.Int32
	epochValue atomic.Int64
	closing    atomic.Bool
	steps      atomic.Int64 // イベントループが処理した回数（空回りしていないことの試験用）

	// ---- 以下は、イベントループのゴルーチンだけが扱う（Start の前は、作成した側が扱う） ----

	t         time.Time // 今回の処理の時刻（処理の初めに時計から読む）
	wakeTimer Timer
	phase     phase
	probing   bool
	epoch     int
	profile   contract.Profile
	src       *source
	cfg       *startConfig

	muxer    *flv.Muxer
	rebaser  rebase.TimestampRebaser
	watchdog watchdog.MediaWatchdog
	liveness liveness.HeartbeatLiveness
	policy   buffer.Policy

	// 取り込み先と配信キー（準備の応答。メモリにのみ置く）
	ingestURL backend.IngestURL
	key       rtmps.StreamKey
	watchURL  string

	provisioned       bool
	provisioning      bool
	provisionFailures int
	provisionRetryAt  time.Time

	pub               Publisher
	pubSince          time.Time
	dialing           bool
	dialFailures      int
	dialFailuresTotal int
	redialAt          time.Time
	lastOutMs         uint32
	sentBase          uint64

	published         bool // publish_started を伝えた（接続が、確認の窓を過ぎても保たれた）
	confirmSent       bool // status(confirming) を、ブラウザへ送った（復帰の配信は、最初から真）
	failReported      bool // 送出の開始の前の失敗（publish_failed）を、すでに伝えた
	interruptedAt     time.Time
	interruptReported bool
	noSourceSince     time.Time

	hb            heartbeatState
	report        *backend.BrowserReport
	browserEvents []backend.BrowserEvent

	discards map[string]int
	plan     closePlan
}

// NewIngestSession は、取り込みセッションを作る（Start で動かす）。台帳は、照合の結果から作る（Registry）。
// deps の Backend・Events・Publishers・Clock は必須。BroadcastID・AccountKey が空なら ErrInvalidParams。
func NewIngestSession(params Params, deps Deps) (*IngestSession, error) {
	if params.BroadcastID == "" || params.AccountKey == "" {
		return nil, ErrInvalidParams
	}
	normalized, err := deps.normalized()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	now := normalized.Clock.Now()
	s := &IngestSession{
		id:         params.BroadcastID,
		accountKey: params.AccountKey,
		deps:       normalized,
		opts:       normalized.Options,
		log:        normalized.Logger.With(slog.String("broadcast_id", params.BroadcastID)),
		inbox:      make(chan item, normalized.Options.InboxSize),
		wake:       make(chan struct{}, 1),
		closeReq:   make(chan CloseReason, 1),
		abortReq:   make(chan struct{}),
		loopExited: make(chan struct{}),
		done:       make(chan struct{}),
		ctx:        ctx,
		cancel:     cancel,
		t:          now,
		profile:    params.Profile,
		muxer:      flv.NewMuxer(),
		discards:   map[string]int{},
	}
	s.noSourceSince = now
	s.hb = newHeartbeatState(now, s.opts.HeartbeatInterval)
	// 心拍の応答が 60 秒得られない場合の数え始めを、いま決める。アプリケーションが応答した照合の成功が、最初の確認
	if err := s.liveness.Observe(true, now); err != nil {
		cancel()
		return nil, fmt.Errorf("session: %w", err)
	}

	switch params.State {
	case contract.BroadcastStateConfirming, contract.BroadcastStateLive, contract.BroadcastStateInterrupted:
		// 復帰（中継の再起動後など）。アプリケーションは、送出の開始を知っている。キーフレームから再開する
		s.published, s.confirmSent = true, true
		s.phase = phaseInterrupted
		s.interruptedAt = now
		s.interruptReported = true
	default:
		s.phase = phaseIdle
	}
	s.publishState()
	return s, nil
}

// BroadcastID は、配信レコードの識別子。
func (s *IngestSession) BroadcastID() string { return s.id }

// AccountKey は、アカウントを区別する不透明な値。
func (s *IngestSession) AccountKey() string { return s.accountKey }

// Epoch は、現在の送出世代（最初の照合の前は 0）。
func (s *IngestSession) Epoch() int { return int(s.epochValue.Load()) }

// State は、取り込みセッションの状態。
func (s *IngestSession) State() State { return State(s.stateValue.Load()) }

// Done は、取り込みセッションが完全に終わった（ゴルーチン・RTMPS の接続・配信キーが残らない）ときに閉じるチャネル。
func (s *IngestSession) Done() <-chan struct{} { return s.done }

// Start は、イベントループを始める。何度呼んでも、始めるのは 1 回。
func (s *IngestSession) Start() {
	s.startOnce.Do(func() {
		go s.run()
	})
}

// Close は、取り込みセッションを閉じる手順に入れる。呼び出し元をブロックしない（完了は Done）。何度、並行に呼んでもよい。
// 最初の理由で閉じる。ただし、CloseReasonSuperseded・CloseReasonForced は、送り切るのを待っている最中の閉じ方も、
// 直ちに切るものへ切り替える。
func (s *IngestSession) Close(reason CloseReason) {
	s.closing.Store(true)
	if reason == CloseReasonSuperseded || reason == CloseReasonForced {
		s.forceOnce.Do(func() { close(s.abortReq) })
	}
	select {
	case s.closeReq <- reason:
	default: // すでに、閉じる要求がある
	}
}

// SwapSource は、同じ配信の新しい世代の接続へ、送信元を差し替える。古い世代の接続は、直ちに閉じる（fatal(stale_epoch)）。
// 差し替えたら、新しい接続へ accepted を返す。新しい接続の世代が、現在の世代以下なら、その接続のほうを閉じる（古い接続）。
// 取り込みセッションが閉じて（閉じている最中で）いれば ErrSessionClosed。差し替えの処理が済むまで待つ。
func (s *IngestSession) SwapSource(c *Connection, result backend.VerifyResult) error {
	if s.closing.Load() {
		return ErrSessionClosed
	}
	reply := make(chan error, 1)
	if !s.post(func() { reply <- s.swap(c, result) }) {
		return ErrSessionClosed
	}
	select {
	case err := <-reply:
		return err
	case <-s.loopExited:
		select {
		case err := <-reply:
			return err
		default:
			return ErrSessionClosed
		}
	}
}

// submit は、接続から届いた、検証済みのフレームを、ループに渡す。ループが終わっていれば、捨てる。
func (s *IngestSession) submit(c *Connection, f frameMessage) {
	s.post(func() { s.onFrame(c, f) })
}

// sourceClosed は、接続（WebSocket）が閉じたことを、ループに知らせる。
func (s *IngestSession) sourceClosed(c *Connection) {
	s.post(func() {
		if s.src != nil && s.src.conn == c {
			s.sourceLost(s.src)
		}
	})
}

// post は、処理をループの待ち行列に積む。待ち行列が満ちていれば、空くまで待つ（ブラウザの受信に背圧がかかる）。
// ループが終わっていれば、積まずに false。
func (s *IngestSession) post(fn func()) bool {
	select {
	case s.inbox <- item{run: fn}:
		return true
	case <-s.loopExited:
		return false
	}
}

// spawn は、ループとは別のゴルーチンで fn を動かす（アプリケーションの呼び出し・RTMPS の接続・後始末）。結果は、待ち行列に戻す。
// ループが終わるときに、これらの終了を待つ。panic は受けて、記録し、取り込みセッションを閉じる。ループのゴルーチンから呼ぶこと。
// 動いている数（workers）は、「待ち行列に戻る結果を待っているものの数」を表す。
func (s *IngestSession) spawn(name string, fn func()) {
	s.workers.Add(1)
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		defer s.workers.Add(-1)
		defer func() {
			if recovered := recover(); recovered != nil {
				s.log.Error("session worker panicked", slog.String("worker", name), slog.String("panic_type", fmt.Sprintf("%T", recovered)))
				s.post(func() { s.closeWith(planInternalError()) })
			}
		}()
		fn()
	}()
}

// deliver は、別のゴルーチンの結果を、ループに渡す。ループが処理するまで待つ。ループが、処理せずに終わった（積んだ直後に終わった）
// ときは、orphan を呼ぶ（結果に含まれる資源を、残さないため）。
func (s *IngestSession) deliver(run func(), orphan func()) {
	handled := make(chan struct{})
	if !s.post(func() {
		close(handled)
		run()
	}) {
		orphan()
		return
	}
	select {
	case <-handled:
	case <-s.loopExited:
		select {
		case <-handled:
		default:
			orphan()
		}
	}
}

// ---- イベントループ ----

func (s *IngestSession) run() {
	defer s.finish()
	defer func() {
		// イベントループの外側の想定外の panic でも、中継全体を落とさない
		if recovered := recover(); recovered != nil {
			s.log.Error("the session loop panicked and is being closed", slog.String("panic_type", fmt.Sprintf("%T", recovered)))
			s.guarded(func() { s.closeWith(planInternalError()) })
		}
	}()
	s.wakeTimer = s.deps.Clock.AfterFunc(time.Hour, s.signalWake)
	s.wakeTimer.Stop()
	for {
		var publisherClosed <-chan struct{} // Publisher が無い間は nil（選ばれない）
		if s.pub != nil {
			publisherClosed = s.pub.Closed()
		}
		select {
		case it := <-s.inbox:
			s.step(it)
		case <-s.wake:
			s.step(item{})
		case <-publisherClosed:
			s.step(item{})
		case reason := <-s.closeReq:
			s.step(item{run: func() { s.requestClose(reason) }})
		}
		if s.phase == phaseClosed {
			return
		}
		s.schedule()
	}
}

func (s *IngestSession) signalWake() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

// step は、待ち行列の 1 件を処理し、そのあと期限を評価する。処理の中の panic は受けて、取り込みセッションを閉じる。
func (s *IngestSession) step(it item) {
	s.steps.Add(1)
	s.t = s.deps.Clock.Now()
	s.guarded(func() {
		s.checkPublisher()
		if it.run != nil {
			it.run()
		}
		if s.phase != phaseClosed {
			s.processDue()
		}
	})
	if it.sync != nil {
		close(it.sync)
	}
}

// checkPublisher は、Publisher が終わっていれば（切断・書き込みの失敗・送出待ちの上限）、その失敗を処理する。
// 処理のたびに、ほかの処理より先に確かめる（フレームの処理が、終わった Publisher へ書かないように）。
func (s *IngestSession) checkPublisher() {
	pub := s.pub
	if pub == nil {
		return
	}
	select {
	case <-pub.Closed():
		s.onPublisherClosed(pub)
	default:
	}
}

// guarded は、fn の panic を受けて、記録し、取り込みセッションを閉じる（go-rtmp は更新が止まっており、panic が出得る。
// 中継全体を落とさない）。記録は、配信レコードの識別子つきで、panic の種類だけ（値・スタックに、配信キーなどが入り得る）。
func (s *IngestSession) guarded(fn func()) {
	defer func() {
		if recovered := recover(); recovered != nil {
			s.log.Error("session panicked and is being closed", slog.String("panic_type", fmt.Sprintf("%T", recovered)))
			s.closeWith(planInternalError())
		}
	}()
	fn()
}

// schedule は、次に起きる時刻を、タイマーに設定する。期限が無ければ、止める。
func (s *IngestSession) schedule() {
	next, ok := s.nextDeadline()
	if !ok {
		s.wakeTimer.Stop()
		return
	}
	delay := next.Sub(s.deps.Clock.Now())
	if delay < time.Millisecond {
		delay = time.Millisecond
	}
	s.wakeTimer.Reset(delay)
	// 時計を読んでから設定するまでの間に、期限が過ぎていても、取りこぼさない
	if !s.deps.Clock.Now().Before(next) {
		s.signalWake()
	}
}

// nextDeadline は、次に評価すべき時刻のうち、最も早いもの。
func (s *IngestSession) nextDeadline() (time.Time, bool) {
	var best time.Time
	found := false
	consider := func(at time.Time) {
		if at.IsZero() {
			return
		}
		if !found || at.Before(best) {
			best, found = at, true
		}
	}
	consider(s.hb.next)
	consider(s.hb.lastOK.Add(livenessStop))
	if s.src != nil {
		consider(s.src.nextTick)
		if s.src.probeStarted && !s.src.probeDone {
			consider(s.src.probeAt.Add(probeWindow))
		}
	}
	if s.phase == phaseInterrupted {
		consider(s.interruptedAt.Add(s.opts.InterruptionLimit))
	}
	if s.src == nil && !s.noSourceSince.IsZero() {
		consider(s.noSourceSince.Add(s.opts.InterruptionLimit))
	}
	// 再試行の時刻は、実際に動ける間だけ数える（動けないまま、過ぎた時刻を数えると、ループが空回りする）
	if s.canProvision() {
		consider(s.provisionRetryAt)
	}
	if s.canDial() {
		consider(s.redialAt)
	}
	if s.pub != nil && !s.published {
		consider(s.pubSince.Add(s.opts.PublishConfirmWindow))
	}
	return best, found
}

// canProvision は、準備を呼べる状態か（開始通知を受けていて、取り込み先が無く、呼び出しの最中ではない）。
func (s *IngestSession) canProvision() bool {
	return s.src != nil && s.src.started && !s.provisioned && !s.provisioning
}

// canDial は、RTMPS へ接続できる状態か（開始通知を受けていて、取り込み先があり、接続が無く、接続の最中ではない）。
func (s *IngestSession) canDial() bool {
	return s.src != nil && s.src.started && s.provisioned && s.pub == nil && !s.dialing
}

// processDue は、期限の来たものを処理する。時計の読み（s.t）だけに基づく。
func (s *IngestSession) processDue() {
	now := s.t
	if s.liveness.ShouldStop(now) {
		s.closeWith(planHeartbeatLost())
		return
	}
	s.checkProbe(now)
	if s.phase == phaseClosed {
		return
	}
	s.checkWatchdog(now)
	s.checkLimits(now)
	if s.phase == phaseClosed {
		return
	}
	s.reconcile()
	s.tickHeartbeat(now)
	s.tickAck(now)
}

// checkLimits は、中断の安全のための上限（75 秒）を確かめる。期限は、アプリケーションが停止を指示するか、この上限か、早い方。
func (s *IngestSession) checkLimits(now time.Time) {
	limit := s.opts.InterruptionLimit
	switch {
	case s.phase == phaseInterrupted && !now.Before(s.interruptedAt.Add(limit)):
		s.log.Warn("interruption limit passed; closing the session", slog.Duration("limit", limit))
		s.closeWith(planEpisodeExpired())
	case s.src == nil && !s.noSourceSince.IsZero() && !now.Before(s.noSourceSince.Add(limit)):
		s.log.Warn("no browser connection for the interruption limit; closing the session", slog.Duration("limit", limit))
		s.closeWith(planEpisodeExpired())
	}
}

// publishState は、状態を、外から読める値へ反映する。
func (s *IngestSession) publishState() {
	var state State
	switch s.phase {
	case phaseClosed:
		state = StateClosed
	case phaseInterrupted:
		state = StateInterrupted
	case phaseStreaming:
		state = StateStreaming
	case phasePreparing:
		state = StatePreparing
	default:
		state = StateVerified
		if s.probing {
			state = StateProbing
		}
	}
	s.stateValue.Store(int32(state))
}

func (s *IngestSession) setPhase(next phase) {
	s.phase = next
	s.publishState()
}

func (s *IngestSession) setProbing(probing bool) {
	s.probing = probing
	s.publishState()
}

// ---- 事象 ----

// emit は、事象をアプリケーションへの送り先（保持と再送）へ積む。世代が決まる前（照合の前）は、アプリケーションが知らないので積まない。
func (s *IngestSession) emit(kind contract.RelayEventKind, cause contract.InterruptCause) {
	if s.epoch < 1 {
		return
	}
	s.deps.Events.Enqueue(s.id, backend.EventRequest{Epoch: s.epoch, Kind: kind, At: s.deps.Clock.Now(), Cause: cause})
}

// discard は、メッセージを破棄したことを数える。記録は、2 の冪の回だけ、理由つきで（メッセージごとには出さない）。
func (s *IngestSession) discard(reason string) {
	s.discards[reason]++
	count := s.discards[reason]
	if count&(count-1) == 0 {
		s.log.Warn("message discarded", slog.String("reason", reason), slog.Int("count", count))
	}
}

// ---- 整形（機密を出さない） ----

// String は、識別子と状態だけを示す。配信キー・取り込み先を含む構造体を、書式化で出さないため、%v・%+v・%#v も、これを使う。
func (s *IngestSession) String() string {
	return fmt.Sprintf("session.IngestSession{broadcast=%s state=%s}", s.id, s.State())
}

// GoString は、String と同じ。
func (s *IngestSession) GoString() string { return s.String() }

// Format は、どの書式動詞でも、String だけを書く。
func (s *IngestSession) Format(f fmt.State, _ rune) { _, _ = io.WriteString(f, s.String()) }

// backoffFor は、attempt 回目（0 始まり）の失敗のあとの待機。最初の待機を倍々にし、上限で止める。
func backoffFor(attempt int, initial, limit time.Duration) time.Duration {
	wait := initial
	for i := 0; i < attempt; i++ {
		if wait >= limit/postBackoffFactor {
			return limit
		}
		wait *= postBackoffFactor
	}
	return min(wait, limit)
}

// errorClass は、エラーを、決まった語彙の分類にする（ログ用）。エラーの文言は、取り込み先のホスト名・IP アドレス・応答の内容を
// 含み得るので、ログへ出さない。
func errorClass(err error) string {
	switch {
	case err == nil:
		return "none"
	case errors.Is(err, context.Canceled):
		return "canceled"
	case errors.Is(err, ErrDestinationRejected):
		return "destination_rejected"
	case errors.Is(err, rtmps.ErrBufferOverflow):
		return "buffer_overflow"
	case errors.Is(err, rtmps.ErrPublishRejected):
		return "publish_rejected"
	case errors.Is(err, rtmps.ErrDialTimeout):
		return "dial_timeout"
	case errors.Is(err, rtmps.ErrDialFailed):
		return "dial_failed"
	case errors.Is(err, rtmps.ErrDisconnected):
		return "disconnected"
	case errors.Is(err, rtmps.ErrClosed):
		return "closed"
	case errors.Is(err, backend.ErrUnavailable):
		return "unavailable"
	case errors.Is(err, backend.ErrStaleEpoch):
		return "stale_epoch"
	case errors.Is(err, backend.ErrUnauthorized):
		return "unauthorized"
	case errors.Is(err, backend.ErrInvalidResponse):
		return "invalid_response"
	case errors.Is(err, backend.ErrNotFound):
		return "not_found"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	}
	return "error"
}
