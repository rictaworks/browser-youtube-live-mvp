package wsapi

import (
	"errors"
	"log/slog"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

func TestOptionsDefaultsFollowTheContract(t *testing.T) {
	logger := slog.New(slog.DiscardHandler)
	got, err := Options{Clock: newFakeClock(), Logger: logger}.normalized()
	if err != nil {
		t.Fatalf("normalized() error = %v; want nil", err)
	}
	if got.MaxMessageBytes != 2_097_152 {
		t.Errorf("MaxMessageBytes = %d; want 2097152 (ws_frame.max_message_bytes)", got.MaxMessageBytes)
	}
	if contract.WSFrameMaxMessageBytes != 2_097_152 {
		t.Errorf("the contract constant = %d; want 2097152", contract.WSFrameMaxMessageBytes)
	}
	cases := []struct {
		name string
		got  time.Duration
		want time.Duration
	}{
		{"PingInterval", got.PingInterval, DefaultPingInterval},
		{"IdleTimeout", got.IdleTimeout, DefaultIdleTimeout},
		{"WriteTimeout", got.WriteTimeout, DefaultWriteTimeout},
		{"LingerTimeout", got.LingerTimeout, DefaultLingerTimeout},
		{"HandshakeTimeout", got.HandshakeTimeout, DefaultHandshakeTimeout},
	}
	for _, c := range cases {
		if c.got != c.want || c.want <= 0 {
			t.Errorf("%s = %v; want the default %v (positive)", c.name, c.got, c.want)
		}
	}
	if got.MaxConnections != DefaultMaxConnections || got.SendQueueLimit != DefaultSendQueueLimit {
		t.Errorf("MaxConnections = %d, SendQueueLimit = %d; want the defaults", got.MaxConnections, got.SendQueueLimit)
	}
	if got.Logger != logger {
		t.Error("Logger was replaced; want the logger that was passed (it is a required dependency, never defaulted)")
	}
	if got.IdleTimeout <= got.PingInterval {
		t.Errorf("IdleTimeout %v must exceed PingInterval %v", got.IdleTimeout, got.PingInterval)
	}
}

func TestOptionsKeepTheValuesThatAreSet(t *testing.T) {
	opts := Options{
		Clock: newFakeClock(), Logger: slog.New(slog.DiscardHandler), MaxMessageBytes: 1024, MaxConnections: 3, SendQueueLimit: 4,
		PingInterval: time.Second, IdleTimeout: 3 * time.Second, WriteTimeout: 2 * time.Second, LingerTimeout: time.Second,
	}
	got, err := opts.normalized()
	if err != nil {
		t.Fatalf("normalized() error = %v; want nil", err)
	}
	if got.MaxMessageBytes != 1024 || got.MaxConnections != 3 || got.SendQueueLimit != 4 ||
		got.PingInterval != time.Second || got.IdleTimeout != 3*time.Second || got.WriteTimeout != 2*time.Second || got.LingerTimeout != time.Second {
		t.Fatalf("normalized() = %+v; the values that were set must be kept", got)
	}
}

func TestOptionsRejectInvalidValues(t *testing.T) {
	clock := newFakeClock()
	logger := slog.New(slog.DiscardHandler)
	cases := []struct {
		name string
		opts Options
		want error
	}{
		{"時計もロガーも無い", Options{}, ErrInvalidDeps},
		{"時計が無い", Options{Logger: logger}, ErrInvalidDeps},
		{"ロガーが無い（捨てる出力先へ差し替えない）", Options{Clock: clock}, ErrInvalidDeps},
		{"メッセージの上限が負", Options{Clock: clock, Logger: logger, MaxMessageBytes: -1}, ErrInvalidOptions},
		{"メッセージの上限が契約を超える", Options{Clock: clock, Logger: logger, MaxMessageBytes: contract.WSFrameMaxMessageBytes + 1}, ErrInvalidOptions},
		{"メッセージの上限がヘッダより小さい", Options{Clock: clock, Logger: logger, MaxMessageBytes: contract.WSFrameHeaderBytes - 1}, ErrInvalidOptions},
		{"接続数の上限が負", Options{Clock: clock, Logger: logger, MaxConnections: -1}, ErrInvalidOptions},
		{"送信待ちの上限が負", Options{Clock: clock, Logger: logger, SendQueueLimit: -1}, ErrInvalidOptions},
		{"ping の間隔が負", Options{Clock: clock, Logger: logger, PingInterval: -time.Second}, ErrInvalidOptions},
		{"無通信の期限が負", Options{Clock: clock, Logger: logger, IdleTimeout: -time.Second}, ErrInvalidOptions},
		{"書き込みの期限が負", Options{Clock: clock, Logger: logger, WriteTimeout: -time.Second}, ErrInvalidOptions},
		{"切断の待ちが負", Options{Clock: clock, Logger: logger, LingerTimeout: -time.Second}, ErrInvalidOptions},
		{"無通信の期限が ping の間隔以下", Options{Clock: clock, Logger: logger, PingInterval: 10 * time.Second, IdleTimeout: 10 * time.Second}, ErrInvalidOptions},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, err := c.opts.normalized(); !errors.Is(err, c.want) {
				t.Fatalf("normalized() error = %v; want %v", err, c.want)
			}
		})
	}
}
