package server

// Error は、このパッケージのエラー（定数。errors.Is で判定できる）。
type Error string

func (e Error) Error() string { return string(e) }

const (
	// ErrPolicyOverrideInProduction は、production で、送出先の許可リストを差し替えようとした。送出先は、YouTube の取り込み口に
	// 限る（requirements.md 28.1）。差し替えは、開発・試験の環境の試験だけが行える。
	ErrPolicyOverrideInProduction Error = "server: the destination policy cannot be replaced in production"
	// ErrInvalidDeps は、必須の依存（記録の出力先 Logger・AccessLog・ErrorLog）が無い。捨てる出力先へ黙って差し替えない
	// （記録が消えて、異常に気づけなくなる。捨ててよい試験は、捨てる出力先を明示して渡す。#20 の session.Deps と同じ）。
	ErrInvalidDeps Error = "server: missing dependency"
)
