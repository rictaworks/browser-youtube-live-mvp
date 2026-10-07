package config

import (
	"errors"
	"testing"
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
