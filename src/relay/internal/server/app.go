package server

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/appenv"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/config"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/session"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/wsapi"
)

const (
	// DefaultGrace は、停止の猶予時間。RTMPS の送出待ちを送り切る時間（通常は一瞬。最悪は約 17 秒）と、事象の送り切りを含む。
	// 超えたら、送り切るのを待たずに中止する（Close を Abort に格上げする）。
	DefaultGrace = 10 * time.Second
	// DefaultFlushReserve は、停止の猶予のうち、事象（取り込みセッションの終了 session_ended など）をアプリケーションへ送り切るために
	// 残す時間。取り込みセッションを閉じる手順は、猶予からこの時間を引いた期限まで（それを過ぎたら強制）。
	DefaultFlushReserve = 2 * time.Second
)

// Deps は、App の依存。記録の出力先（Logger・AccessLog・ErrorLog）は必須。それ以外のゼロの欄は、本番の実装か、既定値。
// 試験が差し替える（時計・待機・送出先の許可・TLS の信頼）。
type Deps struct {
	// Logger は、異常の記録の出力先（必須）。nil は ErrInvalidDeps。捨てる出力先へ黙って差し替えない（記録が消えて、異常に
	// 気づけなくなる）。記録が要らない試験は、捨てる出力先（slog.DiscardHandler）を明示して渡す。
	Logger *slog.Logger
	// AccessLog・ErrorLog は、アクセスログとパニックの記録の出力先（必須）。nil は ErrInvalidDeps。同じく、記録が要らない試験は、
	// 捨てる出力先（io.Discard）を明示して渡す。
	AccessLog io.Writer
	ErrorLog  io.Writer
	// Clock は、時計（取り込みセッション・WebSocket の受け口のタイマー）。nil なら、実時間。
	Clock session.Clock
	// Waiter は、事象の再送の待機。nil なら、実時間。
	Waiter backend.Waiter
	// HTTPClient は、内部通信の HTTP クライアント。nil なら、backend の既定（環境のプロキシを使わない）。
	HTTPClient *http.Client
	// Timeouts・Queue・Session・WebSocket は、各層の設定（ゼロの欄は既定値）。WebSocket の Clock・Logger は、App が決める。
	Timeouts  backend.Timeouts
	Queue     backend.QueueOptions
	Session   session.Options
	WebSocket wsapi.Options
	// RTMPS は、RTMPS の接続の設定（試験が、自己署名の証明書を信頼するために RootCAs を渡す）。
	RTMPS rtmps.Config
	// Policy は、送出先の許可リストを差し替える（試験だけ。nil なら、環境から決める）。production では ErrPolicyOverrideInProduction。
	Policy *rtmps.Policy
	// Grace・FlushReserve は、停止の猶予時間と、事象を送り切るために残す時間。ゼロなら、既定値。
	Grace        time.Duration
	FlushReserve time.Duration
}

// App は、中継の全体（HTTP ルーター・WebSocket の受け口・セッション台帳・内部通信）の組み立てと、起動・正常停止。
//
// 起動は Serve（待ち受けを始め、ctx が終わったら停止の手順に入る）。停止の手順（Shutdown）は、次の順で行う：
//  1. 新しい接続を受け付けない（WebSocket の受け口は 503。HTTP の待ち受けを閉じる）
//  2. すべての取り込みセッションを閉じる（RTMPS は、送出待ちを送り切ってから切る。猶予を過ぎたら、破棄して直ちに切る）。
//     ブラウザには致命通知 internal_error（復帰を試みる）を送る
//  3. WebSocket の接続の処理が終わるのを待つ（残っていれば、直ちに落とす）
//  4. 事象（取り込みセッションの終了 session_ended など）を、アプリケーションへ送り切る
//  5. 内部通信の接続を閉じる
//
// 戻ったときには、ゴルーチンは残らない。
type App struct {
	cfg          config.Config
	log          *slog.Logger
	router       http.Handler
	client       *backend.Client
	events       *backend.EventQueue
	registry     *session.Registry
	ws           *wsapi.Handler
	grace        time.Duration
	flushReserve time.Duration

	mu     sync.Mutex
	server *http.Server
}

// NewApp は、中継を組み立てる。記録の出力先（Logger・AccessLog・ErrorLog）が無ければ ErrInvalidDeps（差し替えない）。
// 設定が不正なら（内部通信の接続先・秘密値・送出先の許可）、エラー。エラーは、接続先・秘密値の内容を含まない。
// ゴルーチンは、まだ始めない。
func NewApp(cfg config.Config, deps Deps) (*App, error) {
	if deps.Logger == nil || deps.AccessLog == nil || deps.ErrorLog == nil {
		return nil, fmt.Errorf("%w: the logger, the access log and the error log are required", ErrInvalidDeps)
	}
	logger, accessLog, errorLog := deps.Logger, deps.AccessLog, deps.ErrorLog
	clock := deps.Clock
	if clock == nil {
		clock = session.SystemClock{}
	}
	waiter := deps.Waiter
	if waiter == nil {
		waiter = backend.SystemWaiter{}
	}
	grace, flushReserve := deps.Grace, deps.FlushReserve
	if grace == 0 {
		grace = DefaultGrace
	}
	if flushReserve == 0 {
		flushReserve = DefaultFlushReserve
	}
	if grace < 0 || flushReserve < 0 {
		return nil, errors.New("server: the grace period and the flush reserve must not be negative")
	}

	policy, err := DestinationPolicy(cfg.Environment, deps.Policy)
	if err != nil {
		return nil, err
	}
	client, err := backend.NewClient(backend.Config{
		BaseURL: cfg.BackendInternalURL, Secret: cfg.SharedSecret, HTTPClient: deps.HTTPClient, Timeouts: deps.Timeouts,
	})
	if err != nil {
		return nil, fmt.Errorf("build the internal communication client: %w", err)
	}
	events, err := backend.NewEventQueue(client, waiter, deps.Queue, logger)
	if err != nil {
		return nil, fmt.Errorf("build the event queue: %w", err)
	}
	registry, err := session.NewRegistry(session.Deps{
		Backend:    client,
		Events:     events,
		Publishers: session.NewRTMPSFactory(policy, deps.RTMPS),
		Clock:      clock,
		Logger:     logger,
		Options:    deps.Session,
	})
	if err != nil {
		return nil, fmt.Errorf("build the session registry: %w", err)
	}
	wsOptions := deps.WebSocket
	wsOptions.Clock, wsOptions.Logger = clock, logger
	ws, err := wsapi.NewHandler(wsapi.RegistryAcceptor(registry), wsOptions)
	if err != nil {
		return nil, fmt.Errorf("build the WebSocket handler: %w", err)
	}
	router, err := NewRouter(accessLog, errorLog, ws)
	if err != nil {
		return nil, fmt.Errorf("build the router: %w", err)
	}
	return &App{
		cfg: cfg, log: logger, router: router, client: client, events: events, registry: registry, ws: ws,
		grace: grace, flushReserve: flushReserve,
	}, nil
}

// DestinationPolicy は、RTMPS の送出先の許可リストを返す。環境から決める（production は YouTube の取り込み口だけ。開発・試験の環境は、
// それに加えて疑似の取り込み口）。override は、試験が差し替えるためのもので、production では ErrPolicyOverrideInProduction。
// 未知の環境は、エラー（別の環境へ倒さない）。
func DestinationPolicy(env appenv.Environment, override *rtmps.Policy) (rtmps.Policy, error) {
	policy, err := rtmps.PolicyFor(env)
	if err != nil {
		return rtmps.Policy{}, fmt.Errorf("resolve the destination policy: %w", err)
	}
	if override == nil {
		return policy, nil
	}
	if env == appenv.Production {
		return rtmps.Policy{}, ErrPolicyOverrideInProduction
	}
	return *override, nil
}

// Handler は、HTTP のハンドラ（GET /health・GET /ws）。
func (a *App) Handler() http.Handler { return a.router }

// Registry は、セッション台帳（診断と試験のため）。
func (a *App) Registry() *session.Registry { return a.registry }

// WebSocket は、WebSocket の受け口（診断と試験のため）。
func (a *App) WebSocket() *wsapi.Handler { return a.ws }

// Serve は、listener で待ち受け、ctx が終わるまで動く。ctx が終わったら、停止の手順（猶予 Grace）に入り、戻る。
// 要求された停止なら nil。待ち受けが自分で止まった（listener の失敗など）ときは、後始末をして、そのエラー。
// 1 つの App につき、1 回だけ呼ぶ。
func (a *App) Serve(ctx context.Context, listener net.Listener) error {
	srv := &http.Server{
		Handler:           a.router,
		ReadHeaderTimeout: config.ReadHeaderTimeout,
		IdleTimeout:       config.IdleTimeout,
		MaxHeaderBytes:    config.MaxHeaderBytes,
	}
	a.mu.Lock()
	a.server = srv
	a.mu.Unlock()

	serveErr := make(chan error, 1)
	go func() { serveErr <- srv.Serve(listener) }()

	select {
	case err := <-serveErr:
		stopCtx, cancel := context.WithTimeout(context.Background(), a.grace)
		defer cancel()
		shutdownErr := a.Shutdown(stopCtx)
		if errors.Is(err, http.ErrServerClosed) {
			return shutdownErr
		}
		return errors.Join(fmt.Errorf("serve: %w", err), shutdownErr)
	case <-ctx.Done():
	}
	stopCtx, cancel := context.WithTimeout(context.Background(), a.grace)
	defer cancel()
	shutdownErr := a.Shutdown(stopCtx)
	<-serveErr
	return shutdownErr
}

// Shutdown は、停止の手順（App の説明を参照）。ctx の期限が猶予時間。期限を過ぎたら、送り切るのを待たずに中止して、ctx のエラーを
// 含むエラーを返す。何度呼んでもよい。
func (a *App) Shutdown(ctx context.Context) error {
	a.ws.BeginDrain()

	// HTTP の待ち受けは、並行に閉じる（待ち受けは、すぐに閉じる。処理中の要求の完了待ちが、取り込みセッションを閉じる手順を遅らせない）
	httpDone := make(chan error, 1)
	if srv := a.httpServer(); srv != nil {
		go func() { httpDone <- srv.Shutdown(ctx) }()
	} else {
		httpDone <- nil
	}

	var errs []error
	sessionsCtx, release := sessionsContext(ctx, a.flushReserve)
	errs = append(errs, labeled("close the ingest sessions", a.registry.Shutdown(sessionsCtx)))
	release()
	errs = append(errs, labeled("wait for the WebSocket connections", a.ws.Wait(ctx)))
	errs = append(errs, labeled("flush the events", a.events.Shutdown(ctx)))
	a.client.CloseIdleConnections()
	errs = append(errs, labeled("stop the HTTP listener", <-httpDone))
	return errors.Join(errs...)
}

func (a *App) httpServer() *http.Server {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.server
}

// sessionsContext は、取り込みセッションを閉じる手順の期限を返す。親の期限から reserve だけ早める（そのあとの、事象を送り切る
// ための時間を残す）。ただし、残りの時間の半分までに留める（猶予が短いときに、取り込みセッションを閉じる時間が無くならないように）。
// 親に期限が無ければ、親が終わるときに終わる。
func sessionsContext(parent context.Context, reserve time.Duration) (context.Context, context.CancelFunc) {
	deadline, ok := parent.Deadline()
	if !ok {
		return context.WithCancel(parent)
	}
	if remaining := time.Until(deadline); reserve > remaining/2 {
		reserve = max(remaining/2, 0)
	}
	return context.WithDeadline(parent, deadline.Add(-reserve))
}

// labeled は、エラーに、停止の手順の名前を付ける。nil は nil のまま。
func labeled(step string, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("%s: %w", step, err)
}

// String は、環境だけを示す（接続先・秘密値・アドレスを含めない）。
func (a *App) String() string {
	return fmt.Sprintf("server.App{environment=%s}", a.cfg.Environment)
}

// GoString は、String と同じ。
func (a *App) GoString() string { return a.String() }

// Format は、どの書式動詞でも、String だけを書く。
func (a *App) Format(f fmt.State, _ rune) { _, _ = io.WriteString(f, a.String()) }
