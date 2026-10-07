// Package appenv は、実行環境（development・test・production）の判定を担う。
//
// 環境の判定は GIN_MODE で行う。未設定・未知の値は、既定の環境へ倒さず、エラーにする。
package appenv

import (
	"fmt"

	"github.com/gin-gonic/gin"
)

// Environment は、中継が動いている環境。
type Environment string

const (
	Development Environment = "development"
	Test        Environment = "test"
	Production  Environment = "production"
)

// UnknownGinModeError は、GIN_MODE が未設定、または判定できない値のときのエラー。
type UnknownGinModeError struct {
	Value string
}

func (e *UnknownGinModeError) Error() string {
	const expected = "(expected one of: " + gin.DebugMode + ", " + gin.TestMode + ", " + gin.ReleaseMode + ")"
	if e.Value == "" {
		return "GIN_MODE is not set " + expected
	}
	return fmt.Sprintf("unknown GIN_MODE %q %s", e.Value, expected)
}

// FromGinMode は、GIN_MODE の値（debug・test・release）を環境へ対応づける。
func FromGinMode(mode string) (Environment, error) {
	switch mode {
	case gin.DebugMode:
		return Development, nil
	case gin.TestMode:
		return Test, nil
	case gin.ReleaseMode:
		return Production, nil
	default:
		return "", &UnknownGinModeError{Value: mode}
	}
}
