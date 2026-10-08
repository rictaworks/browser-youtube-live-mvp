package config

import (
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/appenv"
)

// テスト用の lookup。os.LookupEnv と同じく、未設定（ok=false）と、設定されているが空（ok=true）を区別する
func lookupFrom(env map[string]string) LookupFunc {
	return func(key string) (string, bool) {
		value, ok := env[key]
		return value, ok
	}
}

func TestListenAddress(t *testing.T) {
	cases := []struct {
		name    string
		env     map[string]string
		want    string
		wantErr bool
	}{
		{name: "未設定は既定のポート", env: map[string]string{}, want: ":3002"},
		{name: "PORT を使う", env: map[string]string{"PORT": "8080"}, want: ":8080"},
		{name: "下限の 1", env: map[string]string{"PORT": "1"}, want: ":1"},
		{name: "上限の 65535", env: map[string]string{"PORT": "65535"}, want: ":65535"},
		{name: "設定されているが空は拒否する", env: map[string]string{"PORT": ""}, wantErr: true},
		{name: "数字でない値は拒否する", env: map[string]string{"PORT": "abc"}, wantErr: true},
		{name: "0 は拒否する", env: map[string]string{"PORT": "0"}, wantErr: true},
		{name: "負の値は拒否する", env: map[string]string{"PORT": "-1"}, wantErr: true},
		{name: "上限を超える値は拒否する", env: map[string]string{"PORT": "65536"}, wantErr: true},
		{name: "前後の空白は拒否する", env: map[string]string{"PORT": " 8080"}, wantErr: true},
		{name: "ホスト付きは拒否する", env: map[string]string{"PORT": "0.0.0.0:8080"}, wantErr: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ListenAddress(lookupFrom(tc.env))
			if tc.wantErr {
				if err == nil {
					t.Fatalf("ListenAddress() = %q, nil; want error", got)
				}
				var invalid *InvalidPortError
				if !errors.As(err, &invalid) {
					t.Fatalf("ListenAddress() error = %T; want *InvalidPortError", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("ListenAddress() error = %v; want nil", err)
			}
			if got != tc.want {
				t.Fatalf("ListenAddress() = %q; want %q", got, tc.want)
			}
		})
	}
}

func TestDefaultPortIs3002(t *testing.T) {
	if DefaultPort != 3002 {
		t.Fatalf("DefaultPort = %d; want 3002", DefaultPort)
	}
}

// HTTP サーバーの制限の値。値を固定する（要求ヘッダの読み取り 10 秒・keep-alive の無通信 60 秒・要求ヘッダ全体 16 KiB）
func TestHTTPServerLimits(t *testing.T) {
	if ReadHeaderTimeout != 10*time.Second {
		t.Errorf("ReadHeaderTimeout = %v; want 10s", ReadHeaderTimeout)
	}
	if IdleTimeout != 60*time.Second {
		t.Errorf("IdleTimeout = %v; want 60s", IdleTimeout)
	}
	if MaxHeaderBytes != 16*1024 {
		t.Errorf("MaxHeaderBytes = %d; want 16384 (16 KiB)", MaxHeaderBytes)
	}
}

// ---- Load：環境変数から、中継の設定を読み込む（requirements.md 29.4。欠けていれば起動を失敗させる） ----

const (
	dummyURL    = "http://backend.internal.example:3101"
	dummySecret = "dummy-shared-secret-SECRET-0001"
)

func fullEnv(ginMode string) map[string]string {
	return map[string]string{
		"GIN_MODE":             ginMode,
		"PORT":                 "8080",
		"BACKEND_INTERNAL_URL": dummyURL,
		"RELAY_SHARED_SECRET":  dummySecret,
	}
}

func TestLoadReadsEveryVariable(t *testing.T) {
	cases := []struct {
		name    string
		ginMode string
		want    appenv.Environment
	}{
		{name: "debug は development", ginMode: "debug", want: appenv.Development},
		{name: "test は test", ginMode: "test", want: appenv.Test},
		{name: "release は production", ginMode: "release", want: appenv.Production},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Load(lookupFrom(fullEnv(tc.ginMode)))
			if err != nil {
				t.Fatalf("Load() error = %v; want nil", err)
			}
			if got.Environment != tc.want {
				t.Errorf("Environment = %q; want %q", got.Environment, tc.want)
			}
			if got.ListenAddr != ":8080" {
				t.Errorf("ListenAddr = %q; want :8080", got.ListenAddr)
			}
			if got.BackendInternalURL != dummyURL {
				t.Errorf("BackendInternalURL = %q; want %q", got.BackendInternalURL, dummyURL)
			}
			if got.SharedSecret.String() == dummySecret {
				t.Error("SharedSecret must be a redacted type")
			}
		})
	}
}

func TestLoadUsesTheDefaultPortWhenPortIsNotSet(t *testing.T) {
	env := fullEnv("release")
	delete(env, "PORT")
	got, err := Load(lookupFrom(env))
	if err != nil {
		t.Fatalf("Load() error = %v; want nil", err)
	}
	if got.ListenAddr != ":3002" {
		t.Fatalf("ListenAddr = %q; want :3002", got.ListenAddr)
	}
}

// 欠けている名前だけを出す（値は出さない）。本番だけでなく、開発・試験でも、欠けていれば起動を失敗させる（フォールバック禁止）
func TestLoadFailsWhenARequiredVariableIsMissing(t *testing.T) {
	cases := []struct {
		name      string
		mutate    func(env map[string]string)
		wantNames []string
	}{
		{name: "接続先が未設定", mutate: func(env map[string]string) { delete(env, "BACKEND_INTERNAL_URL") }, wantNames: []string{"BACKEND_INTERNAL_URL"}},
		{name: "秘密値が未設定", mutate: func(env map[string]string) { delete(env, "RELAY_SHARED_SECRET") }, wantNames: []string{"RELAY_SHARED_SECRET"}},
		{
			name: "両方が未設定",
			mutate: func(env map[string]string) {
				delete(env, "BACKEND_INTERNAL_URL")
				delete(env, "RELAY_SHARED_SECRET")
			},
			wantNames: []string{"BACKEND_INTERNAL_URL", "RELAY_SHARED_SECRET"},
		},
		{name: "接続先が空", mutate: func(env map[string]string) { env["BACKEND_INTERNAL_URL"] = "" }, wantNames: []string{"BACKEND_INTERNAL_URL"}},
		{name: "秘密値が空", mutate: func(env map[string]string) { env["RELAY_SHARED_SECRET"] = "" }, wantNames: []string{"RELAY_SHARED_SECRET"}},
		{name: "秘密値が空白だけ", mutate: func(env map[string]string) { env["RELAY_SHARED_SECRET"] = " \t" }, wantNames: []string{"RELAY_SHARED_SECRET"}},
		{name: "接続先が空白だけ", mutate: func(env map[string]string) { env["BACKEND_INTERNAL_URL"] = "  " }, wantNames: []string{"BACKEND_INTERNAL_URL"}},
	}
	for _, ginMode := range []string{"release", "debug", "test"} {
		for _, tc := range cases {
			t.Run(ginMode+"・"+tc.name, func(t *testing.T) {
				env := fullEnv(ginMode)
				tc.mutate(env)
				_, err := Load(lookupFrom(env))
				if err == nil {
					t.Fatal("Load() error = nil; want *MissingError")
				}
				var missing *MissingError
				if !errors.As(err, &missing) {
					t.Fatalf("Load() error = %T; want *MissingError", err)
				}
				if strings.Join(missing.Names, ",") != strings.Join(tc.wantNames, ",") {
					t.Fatalf("MissingError.Names = %v; want %v", missing.Names, tc.wantNames)
				}
				text := err.Error()
				for _, name := range tc.wantNames {
					if !strings.Contains(text, name) {
						t.Errorf("error text %q does not name %s", text, name)
					}
				}
				for _, value := range []string{dummySecret, dummyURL} {
					if strings.Contains(text, value) {
						t.Errorf("error text %q must not contain a value (%q)", text, value)
					}
				}
			})
		}
	}
}

func TestLoadRejectsAnUnknownEnvironmentAndAnInvalidPort(t *testing.T) {
	t.Run("GIN_MODE が未設定", func(t *testing.T) {
		env := fullEnv("release")
		delete(env, "GIN_MODE")
		_, err := Load(lookupFrom(env))
		var unknown *appenv.UnknownGinModeError
		if !errors.As(err, &unknown) {
			t.Fatalf("Load() error = %v; want *appenv.UnknownGinModeError", err)
		}
	})
	t.Run("GIN_MODE が未知", func(t *testing.T) {
		_, err := Load(lookupFrom(fullEnv("staging")))
		var unknown *appenv.UnknownGinModeError
		if !errors.As(err, &unknown) {
			t.Fatalf("Load() error = %v; want *appenv.UnknownGinModeError", err)
		}
	})
	t.Run("PORT が不正", func(t *testing.T) {
		env := fullEnv("release")
		env["PORT"] = "abc"
		_, err := Load(lookupFrom(env))
		var invalid *InvalidPortError
		if !errors.As(err, &invalid) {
			t.Fatalf("Load() error = %v; want *InvalidPortError", err)
		}
	})
	t.Run("すべてを一度に報告する", func(t *testing.T) {
		env := map[string]string{"PORT": "0"}
		_, err := Load(lookupFrom(env))
		var unknown *appenv.UnknownGinModeError
		var invalid *InvalidPortError
		var missing *MissingError
		if !errors.As(err, &unknown) || !errors.As(err, &invalid) || !errors.As(err, &missing) {
			t.Fatalf("Load() error = %v; want the environment, the port and the missing names together", err)
		}
		if len(missing.Names) != 2 {
			t.Fatalf("MissingError.Names = %v; want both names", missing.Names)
		}
	})
}

// 設定を書式化しても、秘密値が出ない
func TestFormattingTheConfigNeverExposesTheSecret(t *testing.T) {
	got, err := Load(lookupFrom(fullEnv("release")))
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	for _, verb := range []string{"%v", "%+v", "%#v", "%s"} {
		text := fmt.Sprintf(verb, got)
		if strings.Contains(text, dummySecret) || strings.Contains(text, "SECRET") {
			t.Errorf("%s of the config exposes the secret: %s", verb, text)
		}
	}
}

func TestVariableNamesMatchRequirements(t *testing.T) {
	want := map[string]string{
		"GIN_MODE":             KeyGinMode,
		"PORT":                 KeyPort,
		"BACKEND_INTERNAL_URL": KeyBackendInternalURL,
		"RELAY_SHARED_SECRET":  KeyRelaySharedSecret,
	}
	for name, got := range want {
		if got != name {
			t.Errorf("constant for %s = %q", name, got)
		}
	}
}
