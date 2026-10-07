package frame

import "errors"

// ErrorCode は、フレームの検証の失敗の種類。
//
// 先頭の 7 種は、ws-protocol.md の 4 章（検証の順）の符号。最後の CodeTimeRegression は、TimeGuard が、同じ種別で時刻が逆行する
// フレームを破棄するときの符号（検証の順の外）。errors.Is で判定できる。
type ErrorCode string

const (
	CodeTruncatedHeader    ErrorCode = "truncated_header"
	CodeInvalidMagic       ErrorCode = "invalid_magic"
	CodeUnsupportedVersion ErrorCode = "unsupported_version"
	CodeUnknownType        ErrorCode = "unknown_type"
	CodeWrongDirection     ErrorCode = "wrong_direction"
	CodeTooLarge           ErrorCode = "too_large"
	CodeLengthMismatch     ErrorCode = "length_mismatch"
	CodeTimeRegression     ErrorCode = "time_regression"
)

// Error は、符号に、診断のための詳細を添えたエラー。詳細は、長さ・符号・時刻などの数値だけで、本文（接続チケットなど）を含めない。
// Unwrap が符号を返すので、errors.Is(err, frame.CodeTooLarge) で判定できる。
type Error struct {
	Code   ErrorCode
	Detail string
}

func (e *Error) Error() string {
	return "frame: " + string(e.Code) + ": " + e.Detail
}

// Unwrap は、符号を返す（errors.Is の判定のため）。
func (e *Error) Unwrap() error { return e.Code }

// Error は、符号そのものを、エラーとして使えるようにする（errors.Is の比較の対象）。
func (c ErrorCode) Error() string {
	return "frame: " + string(c)
}

// CodeOf は、err（ラップされていてもよい）が、このパッケージの Error なら、その符号を返す。そうでなければ、空と false。
func CodeOf(err error) (ErrorCode, bool) {
	var typed *Error
	if errors.As(err, &typed) {
		return typed.Code, true
	}
	return "", false
}
