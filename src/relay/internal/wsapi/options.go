package wsapi

import (
	"fmt"
	"log/slog"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/session"
)

// 既定値。1 メッセージの大きさの上限は契約（limits.json の ws_frame.max_message_bytes）の値。それ以外は、契約に定めが無く、
// 中継の資源（ゴルーチン・メモリ）を守るために置いた解釈（欄の説明に理由を書く）。
const (
	// DefaultMaxConnections は、同時に受け付ける WebSocket の接続数の上限。実際の配信は、同時配信数の上限（既定 3）に
	// 復帰の重なりを足した程度。上限は、チケットを持たない接続（接続通知の期限 10 秒まで居座れる）が、中継の資源を使い切ることを防ぐ。
	// 照合の前の接続も、1 メッセージを 2 MiB まで読む。読み取りの緩衝は、受け取った量に比例して倍々に増やす（read.go）ので、
	// 1 本が使うメモリは、読んだ量に応じて増え、最後の拡張で最大になる：古い緩衝（1 MiB）と新しい緩衝（2 MiB + 1 バイト）が
	// 同時に生きる、約 3 MiB。64 本が同時に最後の拡張へ進んだ最悪は、生きている緩衝の合計で約 192 MiB。古い緩衝は、回収（GC）される
	// まで残るので、実際の使用量はこれを上回り得る。この見積もりは接続数に比例する（上限を上げるときは、取り直す）。
	DefaultMaxConnections = 64
	// DefaultSendQueueLimit は、ブラウザへの送信待ち（重要なメッセージ）の上限。ブラウザへ送るのは、接続受理・計測結果・
	// キーフレーム要求・状態通知・致命通知で、どれも小さく、まれ。これを超えるのは、ブラウザが読んでいないとき。
	DefaultSendQueueLimit = 64
	// DefaultPingInterval は、ping を送る間隔。
	DefaultPingInterval = 5 * time.Second
	// DefaultIdleTimeout は、相手から何も（データも pong も）届かない時間の上限。ping の間隔の 3 倍。
	DefaultIdleTimeout = 15 * time.Second
	// DefaultWriteTimeout は、1 回の書き込みの期限。読まない（止まった）相手への書き込みで、書き込み役が居座ることを防ぐ。
	DefaultWriteTimeout = 10 * time.Second
	// DefaultLingerTimeout は、Close フレームを送ったあと、相手が接続を閉じるのを待つ上限。
	DefaultLingerTimeout = 3 * time.Second
	// DefaultHandshakeTimeout は、WebSocket への切り替えの応答を書く期限。
	DefaultHandshakeTimeout = 10 * time.Second

	// bufferBytes は、読み取り・書き込みの緩衝の大きさ（バイト）。中継がブラウザへ送るのは小さな制御メッセージだけ。
	bufferBytes = 4096
)

// Options は、WebSocket の受け口の設定。ゼロの欄は既定値。負の値・契約を超える値・矛盾は ErrInvalidOptions。
type Options struct {
	// Clock は、時計（必須）。ping・無通信の監視・書き込みの期限・切断の待ちは、すべてここから取る（実時間を直接使わない）。
	Clock session.Clock
	// Logger は、異常の記録の出力先（必須）。nil は ErrInvalidDeps で、捨てる出力先へ黙って差し替えない（記録が消えて、異常に
	// 気づけなくなる）。記録が要らない試験は、捨てる出力先（slog.DiscardHandler）を明示して渡す。
	// 配信キー・チケット・取り込み先・エラーの文言を出さない。
	Logger *slog.Logger
	// MaxMessageBytes は、1 メッセージ（ヘッダ + 本文）の上限（ws_frame.max_message_bytes）。契約より大きくできない。
	MaxMessageBytes int
	// MaxConnections は、同時に受け付ける接続数の上限。
	MaxConnections int
	// SendQueueLimit は、重要なメッセージの送信待ちの上限。受領応答と抑制指示は、最新の 1 つだけを保つので、数えない。
	SendQueueLimit int
	// PingInterval は、ping の間隔。
	PingInterval time.Duration
	// IdleTimeout は、相手から何も届かない時間の上限。PingInterval より長くする。
	IdleTimeout time.Duration
	// WriteTimeout は、1 回の書き込みの期限。
	WriteTimeout time.Duration
	// LingerTimeout は、Close フレームを送ったあと、相手が閉じるのを待つ上限。
	LingerTimeout time.Duration
	// HandshakeTimeout は、WebSocket への切り替えの応答を書く期限。
	HandshakeTimeout time.Duration
}

// normalized は、ゼロの欄を既定値にして、検査する。時計かロガーが無ければ ErrInvalidDeps（どちらも、既定値で補わない）。
func (o Options) normalized() (Options, error) {
	if o.Clock == nil {
		return Options{}, fmt.Errorf("%w: the clock is required", ErrInvalidDeps)
	}
	if o.Logger == nil {
		return Options{}, fmt.Errorf("%w: the logger is required", ErrInvalidDeps)
	}
	counts := []struct {
		name     string
		value    *int
		fallback int
	}{
		{"MaxMessageBytes", &o.MaxMessageBytes, contract.WSFrameMaxMessageBytes},
		{"MaxConnections", &o.MaxConnections, DefaultMaxConnections},
		{"SendQueueLimit", &o.SendQueueLimit, DefaultSendQueueLimit},
	}
	for _, field := range counts {
		switch {
		case *field.value < 0:
			return Options{}, fmt.Errorf("%w: %s is negative", ErrInvalidOptions, field.name)
		case *field.value == 0:
			*field.value = field.fallback
		}
	}
	durations := []struct {
		name     string
		value    *time.Duration
		fallback time.Duration
	}{
		{"PingInterval", &o.PingInterval, DefaultPingInterval},
		{"IdleTimeout", &o.IdleTimeout, DefaultIdleTimeout},
		{"WriteTimeout", &o.WriteTimeout, DefaultWriteTimeout},
		{"LingerTimeout", &o.LingerTimeout, DefaultLingerTimeout},
		{"HandshakeTimeout", &o.HandshakeTimeout, DefaultHandshakeTimeout},
	}
	for _, field := range durations {
		switch {
		case *field.value < 0:
			return Options{}, fmt.Errorf("%w: %s is negative", ErrInvalidOptions, field.name)
		case *field.value == 0:
			*field.value = field.fallback
		}
	}
	if o.MaxMessageBytes > contract.WSFrameMaxMessageBytes {
		return Options{}, fmt.Errorf("%w: MaxMessageBytes exceeds the contract limit", ErrInvalidOptions)
	}
	if o.MaxMessageBytes < contract.WSFrameHeaderBytes {
		return Options{}, fmt.Errorf("%w: MaxMessageBytes is smaller than a frame header", ErrInvalidOptions)
	}
	if o.IdleTimeout <= o.PingInterval {
		return Options{}, fmt.Errorf("%w: IdleTimeout must be longer than PingInterval", ErrInvalidOptions)
	}
	return o, nil
}
