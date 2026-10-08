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
			// 倍にすると上限に届く（上限以上になる）最後の拡張は、上限 + 1 バイトへ一気に増やす（上限 + 1 バイトを読んだ時点で
			// 打ち切るので、それ以上は要らない）。上限が 2 MiB なら、1 MiB の次が 2 MiB + 1 バイト。倍々のまま進めると、
			// 2 MiB の段を挟んで、最後の拡張で「古い 2 MiB と新しい 2 MiB + 1 バイト」が同時に生きる（約 4 MiB）。
			// 一気に増やせば、「古い 1 MiB と新しい 2 MiB + 1 バイト」の約 3 MiB で済む。
			next := 2 * cap(buffer)
			if next >= limit {
				next = limit + 1
			}
			grown := make([]byte, len(buffer), next)
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
