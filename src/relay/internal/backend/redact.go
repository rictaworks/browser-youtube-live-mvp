package backend

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
)

// 機密の値の型。ログ・エラー・%v・JSON のどこにも、中身を出さない（requirements.md 6.1・28.1。契約 internal-api.md の 1 章「機密」）。
// 種類（共有の秘密値・接続チケット・取り込み先）ごとに、伏せた表示だけが違う。

// label は、伏せた値の表示（種類ごと）。
type label interface{ text() string }

type secretLabel struct{}

func (secretLabel) text() string { return "[redacted secret]" }

type ticketLabel struct{}

func (ticketLabel) text() string { return "[redacted ticket]" }

type ingestURLLabel struct{}

func (ingestURLLabel) text() string { return "[redacted ingest url]" }

// sensitive は、伏せる文字列。String・GoString・Format（%v・%+v・%#v・%s・%q・%x・%d のすべて）・MarshalText・MarshalJSON・
// LogValue（log/slog）のどれでも、伏せた文字列だけを返す。JSON からの読み込みは、そのまま可能（準備の応答を、型へ読み込める）。
// 中身が要るのは、このパッケージの reveal だけ（HTTP のヘッダと要求の本文に 1 か所ずつ）。
type sensitive[L label] string

// String は、伏せた文字列を返す。
func (s sensitive[L]) String() string {
	var l L
	return l.text()
}

// GoString は、伏せた文字列を返す（%#v）。
func (s sensitive[L]) GoString() string { return s.String() }

// Format は、どの書式動詞でも、伏せた文字列だけを書く。
func (s sensitive[L]) Format(f fmt.State, _ rune) {
	_, _ = io.WriteString(f, s.String())
}

// MarshalText は、伏せた文字列を返す。
func (s sensitive[L]) MarshalText() ([]byte, error) { return []byte(s.String()), nil }

// MarshalJSON は、伏せた文字列の JSON を返す。
func (s sensitive[L]) MarshalJSON() ([]byte, error) { return json.Marshal(s.String()) }

// LogValue は、log/slog へ、伏せた値を渡す。
func (s sensitive[L]) LogValue() slog.Value { return slog.StringValue(s.String()) }

// reveal は、中身を返す（このパッケージの内部だけ）。
func (s sensitive[L]) reveal() string { return string(s) }

// Secret は、共有の秘密値（RELAY_SHARED_SECRET）。ヘッダ X-Relay-Secret に載せる。
type Secret = sensitive[secretLabel]

// Ticket は、接続チケット（1 回限り・60 秒で失効）。照合の要求の本文に載せる。
type Ticket = sensitive[ticketLabel]

// IngestURL は、取り込み先（RTMPS の URL。配信キーを含まない）。ログ・エラーへ出さない。
type IngestURL = sensitive[ingestURLLabel]
