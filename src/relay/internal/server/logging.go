package server

import (
	"fmt"

	"github.com/gin-gonic/gin"
)

// accessLogFormatter は、アクセスログ 1 行の書式。
// クライアントの IP アドレスと、クエリ文字列（接続チケットなどの秘密を含み得る）を出さない（requirements.md 28.1・28.2）。
func accessLogFormatter(param gin.LogFormatterParams) string {
	return fmt.Sprintf("%s | %3d | %13v | %-7s %q\n",
		param.TimeStamp.Format("2006/01/02 - 15:04:05"),
		param.StatusCode,
		param.Latency,
		param.Method,
		param.Request.URL.Path,
	)
}
