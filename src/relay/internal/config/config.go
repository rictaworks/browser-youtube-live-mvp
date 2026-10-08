// Package config は、環境変数から読み取る設定値（待ち受けのポート・内部通信の接続先と秘密値・実行環境）を扱う
// （requirements.md 29.4）。
//
// 読み込みは Load が行う。必須の変数が欠けていれば、環境を問わず、起動を失敗させる（既定値へ倒さない。CLAUDE.md の
// 「フォールバック禁止」）。エラーには、欠けている変数の名前だけを出し、値は出さない。
package config

import (
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/appenv"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
)

// 中継が読む環境変数の名前（requirements.md 29.4。GIN_MODE と PORT は、Gin と Railway が定める）。
const (
	// KeyGinMode は、実行環境の判定に使う（debug・test・release）。
	KeyGinMode = "GIN_MODE"
	// KeyPort は、待ち受けのポート（Railway が与える）。未設定なら DefaultPort。
	KeyPort = "PORT"
	// KeyBackendInternalURL は、アプリケーションの内部通信の接続先。
	KeyBackendInternalURL = "BACKEND_INTERNAL_URL"
	// KeyRelaySharedSecret は、内部通信の相互確認に使う共有の秘密値（アプリケーションと同じ値）。
	KeyRelaySharedSecret = "RELAY_SHARED_SECRET"
)

const (
	// DefaultPort は、PORT が未設定のときに待ち受けるポート。
	DefaultPort = 3002

	// ReadHeaderTimeout は、リクエストヘッダの読み取りの期限（低速な接続による占有を防ぐ）。
	ReadHeaderTimeout = 10 * time.Second

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
	return fmt.Sprintf("invalid %s %q: %s", KeyPort, e.Value, e.Reason)
}

// MissingError は、必須の環境変数が欠けている（未設定、空、空白だけ）ときのエラー。欠けている名前だけを持つ（値は持たない）。
type MissingError struct {
	Names []string
}

func (e *MissingError) Error() string {
	return "missing required environment variables: " + strings.Join(e.Names, ", ")
}

// Config は、中継の起動に必要な設定。
type Config struct {
	// Environment は、実行環境（GIN_MODE から決める）。開発用の許可（疑似の取り込み口など）は、production 以外にだけ効く。
	Environment appenv.Environment
	// ListenAddr は、待ち受けのアドレス（":<ポート>"）。
	ListenAddr string
	// BackendInternalURL は、アプリケーションの内部側の口の接続先（外部から到達できない経路）。
	BackendInternalURL string
	// SharedSecret は、内部通信の共有の秘密値。ログ・エラー・%v・JSON のどこにも、中身を出さない型。
	SharedSecret backend.Secret
}

// String は、環境と待ち受けのアドレスだけを示す（接続先・秘密値を含めない）。
func (c Config) String() string {
	return fmt.Sprintf("config.Config{environment=%s listen=%s}", c.Environment, c.ListenAddr)
}

// GoString は、String と同じ（%#v でも、接続先・秘密値を出さない）。
func (c Config) GoString() string { return c.String() }

// Format は、どの書式動詞でも、String だけを書く。
func (c Config) Format(f fmt.State, _ rune) { _, _ = io.WriteString(f, c.String()) }

// Load は、環境変数から設定を読み込む。実行環境（GIN_MODE）・ポート（PORT）・必須の変数が欠けている、または不正なものを、
// 見つけたぶんすべて報告する（errors.Join。errors.As で *appenv.UnknownGinModeError・*InvalidPortError・*MissingError を取り出せる）。
// 必須の変数は、BACKEND_INTERNAL_URL と RELAY_SHARED_SECRET。未設定・空・空白だけは、欠けているとみなす。
// 値の形式（URL・秘密値）の検査は、内部通信のクライアントを作るときに行う（backend.NewClient）。
func Load(lookup LookupFunc) (Config, error) {
	var problems []error
	var cfg Config

	mode, _ := lookup(KeyGinMode)
	environment, err := appenv.FromGinMode(mode)
	if err != nil {
		problems = append(problems, fmt.Errorf("detect the environment: %w", err))
	} else {
		cfg.Environment = environment
	}

	addr, err := ListenAddress(lookup)
	if err != nil {
		problems = append(problems, fmt.Errorf("resolve the listen address: %w", err))
	} else {
		cfg.ListenAddr = addr
	}

	var missing []string
	if value, ok := required(lookup, KeyBackendInternalURL); ok {
		cfg.BackendInternalURL = value
	} else {
		missing = append(missing, KeyBackendInternalURL)
	}
	if value, ok := required(lookup, KeyRelaySharedSecret); ok {
		cfg.SharedSecret = backend.Secret(value)
	} else {
		missing = append(missing, KeyRelaySharedSecret)
	}
	if len(missing) > 0 {
		problems = append(problems, &MissingError{Names: missing})
	}

	if len(problems) > 0 {
		return Config{}, errors.Join(problems...)
	}
	return cfg, nil
}

// required は、必須の変数の値を返す。未設定・空・空白だけなら false。
func required(lookup LookupFunc, key string) (string, bool) {
	value, ok := lookup(key)
	if !ok || strings.TrimSpace(value) == "" {
		return "", false
	}
	return value, true
}

// ListenAddress は、待ち受けのアドレス（":<ポート>"）を返す。PORT が未設定なら DefaultPort を使う。
func ListenAddress(lookup LookupFunc) (string, error) {
	raw, ok := lookup(KeyPort)
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
