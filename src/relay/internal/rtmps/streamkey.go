package rtmps

import (
	"fmt"
	"io"
	"log/slog"
)

const (
	// maxStreamKeyBytes は、配信キーの長さの上限（バイト）。YouTube の配信キーは 24 文字ほど。
	maxStreamKeyBytes = 256

	redactedStreamKey = "[redacted stream key]"
)

// StreamKey は、配信キー（RTMP の publish で使う名前）。URL とは別に受け取る（requirements.md 10.1・28.1）。
//
// 配信キーは、DB・ログ・ブラウザ・測定イベント・管理画面へ出さない。メモリにのみ置く。そのため、この型は、
// String・GoString・Format（%v・%+v・%#v・%s・%q・%x・%d のすべて）・MarshalText・MarshalJSON・LogValue（log/slog）の
// どれでも、伏せた文字列だけを返す。JSON からの読み込みは、そのまま可能（内部通信の準備の応答を、型へ読み込める）。
// 中身が要るのは、このパッケージの reveal だけ（Dial が、publish の呼び出しで 1 回使う）。Publisher は、配信キーを保持しない。
//
// 限界：Go は文字列を消去できない。非公開のフィールドとして保持する構造体を、リフレクションで書式化すると、中身が出る
// （fmt は、非公開のフィールドのメソッドを呼ばない）。配信キーを、構造体のフィールドへ置かない。
type StreamKey string

// Validate は、配信キーを検査する（1 から maxStreamKeyBytes バイトの、空白・制御文字・非 ASCII を含まない文字列）。
// 不正なら ErrInvalidStreamKey。エラーは、配信キーの内容（一部も、不正な文字の値も）を含まない。
func (k StreamKey) Validate() error {
	if len(k) == 0 {
		return fmt.Errorf("%w: empty", ErrInvalidStreamKey)
	}
	if len(k) > maxStreamKeyBytes {
		return fmt.Errorf("%w: %d bytes (want at most %d)", ErrInvalidStreamKey, len(k), maxStreamKeyBytes)
	}
	for i := 0; i < len(k); i++ {
		if k[i] < firstPrintable || k[i] > lastPrintable {
			return fmt.Errorf("%w: unexpected character at position %d", ErrInvalidStreamKey, i)
		}
	}
	return nil
}

// String は、伏せた文字列を返す。
func (k StreamKey) String() string { return redactedStreamKey }

// GoString は、伏せた文字列を返す（%#v）。
func (k StreamKey) GoString() string { return redactedStreamKey }

// Format は、どの書式動詞でも、伏せた文字列だけを書く。
func (k StreamKey) Format(f fmt.State, _ rune) {
	_, _ = io.WriteString(f, redactedStreamKey)
}

// MarshalText は、伏せた文字列を返す。
func (k StreamKey) MarshalText() ([]byte, error) { return []byte(redactedStreamKey), nil }

// MarshalJSON は、伏せた文字列の JSON を返す。
func (k StreamKey) MarshalJSON() ([]byte, error) {
	return []byte(`"` + redactedStreamKey + `"`), nil
}

// LogValue は、log/slog へ、伏せた値を渡す。
func (k StreamKey) LogValue() slog.Value { return slog.StringValue(redactedStreamKey) }

// reveal は、配信キーの中身を返す（このパッケージの内部だけ。publish の呼び出しに使う）。
func (k StreamKey) reveal() string { return string(k) }
