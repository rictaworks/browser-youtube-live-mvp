package rtmps

import (
	"crypto/x509"
	"fmt"
	"log/slog"
	"time"
)

// 既定値。ゼロ値の Config は、これらを使う。
const (
	// DefaultDialTimeout は、接続全体（TCP・TLS・RTMP のハンドシェイク・connect・createStream・publish）の期限。
	// 中継の中断の期限（30 秒。13.2）より十分に短い。go-rtmp にはハンドシェイクのタイムアウトが無いため、この期限で接続を閉じる。
	DefaultDialTimeout = 10 * time.Second
	// DefaultCloseTimeout は、Close が、送出待ちを送り切るのを待つ期限。送出待ちは 3 秒分が上限なので、回線が健全なら、ごく短い。
	// 期限が来たら、強制的に切る（停止の経路は、有限の時間で終わる。27 章の終端性）。
	DefaultCloseTimeout = 5 * time.Second
	// DefaultCloseLinger は、送り切ったあとの Close が、接続をおだやかに閉じるとき（FIN を送ったあと）、相手が閉じるのを待つ上限。
	// 相手が閉じたことは、送ったものを、相手がすべて受け取ったことの証明になる（RST で、配信の最後の部分が捨てられない）。
	DefaultCloseLinger = 2 * time.Second
	// DefaultTeardownTimeout は、接続の後始末（切断・ゴルーチンの終了）を待つ期限（受け口が閉じるのを待つ CloseLinger を除く）。
	// go-rtmp の Close は、書き込み中のものを最大 3 秒待ち、TLS の close_notify の書き込みに最大 5 秒かかり得る。
	// 強制の切断のあとは、ごく短い。Close・Abort が待つのは、この期限と CloseLinger の合計まで。
	DefaultTeardownTimeout = 10 * time.Second
	// DefaultPollInterval は、接続が切れていないかを見張る間隔。go-rtmp は、切断を通知する手段を持たない（LastError の参照だけ）。
	DefaultPollInterval = 100 * time.Millisecond
	// DefaultPublishRejectWindow は、publish を送ってから、この間に接続が切れたら、配信キーの不正・使用中の可能性として、
	// ErrPublishRejected に分類する期間。
	DefaultPublishRejectWindow = 5 * time.Second
)

// Config は、Dial・Publisher の設定。ゼロ値は、すべて既定値（負の値は ErrInvalidConfig）。
type Config struct {
	// DialTimeout は、接続全体の期限。
	DialTimeout time.Duration
	// CloseTimeout は、Close が送出待ちを送り切るのを待つ期限。
	CloseTimeout time.Duration
	// CloseLinger は、送り切ったあとの Close が、相手が閉じるのを待つ上限。
	CloseLinger time.Duration
	// TeardownTimeout は、Close・Abort が、接続の後始末を待つ期限（CloseLinger を除く）。過ぎたら、Close は ErrTeardownTimeout を返す
	// （後始末は、背景で続く）。
	TeardownTimeout time.Duration
	// PollInterval は、接続の切断を見張る間隔。
	PollInterval time.Duration
	// PublishRejectWindow は、publish の直後の切断（ErrPublishRejected）とみなす期間。
	PublishRejectWindow time.Duration
	// RootCAs は、TLS の証明書の検証に使う認証局。nil なら、OS の証明書ストア（本番）。試験で、自己署名の証明書を信頼するために渡す。
	// 検証そのものは、省略できない（省略できるのは、PolicyFor が、開発・試験の環境の疑似の取り込み口にだけ許す場合）。
	RootCAs *x509.CertPool
	// Logger は、接続・切断の記録の出力先。nil なら、捨てる。配信キーは、渡さない・出さない。
	Logger *slog.Logger
}

// normalized は、既定値を入れ、検査した Config を返す。
func (c Config) normalized() (Config, error) {
	fields := []struct {
		name     string
		value    *time.Duration
		fallback time.Duration
	}{
		{"DialTimeout", &c.DialTimeout, DefaultDialTimeout},
		{"CloseTimeout", &c.CloseTimeout, DefaultCloseTimeout},
		{"CloseLinger", &c.CloseLinger, DefaultCloseLinger},
		{"TeardownTimeout", &c.TeardownTimeout, DefaultTeardownTimeout},
		{"PollInterval", &c.PollInterval, DefaultPollInterval},
		{"PublishRejectWindow", &c.PublishRejectWindow, DefaultPublishRejectWindow},
	}
	for _, field := range fields {
		switch {
		case *field.value < 0:
			return Config{}, fmt.Errorf("%w: %s %v is negative", ErrInvalidConfig, field.name, *field.value)
		case *field.value == 0:
			*field.value = field.fallback
		}
	}
	if c.Logger == nil {
		c.Logger = slog.New(slog.DiscardHandler)
	}
	return c, nil
}
