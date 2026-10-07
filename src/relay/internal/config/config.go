// Package config は、環境変数から読み取る設定値（待ち受けのポートなど）を扱う。
package config

import (
	"fmt"
	"strconv"
	"time"
)

const (
	// DefaultPort は、PORT が未設定のときに待ち受けるポート。
	DefaultPort = 3002

	// ReadHeaderTimeout は、リクエストヘッダの読み取りの期限（低速な接続による占有を防ぐ）。
	ReadHeaderTimeout = 10 * time.Second

	portKey = "PORT"
	minPort = 1
	maxPort = 65535
)

// LookupFunc は、環境変数を引く関数。os.LookupEnv と同じく、未設定（ok が false）と、空の値を区別する。
type LookupFunc func(key string) (value string, ok bool)

// InvalidPortError は、PORT が設定されているが、ポート番号として使えないときのエラー。
type InvalidPortError struct {
	Value  string
	Reason string
}

func (e *InvalidPortError) Error() string {
	return fmt.Sprintf("invalid %s %q: %s", portKey, e.Value, e.Reason)
}

// ListenAddress は、待ち受けのアドレス（":<ポート>"）を返す。PORT が未設定なら DefaultPort を使う。
func ListenAddress(lookup LookupFunc) (string, error) {
	raw, ok := lookup(portKey)
	if !ok {
		return ":" + strconv.Itoa(DefaultPort), nil
	}
	port, err := strconv.Atoi(raw)
	if err != nil {
		return "", &InvalidPortError{Value: raw, Reason: "must be an integer"}
	}
	if port < minPort || port > maxPort {
		return "", &InvalidPortError{Value: raw, Reason: fmt.Sprintf("must be between %d and %d", minPort, maxPort)}
	}
	return ":" + strconv.Itoa(port), nil
}
