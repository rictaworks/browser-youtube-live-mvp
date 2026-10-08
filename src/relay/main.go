// 中継（Gin）。ブラウザから WebSocket（GET /ws）で受けたメディアを FLV に詰め替えて、RTMPS で YouTube へ送出する層
// （requirements.md 2.3・11.9・11.10）。再エンコードをしない。状態を永続化しない。
//
// 起動は、環境変数の読み込み（欠けていれば失敗）→ 内部通信・セッション台帳・WebSocket の受け口の結線 → 待ち受け。
// SIGTERM・SIGINT を受けたら、新しい接続を受け付けず、既存のセッションを閉じて（RTMPS は送出待ちを送り切ってから切る）、止まる。
package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"syscall"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/appenv"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/config"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/server"
)

// 終了コード。
const (
	exitOK     = 0
	exitFailed = 1
)

// app は、起動に必要なものをまとめたもの。
type app struct {
	cfg         config.Config
	log         *slog.Logger
	server      *server.App
	restoreLogs func()
}

// newLogger は、中継の記録の出力先（JSON。1 行 1 件）を作る。開発環境は詳細（Debug）まで、それ以外は Info 以上。
// 配信キー・チケット・取り込み先・エラーの文言を、記録へ出さない（各層が守る）。
func newLogger(env appenv.Environment, w io.Writer) *slog.Logger {
	level := slog.LevelInfo
	if env == appenv.Development {
		level = slog.LevelDebug
	}
	return slog.New(slog.NewJSONHandler(w, &slog.HandlerOptions{Level: level}))
}

// newApp は、環境変数（lookup）から設定を読み、中継を結線する。必須の変数が欠けている、値が不正なら、既定の値へ倒さず、エラーにする
// （エラーは、欠けている名前だけを示し、値を含まない）。stdout にはアクセスログ、stderr には記録とパニックの記録を書く
// （どちらも必須。nil は server.ErrInvalidDeps で、捨てる出力先へ差し替えない）。
func newApp(lookup config.LookupFunc, stdout, stderr io.Writer) (*app, error) {
	if stdout == nil || stderr == nil {
		return nil, fmt.Errorf("%w: the standard output and the standard error are required", server.ErrInvalidDeps)
	}
	cfg, err := config.Load(lookup)
	if err != nil {
		return nil, err
	}
	logger := newLogger(cfg.Environment, stderr)
	restore, err := server.RedirectThirdPartyLogs(logger)
	if err != nil {
		return nil, fmt.Errorf("redirect the logs of the libraries: %w", err)
	}
	relay, err := server.NewApp(cfg, server.Deps{Logger: logger, AccessLog: stdout, ErrorLog: stderr})
	if err != nil {
		restore()
		return nil, fmt.Errorf("build the relay: %w", err)
	}
	return &app{cfg: cfg, log: logger, server: relay, restoreLogs: restore}, nil
}

// close は、外部のライブラリの記録の向きを、元に戻す（試験が使う）。
func (a *app) close() { a.restoreLogs() }

// run は、設定のアドレスで待ち受け、ctx が終わるまで動く。
func (a *app) run(ctx context.Context) error {
	listener, err := net.Listen("tcp", a.cfg.ListenAddr)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	return a.serve(ctx, listener)
}

// serve は、listener で待ち受け、ctx が終わるまで動く。ctx が終わったら、停止の手順（猶予時間つき）を行って戻る。
func (a *app) serve(ctx context.Context, listener net.Listener) error {
	a.log.Info("the relay is starting", slog.String("environment", string(a.cfg.Environment)), slog.String("addr", a.cfg.ListenAddr))
	err := a.server.Serve(ctx, listener)
	a.log.Info("the relay stopped")
	return err
}

// run は、プロセスの本体。終了コードを返す。SIGTERM・SIGINT で停止の手順に入り、正常に止まれば 0。
func run(lookup config.LookupFunc, stdout, stderr io.Writer) int {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	// 最初の信号で停止の手順に入る。その間に、もう一度、信号が来たら、既定の動作（直ちに終了）に戻す（運用者が、強制的に止められる）
	go func() {
		<-ctx.Done()
		stop()
	}()

	a, err := newApp(lookup, stdout, stderr)
	if err != nil {
		fmt.Fprintf(stderr, "relay: startup failed: %v\n", err)
		return exitFailed
	}
	defer a.close()
	if err := a.run(ctx); err != nil {
		fmt.Fprintf(stderr, "relay: stopped with an error: %v\n", err)
		return exitFailed
	}
	return exitOK
}

func main() {
	os.Exit(run(os.LookupEnv, os.Stdout, os.Stderr))
}
