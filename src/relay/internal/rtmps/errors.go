package rtmps

// Error は、このパッケージのエラー（定数。errors.Is で判定できる）。
//
// エラーの文言は、配信キー・URL の内容（ユーザー情報・パス・クエリ）を含まない。接続の失敗は、標準ライブラリや go-rtmp のエラーを
// 包むので、取り込み先のホスト名・IP アドレス（秘密ではない）が文言に入ることがある。
type Error string

func (e Error) Error() string { return string(e) }

// 送出先の検証（Validate・NewPolicy・PolicyFor）。
const (
	// ErrInvalidURL は、URL として読めない（空・長すぎる・空白や制御文字や非 ASCII の文字を含む・構文の誤り）。
	ErrInvalidURL Error = "rtmps: invalid destination URL"
	// ErrSchemeNotAllowed は、スキームが rtmps ではない（平文の rtmp を含む）。
	ErrSchemeNotAllowed Error = "rtmps: destination scheme is not rtmps"
	// ErrUserInfoNotAllowed は、ユーザー情報（user:pass@）を含む。
	ErrUserInfoNotAllowed Error = "rtmps: destination must not contain user information"
	// ErrQueryNotAllowed は、クエリ（?backup=1 を含む）またはフラグメントを含む。
	ErrQueryNotAllowed Error = "rtmps: destination must not contain a query or a fragment"
	// ErrHostNotAllowed は、ホストが許可リスト（YouTube の取り込み口）に無い。
	ErrHostNotAllowed Error = "rtmps: destination host is not allowed"
	// ErrPortNotAllowed は、ポートが許可リストのものと一致しない（443 以外。ポートの省略を含む）。
	ErrPortNotAllowed Error = "rtmps: destination port is not allowed"
	// ErrPathNotAllowed は、パスが、1 つのアプリ名（英数字・_・-。長さの上限あり）ではない。
	ErrPathNotAllowed Error = "rtmps: destination path is not a single application name"
	// ErrInvalidPolicy は、許可リストの定義が不正（空・ホストやポートの形式の誤り）。
	ErrInvalidPolicy Error = "rtmps: invalid destination policy"
	// ErrUnknownEnvironment は、環境が development・test・production のどれでもない。
	ErrUnknownEnvironment Error = "rtmps: unknown environment"
)

// 配信キー。
const (
	// ErrInvalidStreamKey は、配信キーが不正（空・長すぎる・空白や制御文字や非 ASCII の文字を含む）。
	ErrInvalidStreamKey Error = "rtmps: invalid stream key"
)

// 接続（Dial）。
const (
	// ErrInvalidDestination は、Validate を通っていない送出先（零値）を渡した。
	ErrInvalidDestination Error = "rtmps: destination was not validated"
	// ErrInvalidConfig は、設定が不正（期間が負）。
	ErrInvalidConfig Error = "rtmps: invalid config"
	// ErrDialFailed は、接続・RTMP のハンドシェイク・connect・createStream・publish のいずれかが成立しなかった。
	// *DialError で、どの段階かを示し、原因は Unwrap で得る。
	ErrDialFailed Error = "rtmps: dial failed"
	// ErrDialTimeout は、接続全体（TLS・RTMP のハンドシェイク・connect・createStream・publish）が、期限内に済まなかった。
	// ErrDialFailed でもある。
	ErrDialTimeout Error = "rtmps: dial timed out"
)

// 送出（Publisher）。
const (
	// ErrClosed は、Publisher が閉じている（Close・Abort のあと、または、失敗したあと）。失敗したあとは、原因も包む
	// （errors.Is で、ErrBufferOverflow・ErrDisconnected・ErrPublishRejected なども判定できる）。
	ErrClosed Error = "rtmps: publisher is closed"
	// ErrBufferOverflow は、送出待ちが 3 秒分の上限に達した。バッファは破棄され、Publisher は閉じた。呼び出し側が再接続する。
	ErrBufferOverflow Error = "rtmps: egress buffer reached its limit"
	// ErrDisconnected は、RTMPS の接続が失われた（YouTube 側の切断・書き込みの失敗）。
	ErrDisconnected Error = "rtmps: connection lost"
	// ErrPublishRejected は、publish の直後に接続が切れた。配信キーの不正・使用中の可能性が高い
	// （go-rtmp は、サーバーの応答 onStatus を処理しないので、切断で検知する）。ErrDisconnected とは別の分類。
	ErrPublishRejected Error = "rtmps: connection closed right after publish (the stream key may be invalid or in use)"
	// ErrDrainTimeout は、Close が、送出待ちを期限内に送り切れなかった（接続を強制的に切った）。
	ErrDrainTimeout Error = "rtmps: pending messages were not sent before the close timeout"
	// ErrTeardownTimeout は、接続の後始末が、期限内に済まなかった（後始末は、背景で続く）。
	ErrTeardownTimeout Error = "rtmps: teardown did not finish in time"
	// ErrInvalidMessage は、空の本文、または RTMP のメッセージの長さの上限（24 ビット）を超える本文を渡した。
	ErrInvalidMessage Error = "rtmps: invalid message"
)
