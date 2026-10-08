package session

// Error は、このパッケージのエラー（定数。errors.Is で判定できる）。
type Error string

func (e Error) Error() string { return string(e) }

const (
	// ErrInvalidOptions は、設定（Options）が不正（負の値・矛盾）。
	ErrInvalidOptions Error = "session: invalid options"
	// ErrInvalidDeps は、必要な依存（Backend・Events・Publishers・Clock）が無い。
	ErrInvalidDeps Error = "session: missing dependency"
	// ErrInvalidParams は、取り込みセッションの作成の引数が不正（配信の識別子・アカウントの値）。
	ErrInvalidParams Error = "session: invalid session parameters"
	// ErrSessionClosed は、閉じた（閉じている最中の）取り込みセッションへ、送信元を差し替えようとした。
	ErrSessionClosed Error = "session: the ingest session is closed"
	// ErrAlreadyRegistered は、同じ配信の取り込みセッションが、すでに台帳にある。
	ErrAlreadyRegistered Error = "session: an ingest session for the broadcast is already registered"
	// ErrShuttingDown は、停止の手順に入った台帳が、新しい接続・セッションを受け付けない。
	ErrShuttingDown Error = "session: the registry is shutting down"
	// ErrLinkClosed は、ブラウザとの接続（BrowserLink）が閉じていて、送れない。実装（#21）が返す。
	ErrLinkClosed Error = "session: the browser link is closed"
	// ErrDestinationRejected は、取り込み先が検証に通らない（YouTube の取り込み口ではない・平文・ポートの誤りなど）。
	// 接続を試みない。再試行しても変わらない。
	ErrDestinationRejected Error = "session: the ingest destination was rejected"

	// errInvalidBody は、本文が検査に通らない（破棄する）。
	errInvalidBody Error = "session: invalid message body"
)
