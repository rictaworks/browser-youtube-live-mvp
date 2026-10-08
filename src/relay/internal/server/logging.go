package server

import (
	"fmt"

	"github.com/gin-gonic/gin"
)

// accessLogFormatter は、アクセスログ 1 行の書式。
// クライアントの IP アドレスと、クエリ文字列（接続チケットなどの秘密を含み得る）を出さない（requirements.md 28.1・28.2）。
//
// 状態は、Gin が見たレスポンスの状態を書く。成功した WebSocket も 200 と記録される：gorilla が 101 の応答を生の接続へ直接書くので、
// Gin から見える状態は既定の 200 のまま。したがって /ws の 200 は「切り替えが確立した」の意味で、切り替えを拒否した要求は、
// 拒否の状態（400・405・503 など）で記録される。行は、ハンドラが戻ったとき（WebSocket なら、接続が終わったとき）に書かれる。
func accessLogFormatter(param gin.LogFormatterParams) string {
	return fmt.Sprintf("%s | %3d | %13v | %-7s %q\n",
		param.TimeStamp.Format("2006/01/02 - 15:04:05"),
		param.StatusCode,
		param.Latency,
		param.Method,
		param.Request.URL.Path,
	)
}
