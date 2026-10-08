package wsapi

import (
	"io"
	"time"

	"github.com/gorilla/websocket"
)

// socket は、WebSocket の接続 1 本の操作。本番は gorilla/websocket の接続（gorillaSocket）。試験は疑似の実装を使う。
//
// gorilla/websocket の規則（読み取りは 1 つのゴルーチン、書き込みは 1 つのゴルーチン。Close と WriteControl は、どのゴルーチンからも
// 呼べる）に従う。読み取りは受信のゴルーチン（Handler の読み取りの繰り返し）だけが、WriteMessage は書き込み役（link）だけが呼ぶ。
type socket interface {
	// NextReader は、次のメッセージを返す。メッセージの種類は websocket.TextMessage・websocket.BinaryMessage。
	// 前のメッセージを読み切っていなければ、残りを読み捨てる。Close フレームを受けたら *websocket.CloseError。
	NextReader() (messageType int, r io.Reader, err error)
	// WriteMessage は、1 メッセージを書く。
	WriteMessage(messageType int, data []byte) error
	// WriteControl は、制御フレーム（ping・pong・Close）を書く。deadline が零値なら、期限なし（期限は link の書き込みの見張りが持つ）。
	WriteControl(messageType int, data []byte, deadline time.Time) error
	// CloseWrite は、書き込み側だけを閉じる（TCP の FIN）。できない接続（TLS を終端していないなど）では、何もしない。
	CloseWrite() error
	// Close は、基になる接続を閉じる（Close フレームは送らない）。止まっている読み書きも、エラーで戻る。何度呼んでもよい。
	Close() error
}

// gorillaSocket は、*websocket.Conn を socket にしたもの。
type gorillaSocket struct {
	*websocket.Conn
}

// CloseWrite は、基になる接続が書き込み側だけを閉じられるなら（*net.TCPConn など）閉じる。
func (s gorillaSocket) CloseWrite() error {
	if closer, ok := s.NetConn().(interface{ CloseWrite() error }); ok {
		return closer.CloseWrite()
	}
	return nil
}
