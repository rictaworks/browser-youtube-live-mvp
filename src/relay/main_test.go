package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/sirupsen/logrus"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/appenv"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/config"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/server"
)

const (
	dummyURL    = "http://backend.internal.example:3101"
	dummySecret = "dummy-shared-secret-SECRET-0001"
)

// syncBuffer は、複数のゴルーチンから書いてよい、メモリ上のバッファ。
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func lookupFrom(env map[string]string) func(string) (string, bool) {
	return func(key string) (string, bool) {
		value, ok := env[key]
		return value, ok
	}
}

func fullEnv(ginMode, port string) map[string]string {
	env := map[string]string{"GIN_MODE": ginMode, "BACKEND_INTERNAL_URL": dummyURL, "RELAY_SHARED_SECRET": dummySecret}
	if port != "" {
		env["PORT"] = port
	}
	return env
}

func TestNewApp(t *testing.T) {
	cases := []struct {
		name     string
		env      map[string]string
		wantEnv  appenv.Environment
		wantAddr string
		wantErr  bool
	}{
		{name: "debug・PORT 未設定は development・既定のポート", env: fullEnv("debug", ""), wantEnv: appenv.Development, wantAddr: ":3002"},
		{name: "test", env: fullEnv("test", "9000"), wantEnv: appenv.Test, wantAddr: ":9000"},
		{name: "release・PORT は production", env: fullEnv("release", "8080"), wantEnv: appenv.Production, wantAddr: ":8080"},
		{name: "GIN_MODE が未設定なら起動しない", env: map[string]string{"BACKEND_INTERNAL_URL": dummyURL, "RELAY_SHARED_SECRET": dummySecret}, wantErr: true},
		{name: "GIN_MODE が未知なら起動しない", env: fullEnv("staging", ""), wantErr: true},
		{name: "PORT が不正なら起動しない", env: fullEnv("test", "abc"), wantErr: true},
		{name: "接続先が無ければ起動しない（本番）", env: map[string]string{"GIN_MODE": "release", "RELAY_SHARED_SECRET": dummySecret}, wantErr: true},
		{name: "秘密値が無ければ起動しない（本番）", env: map[string]string{"GIN_MODE": "release", "BACKEND_INTERNAL_URL": dummyURL}, wantErr: true},
		{name: "接続先が不正なら起動しない", env: map[string]string{"GIN_MODE": "test", "BACKEND_INTERNAL_URL": "ftp://x", "RELAY_SHARED_SECRET": dummySecret}, wantErr: true},
		{name: "秘密値が不正なら起動しない", env: map[string]string{"GIN_MODE": "test", "BACKEND_INTERNAL_URL": dummyURL, "RELAY_SHARED_SECRET": "has space"}, wantErr: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := newApp(lookupFrom(tc.env), io.Discard, io.Discard)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("newApp() = %+v, nil; want error", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("newApp() error = %v; want nil", err)
			}
			t.Cleanup(got.close)
			if got.cfg.Environment != tc.wantEnv {
				t.Errorf("environment = %q; want %q", got.cfg.Environment, tc.wantEnv)
			}
			if got.cfg.ListenAddr != tc.wantAddr {
				t.Errorf("addr = %q; want %q", got.cfg.ListenAddr, tc.wantAddr)
			}
			if got.server == nil {
				t.Error("server = nil; want the wired relay")
			}
		})
	}
}

// 標準出力・標準エラーの出力先は必須。nil を、捨てる出力先へ黙って差し替えない（記録が消えて、異常に気づけなくなる）。
// 失敗した起動が、外部のライブラリ（go-rtmp）の記録の向きを、変えたまま残さない
func TestNewAppRequiresTheOutputsAndNeverSubstitutesThem(t *testing.T) {
	cases := []struct {
		name           string
		stdout, stderr io.Writer
	}{
		{"標準出力が無い", nil, io.Discard},
		{"標準エラーが無い", io.Discard, nil},
		{"どちらも無い", nil, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			std := logrus.StandardLogger()
			var original bytes.Buffer
			previousOut := std.Out
			std.SetOutput(&original)
			t.Cleanup(func() { std.SetOutput(previousOut) })

			got, err := newApp(lookupFrom(fullEnv("test", "")), tc.stdout, tc.stderr)
			if err == nil {
				got.close()
				t.Fatalf("newApp() = %+v, nil; want an error when an output is missing", got)
			}
			if !errors.Is(err, server.ErrInvalidDeps) {
				t.Errorf("newApp() error = %v; want server.ErrInvalidDeps", err)
			}
			logrus.Info("after the failed start")
			if !strings.Contains(original.String(), "after the failed start") {
				t.Errorf("logrus lost its own output after a failed start: %q", original.String())
			}
		})
	}
}

// 起動の失敗は、欠けている名前だけを示し、値（接続先・秘密値）を出さない
func TestStartupFailureNamesTheMissingVariablesButNeverShowsValues(t *testing.T) {
	env := map[string]string{"GIN_MODE": "release", "PORT": "8080", "RELAY_SHARED_SECRET": dummySecret}
	var stdout, stderr syncBuffer
	if code := run(lookupFrom(env), &stdout, &stderr); code == 0 {
		t.Fatal("run() = 0; want a failure when BACKEND_INTERNAL_URL is missing")
	}
	text := stderr.String()
	if !strings.Contains(text, "BACKEND_INTERNAL_URL") {
		t.Errorf("stderr = %q; want it to name the missing variable", text)
	}
	if strings.Contains(text, "RELAY_SHARED_SECRET") {
		t.Errorf("stderr = %q; the variable that is set must not be reported as missing", text)
	}
	for _, leaked := range []string{dummySecret, "SECRET"} {
		if strings.Contains(text+stdout.String(), leaked) {
			t.Errorf("the output contains %q", leaked)
		}
	}
}

func TestStartupFailureOfAnInvalidSecretNeverShowsTheValue(t *testing.T) {
	env := map[string]string{"GIN_MODE": "test", "BACKEND_INTERNAL_URL": dummyURL, "RELAY_SHARED_SECRET": "invalid secret SECRET"}
	var stdout, stderr syncBuffer
	if code := run(lookupFrom(env), &stdout, &stderr); code == 0 {
		t.Fatal("run() = 0; want a failure for an invalid secret")
	}
	for _, leaked := range []string{"invalid secret", "SECRET", dummyURL} {
		if strings.Contains(stderr.String()+stdout.String(), leaked) {
			t.Errorf("the output contains %q: %s", leaked, stderr.String())
		}
	}
}

func freePort(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()
	_, port, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		t.Fatalf("split: %v", err)
	}
	return port
}

func waitForHealth(t *testing.T, base string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		response, err := http.Get(base + "/health")
		if err == nil {
			body, _ := io.ReadAll(response.Body)
			response.Body.Close()
			if response.StatusCode == http.StatusOK && strings.Contains(string(body), `"status":"ok"`) {
				return
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("GET /health did not become healthy: %v", err)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// ヘルスチェックに答え、context が終わったら、正常に停止する
func TestTheAppServesHealthAndStopsGracefullyOnCancel(t *testing.T) {
	a, err := newApp(lookupFrom(fullEnv("test", "")), io.Discard, io.Discard)
	if err != nil {
		t.Fatalf("newApp: %v", err)
	}
	t.Cleanup(a.close)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- a.serve(ctx, listener) }()
	base := "http://" + listener.Addr().String()
	waitForHealth(t, base)

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("serve() error = %v; want nil after a requested stop", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("serve did not return after the context was cancelled")
	}
}

// 待ち受けに失敗（ポートが使用中）したら、終了コードは 0 ではない
func TestRunFailsWhenThePortIsInUse(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()
	_, port, _ := net.SplitHostPort(listener.Addr().String())
	var stdout, stderr syncBuffer
	if code := run(lookupFrom(fullEnv("test", port)), &stdout, &stderr); code == 0 {
		t.Fatal("run() = 0; want a failure when the port is in use")
	}
	if !strings.Contains(stderr.String(), "listen") {
		t.Errorf("stderr = %q; want the listen failure", stderr.String())
	}
}

func TestEnvironmentVariableNamesAreTheOnesInRequirements(t *testing.T) {
	// requirements.md 29.4：中継が読むのは、BACKEND_INTERNAL_URL・RELAY_SHARED_SECRET（と、Railway の PORT・Gin の GIN_MODE）
	for _, name := range []string{"BACKEND_INTERNAL_URL", "RELAY_SHARED_SECRET", "PORT", "GIN_MODE"} {
		found := false
		for _, known := range []string{config.KeyBackendInternalURL, config.KeyRelaySharedSecret, config.KeyPort, config.KeyGinMode} {
			if known == name {
				found = true
			}
		}
		if !found {
			t.Errorf("the config package has no key for %s", name)
		}
	}
}
