package wsapi

// Error は、このパッケージのエラー（定数。errors.Is で判定できる）。
type Error string

func (e Error) Error() string { return string(e) }

const (
	// ErrInvalidOptions は、設定（Options）が不正（負の値・契約を超える上限・矛盾）。
	ErrInvalidOptions Error = "wsapi: invalid options"
	// ErrInvalidDeps は、必要な依存（時計・ロガー・セッションの受け口）が無い。
	ErrInvalidDeps Error = "wsapi: missing dependency"
)
