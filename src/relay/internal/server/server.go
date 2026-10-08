// Package server は、中継の HTTP ルーター（GET /health・GET /ws）と、中継全体の組み立て・起動・正常停止（App）を担う。
package server

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"runtime"
	"runtime/debug"

	"github.com/gin-gonic/gin"
)

const (
	// HealthPath は、ヘルスチェックのパス。
	HealthPath = "/health"

	// HealthStatusOK は、ヘルスチェックの応答の status の値。
	HealthStatusOK = "ok"

	// WebSocketPath は、ブラウザからの WebSocket の受け口のパス（契約 ws-protocol.md の 1 章）。
	WebSocketPath = "/ws"
)

// NewRouter は、中継のルーターを返す。ws が nil でなければ、GET /ws に割り当てる（WebSocket への切り替えは、ws が行う）。
//
// accessLog にはアクセスログ（クライアントの IP アドレスとクエリ文字列を除く）、
// errorLog にはパニックの記録（リクエストのヘッダとクエリ、パニックの値を除く）を書く。どちらも必須（nil は ErrInvalidDeps。
// 捨てる出力先へ差し替えない。捨ててよい試験は、io.Discard を明示して渡す）。
func NewRouter(accessLog, errorLog io.Writer, ws http.Handler) (*gin.Engine, error) {
	if accessLog == nil || errorLog == nil {
		return nil, fmt.Errorf("%w: the access log and the error log are required", ErrInvalidDeps)
	}
	router := gin.New()
	// 転送ヘッダ（X-Forwarded-For など）を信用しない。利用者の IP アドレスは、この層では扱わない（requirements.md 28.2）
	if err := router.SetTrustedProxies(nil); err != nil {
		return nil, fmt.Errorf("set trusted proxies: %w", err)
	}
	router.Use(
		gin.LoggerWithConfig(gin.LoggerConfig{
			Output:    accessLog,
			Formatter: accessLogFormatter,
			SkipPaths: []string{HealthPath},
		}),
		recoveryMiddleware(log.New(errorLog, "relay: ", log.LstdFlags)),
	)
	router.GET(HealthPath, health)
	if ws != nil {
		router.GET(WebSocketPath, gin.WrapH(ws))
	}
	return router, nil
}

func health(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"status": HealthStatusOK})
}

// recoveryMiddleware は、パニックを回復して 500 を返し、原因の種類とスタックを記録する。
// Gin 既定の Recovery は、リクエストのヘッダ（Cookie など）を含めて記録するため使わない。
// パニックの値は、記録しない（接続チケット・配信キー・取り込み先・エラーの文言が入り得る）。ただし、ランタイムのエラー
// （nil の参照・範囲外の添字・型の変換）は、メッセージが型名と数値だけなので、残す。
// 経路は、クライアントが決める文字列なので、引用符つき（%q）で書く（改行などの制御文字で、記録の行を偽造させない）。
// メソッドは、HTTP サーバーが、トークンの文字だけを通す。
func recoveryMiddleware(logger *log.Logger) gin.HandlerFunc {
	return gin.CustomRecoveryWithWriter(io.Discard, func(c *gin.Context, recovered any) {
		logger.Printf("panic recovered: %s %q: %s\n%s", c.Request.Method, c.Request.URL.Path, describePanic(recovered), debug.Stack())
		c.AbortWithStatus(http.StatusInternalServerError)
	})
}

// describePanic は、パニックの値の説明（型。ランタイムのエラーは、メッセージも）。
func describePanic(recovered any) string {
	if runtimeErr, ok := recovered.(runtime.Error); ok {
		return fmt.Sprintf("%T: %s", recovered, runtimeErr.Error())
	}
	return fmt.Sprintf("%T", recovered)
}
