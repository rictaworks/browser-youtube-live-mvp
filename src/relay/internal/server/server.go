// Package server は、中継の HTTP ルーターを組み立てる。
package server

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"runtime/debug"

	"github.com/gin-gonic/gin"
)

const (
	// HealthPath は、ヘルスチェックのパス。
	HealthPath = "/health"

	// HealthStatusOK は、ヘルスチェックの応答の status の値。
	HealthStatusOK = "ok"
)

// NewRouter は、中継のルーターを返す。
//
// accessLog にはアクセスログ（クライアントの IP アドレスとクエリ文字列を除く）、
// errorLog にはパニックの記録（リクエストのヘッダとクエリを除く）を書く。
func NewRouter(accessLog, errorLog io.Writer) (*gin.Engine, error) {
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
	return router, nil
}

func health(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"status": HealthStatusOK})
}

// recoveryMiddleware は、パニックを回復して 500 を返し、原因とスタックを記録する。
// Gin 既定の Recovery は、リクエストのヘッダ（Cookie など）を含めて記録するため使わない。
func recoveryMiddleware(logger *log.Logger) gin.HandlerFunc {
	return gin.CustomRecoveryWithWriter(io.Discard, func(c *gin.Context, recovered any) {
		logger.Printf("panic recovered: %s %s: %v\n%s", c.Request.Method, c.Request.URL.Path, recovered, debug.Stack())
		c.AbortWithStatus(http.StatusInternalServerError)
	})
}
