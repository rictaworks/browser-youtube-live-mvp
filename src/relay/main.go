// 中継（Gin）。WebSocket で受けたメディアを FLV に詰め替えて RTMPS で送出する層（requirements.md 2.3・11.10）。
// 現時点は、環境の判定とヘルスチェック（GET /health）だけを持つ雛形である。
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/gin-gonic/gin"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/appenv"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/config"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/server"
)

// app は、起動に必要なものをまとめたもの。
type app struct {
	env     appenv.Environment
	addr    string
	handler http.Handler
}

// newApp は、環境変数（lookup）から環境と待ち受けのアドレスを決め、ルーターを組み立てる。
// GIN_MODE・PORT が不正なら、既定の値へ倒さず、エラーにする。
func newApp(lookup config.LookupFunc) (*app, error) {
	mode, _ := lookup(gin.EnvGinMode)
	env, err := appenv.FromGinMode(mode)
	if err != nil {
		return nil, fmt.Errorf("detect environment: %w", err)
	}
	addr, err := config.ListenAddress(lookup)
	if err != nil {
		return nil, fmt.Errorf("resolve listen address: %w", err)
	}
	router, err := server.NewRouter(os.Stdout, os.Stderr)
	if err != nil {
		return nil, fmt.Errorf("build router: %w", err)
	}
	return &app{env: env, addr: addr, handler: router}, nil
}

func (a *app) run() error {
	srv := &http.Server{
		Addr:              a.addr,
		Handler:           a.handler,
		ReadHeaderTimeout: config.ReadHeaderTimeout,
	}
	log.Printf("relay: starting environment=%s addr=%s", a.env, a.addr)
	return srv.ListenAndServe()
}

func main() {
	a, err := newApp(os.LookupEnv)
	if err != nil {
		log.Fatalf("relay: startup failed: %v", err)
	}
	if err := a.run(); err != nil {
		log.Fatalf("relay: server stopped: %v", err)
	}
}
