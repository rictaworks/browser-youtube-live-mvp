package wsapi

import (
	"errors"
	"io"
)

// initialReadBytes は、1 メッセージを読む緩衝の最初の大きさ。実際に届いた量に応じて倍々に増やす（宣言された大きさに比例して
// 確保しない。ヘッダで 2 MiB を宣言しただけで止まる接続が、接続ごとに 2 MiB を確保させることを防ぐ）。
const initialReadBytes = 4096

// readMessage は、1 メッセージの本文を、limit バイトまで読む。limit を超えると分かった時点（limit + 1 バイトを読んだ時点）で
// 読むのをやめ、oversize を返す（残りは読まない。呼び出し側が、致命通知のうえ切断する。ws-protocol.md の 4.1）。
// 返したバイト列は、新しい領域（呼び出し側のものになる）。読み取りの失敗は、そのまま返す（データは返さない）。
func readMessage(r io.Reader, limit int) (data []byte, oversize bool, err error) {
	buffer := make([]byte, 0, min(initialReadBytes, limit+1))
	for {
		if len(buffer) == cap(buffer) {
			grown := make([]byte, len(buffer), min(2*cap(buffer), limit+1))
			copy(grown, buffer)
			buffer = grown
		}
		n, readErr := r.Read(buffer[len(buffer):cap(buffer)])
		buffer = buffer[:len(buffer)+n]
		if len(buffer) > limit {
			return nil, true, nil
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				return buffer, false, nil
			}
			return nil, false, readErr
		}
	}
}
