package session

import (
	"fmt"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps"
)

// Options は、取り込みセッションと台帳の設定値。ゼロの欄は既定値（DefaultOptions）。負の値・矛盾は ErrInvalidOptions。
// 既定値は、契約（src/contracts/limits.json）の値から取る。契約に無い値は、解釈として置いたもの（欄の説明に書く）。
type Options struct {
	// HelloTimeout は、接続から接続通知（hello）までの期限（relay.hello_timeout_seconds）。
	HelloTimeout time.Duration
	// HeartbeatInterval は、心拍の間隔（relay.heartbeat_interval_seconds）。
	HeartbeatInterval time.Duration
	// AckInterval は、受領応答の間隔（relay.ack_interval_ms）。映像・音声の無通信の確認の間隔でもある。
	AckInterval time.Duration
	// InterruptionLimit は、中断の安全のための上限（deadlines.interrupted_heartbeat_lost_seconds の 75 秒）。
	// 期限は、アプリケーションが停止を指示するか、この上限か、早い方。送信元が無いまま、これだけ経った場合も閉じる。
	InterruptionLimit time.Duration
	// PublishConfirmWindow は、RTMPS の接続・publish のあと、事象 publish_started と status(confirming) を出すまで、
	// 接続が切れないかを見る時間。go-rtmp は publish の成否（onStatus）を知らないので、切断が来ないことで確かめる
	// （#19 の PublishRejectWindow と同じ 5 秒）。0 を明示できないので、すぐに出したい試験は、極めて短い値を使う。
	PublishConfirmWindow time.Duration
	// RedialInitial・RedialMax は、RTMPS の再接続の待機の最初の値と上限（指数的に増やす。上限は
	// deadlines.reconnect_backoff_cap_ms の 5 秒。最初の値は契約に無く、解釈として 500 ms）。
	RedialInitial time.Duration
	RedialMax     time.Duration
	// MaxRedialAttempts は、連続して失敗してよい RTMPS の接続の回数（成功で数え直す）。応答しない受け口との接続は、
	// ゴルーチンを 1 つ残すので、上限を置く（#19 のレビューの申し送り）。超えたら、取り込みセッションを閉じる。
	MaxRedialAttempts int
	// MaxDialFailures は、取り込みセッションの生涯で、失敗してよい RTMPS の接続の合計。
	MaxDialFailures int
	// InboxSize は、取り込みセッションの受信の待ち行列の長さ。満ちたら、受信を止める（ブラウザへ背圧がかかる）。
	InboxSize int
	// MaxBrowserEvents は、心拍で届けるまで保持する、ブラウザ側の出来事の上限。超えたら、古いものから捨てる。
	MaxBrowserEvents int
	// MaxEventsPerReport は、1 回の状態報告に載せてよい出来事の数。超える報告は破棄する。
	MaxEventsPerReport int
	// BanTTL は、受信量の超過で切断した配信への再接続を拒む期間。MaxBanned は、その配信の記録の上限。
	BanTTL    time.Duration
	MaxBanned int
}

// DefaultOptions は、既定の設定値。
func DefaultOptions() Options {
	return Options{
		HelloTimeout:         contract.RelayHelloTimeoutSeconds * time.Second,
		HeartbeatInterval:    contract.RelayHeartbeatIntervalSeconds * time.Second,
		AckInterval:          contract.RelayAckIntervalMs * time.Millisecond,
		InterruptionLimit:    contract.DeadlinesInterruptedHeartbeatLostSeconds * time.Second,
		PublishConfirmWindow: rtmps.DefaultPublishRejectWindow,
		RedialInitial:        500 * time.Millisecond,
		RedialMax:            contract.DeadlinesReconnectBackoffCapMs * time.Millisecond,
		MaxRedialAttempts:    6,
		MaxDialFailures:      24,
		InboxSize:            1024,
		MaxBrowserEvents:     2048,
		MaxEventsPerReport:   64,
		BanTTL:               2 * time.Hour,
		MaxBanned:            1024,
	}
}

// normalized は、ゼロの欄を既定値にして、検査する。
func (o Options) normalized() (Options, error) {
	defaults := DefaultOptions()
	durations := []struct {
		name     string
		value    *time.Duration
		fallback time.Duration
	}{
		{"HelloTimeout", &o.HelloTimeout, defaults.HelloTimeout},
		{"HeartbeatInterval", &o.HeartbeatInterval, defaults.HeartbeatInterval},
		{"AckInterval", &o.AckInterval, defaults.AckInterval},
		{"InterruptionLimit", &o.InterruptionLimit, defaults.InterruptionLimit},
		{"PublishConfirmWindow", &o.PublishConfirmWindow, defaults.PublishConfirmWindow},
		{"RedialInitial", &o.RedialInitial, defaults.RedialInitial},
		{"RedialMax", &o.RedialMax, defaults.RedialMax},
		{"BanTTL", &o.BanTTL, defaults.BanTTL},
	}
	for _, field := range durations {
		switch {
		case *field.value < 0:
			return Options{}, fmt.Errorf("%w: %s is negative", ErrInvalidOptions, field.name)
		case *field.value == 0:
			*field.value = field.fallback
		}
	}
	counts := []struct {
		name     string
		value    *int
		fallback int
	}{
		{"MaxRedialAttempts", &o.MaxRedialAttempts, defaults.MaxRedialAttempts},
		{"MaxDialFailures", &o.MaxDialFailures, defaults.MaxDialFailures},
		{"InboxSize", &o.InboxSize, defaults.InboxSize},
		{"MaxBrowserEvents", &o.MaxBrowserEvents, defaults.MaxBrowserEvents},
		{"MaxEventsPerReport", &o.MaxEventsPerReport, defaults.MaxEventsPerReport},
		{"MaxBanned", &o.MaxBanned, defaults.MaxBanned},
	}
	for _, field := range counts {
		switch {
		case *field.value < 0:
			return Options{}, fmt.Errorf("%w: %s is negative", ErrInvalidOptions, field.name)
		case *field.value == 0:
			*field.value = field.fallback
		}
	}
	if o.RedialMax < o.RedialInitial {
		return Options{}, fmt.Errorf("%w: RedialMax is shorter than RedialInitial", ErrInvalidOptions)
	}
	return o, nil
}
