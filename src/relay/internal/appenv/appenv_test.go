package appenv

import (
	"errors"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestFromGinMode(t *testing.T) {
	cases := []struct {
		name    string
		mode    string
		want    Environment
		wantErr bool
	}{
		{name: "debug は development", mode: "debug", want: Development},
		{name: "test は test", mode: "test", want: Test},
		{name: "release は production", mode: "release", want: Production},
		{name: "空（未設定）は拒否する", mode: "", wantErr: true},
		{name: "未知の値は拒否する", mode: "staging", wantErr: true},
		{name: "大文字は別の値として拒否する", mode: "RELEASE", wantErr: true},
		{name: "前後の空白は別の値として拒否する", mode: " release", wantErr: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := FromGinMode(tc.mode)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("FromGinMode(%q) = %q, nil; want error", tc.mode, got)
				}
				var unknown *UnknownGinModeError
				if !errors.As(err, &unknown) {
					t.Fatalf("FromGinMode(%q) error = %T; want *UnknownGinModeError", tc.mode, err)
				}
				if unknown.Value != tc.mode {
					t.Fatalf("UnknownGinModeError.Value = %q; want %q", unknown.Value, tc.mode)
				}
				return
			}
			if err != nil {
				t.Fatalf("FromGinMode(%q) error = %v; want nil", tc.mode, err)
			}
			if got != tc.want {
				t.Fatalf("FromGinMode(%q) = %q; want %q", tc.mode, got, tc.want)
			}
		})
	}
}

// Gin が定める 3 つのモードを、すべて環境へ対応づけられること（Gin の定数との食い違いを検知する）
func TestFromGinModeCoversEveryGinMode(t *testing.T) {
	for _, mode := range []string{gin.DebugMode, gin.TestMode, gin.ReleaseMode} {
		if _, err := FromGinMode(mode); err != nil {
			t.Errorf("FromGinMode(%q) error = %v; want nil", mode, err)
		}
	}
}

func TestUnknownGinModeErrorMessage(t *testing.T) {
	cases := []struct {
		name  string
		value string
		want  string
	}{
		{name: "未設定", value: "", want: "GIN_MODE is not set (expected one of: debug, test, release)"},
		{name: "未知の値", value: "staging", want: `unknown GIN_MODE "staging" (expected one of: debug, test, release)`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := (&UnknownGinModeError{Value: tc.value}).Error()
			if got != tc.want {
				t.Fatalf("Error() = %q; want %q", got, tc.want)
			}
		})
	}
}
