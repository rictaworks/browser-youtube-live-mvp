package main

import (
	"testing"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/appenv"
)

func lookupFrom(env map[string]string) func(string) (string, bool) {
	return func(key string) (string, bool) {
		value, ok := env[key]
		return value, ok
	}
}

func TestNewApp(t *testing.T) {
	cases := []struct {
		name     string
		env      map[string]string
		wantEnv  appenv.Environment
		wantAddr string
		wantErr  bool
	}{
		{
			name:     "debug・PORT 未設定は development・既定のポート",
			env:      map[string]string{"GIN_MODE": "debug"},
			wantEnv:  appenv.Development,
			wantAddr: ":3002",
		},
		{
			name:     "test",
			env:      map[string]string{"GIN_MODE": "test", "PORT": "9000"},
			wantEnv:  appenv.Test,
			wantAddr: ":9000",
		},
		{
			name:     "release・PORT は production",
			env:      map[string]string{"GIN_MODE": "release", "PORT": "8080"},
			wantEnv:  appenv.Production,
			wantAddr: ":8080",
		},
		{name: "GIN_MODE が未設定なら起動しない", env: map[string]string{}, wantErr: true},
		{name: "GIN_MODE が未知なら起動しない", env: map[string]string{"GIN_MODE": "staging"}, wantErr: true},
		{name: "PORT が不正なら起動しない", env: map[string]string{"GIN_MODE": "test", "PORT": "abc"}, wantErr: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := newApp(lookupFrom(tc.env))
			if tc.wantErr {
				if err == nil {
					t.Fatalf("newApp() = %+v, nil; want error", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("newApp() error = %v; want nil", err)
			}
			if got.env != tc.wantEnv {
				t.Errorf("env = %q; want %q", got.env, tc.wantEnv)
			}
			if got.addr != tc.wantAddr {
				t.Errorf("addr = %q; want %q", got.addr, tc.wantAddr)
			}
			if got.handler == nil {
				t.Error("handler = nil; want a router")
			}
		})
	}
}
