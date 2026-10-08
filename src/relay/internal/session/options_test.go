package session

import (
	"errors"
	"testing"
	"time"
)

// 設定値は、契約（limits.json）の値から取る。ゼロの欄は既定値。負は不可。

func TestDefaultOptionsFollowTheContract(t *testing.T) {
	got := DefaultOptions()
	want := Options{
		HelloTimeout:         10 * time.Second,       // relay.hello_timeout_seconds
		HeartbeatInterval:    2 * time.Second,        // relay.heartbeat_interval_seconds
		AckInterval:          500 * time.Millisecond, // relay.ack_interval_ms
		InterruptionLimit:    75 * time.Second,       // deadlines.interrupted_heartbeat_lost_seconds
		PublishConfirmWindow: 5 * time.Second,        // rtmps.DefaultPublishRejectWindow
		RedialInitial:        500 * time.Millisecond, // 契約に無い（解釈）
		RedialMax:            5 * time.Second,        // deadlines.reconnect_backoff_cap_ms
		MaxRedialAttempts:    6,
		MaxDialFailures:      24,
		InboxSize:            1024,
		MaxBrowserEvents:     2048,
		MaxEventsPerReport:   64,
		BanTTL:               2 * time.Hour,
		MaxBanned:            1024,
	}
	if got != want {
		t.Fatalf("DefaultOptions = %+v\nwant           %+v", got, want)
	}
}

func TestZeroOptionsNormalizeToTheDefaults(t *testing.T) {
	got, err := Options{}.normalized()
	if err != nil {
		t.Fatalf("normalized: %v", err)
	}
	if got != DefaultOptions() {
		t.Fatalf("normalized zero = %+v, want the defaults", got)
	}
}

func TestOptionsKeepExplicitValues(t *testing.T) {
	custom := DefaultOptions()
	custom.HelloTimeout = 3 * time.Second
	custom.MaxRedialAttempts = 2
	got, err := custom.normalized()
	if err != nil {
		t.Fatalf("normalized: %v", err)
	}
	if got != custom {
		t.Fatalf("normalized = %+v, want %+v", got, custom)
	}
}

func TestOptionsRejectInvalidValues(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(o *Options)
	}{
		{"接続通知の期限が負", func(o *Options) { o.HelloTimeout = -time.Second }},
		{"心拍の間隔が負", func(o *Options) { o.HeartbeatInterval = -1 }},
		{"受領応答の間隔が負", func(o *Options) { o.AckInterval = -1 }},
		{"中断の上限が負", func(o *Options) { o.InterruptionLimit = -1 }},
		{"送出の確認の窓が負", func(o *Options) { o.PublishConfirmWindow = -1 }},
		{"再接続の最初の待機が負", func(o *Options) { o.RedialInitial = -1 }},
		{"再接続の待機の上限が負", func(o *Options) { o.RedialMax = -1 }},
		{"再接続の待機の上限が最初より短い", func(o *Options) { o.RedialInitial = 2 * time.Second; o.RedialMax = time.Second }},
		{"再接続の試行回数が負", func(o *Options) { o.MaxRedialAttempts = -1 }},
		{"接続の失敗の上限が負", func(o *Options) { o.MaxDialFailures = -1 }},
		{"受信の待ち行列が負", func(o *Options) { o.InboxSize = -1 }},
		{"ブラウザの出来事の上限が負", func(o *Options) { o.MaxBrowserEvents = -1 }},
		{"1 回の報告の出来事の上限が負", func(o *Options) { o.MaxEventsPerReport = -1 }},
		{"禁止の保持が負", func(o *Options) { o.BanTTL = -1 }},
		{"禁止の件数が負", func(o *Options) { o.MaxBanned = -1 }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			options := DefaultOptions()
			c.mutate(&options)
			if _, err := options.normalized(); !errors.Is(err, ErrInvalidOptions) {
				t.Fatalf("error = %v, want ErrInvalidOptions", err)
			}
		})
	}
}
