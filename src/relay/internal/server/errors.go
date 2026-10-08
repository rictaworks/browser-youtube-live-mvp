package server

// Error は、このパッケージのエラー（定数。errors.Is で判定できる）。
type Error string

func (e Error) Error() string { return string(e) }

const (
	// ErrPolicyOverrideInProduction は、production で、送出先の許可リストを差し替えようとした。送出先は、YouTube の取り込み口に
	// 限る（requirements.md 28.1）。差し替えは、開発・試験の環境の試験だけが行える。
	ErrPolicyOverrideInProduction Error = "server: the destination policy cannot be replaced in production"
)
