package rtmps

import (
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"slices"
	"strconv"
	"strings"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/appenv"
)

// 送出先の検証（requirements.md 6.1・10.1・28.1）。
//
// 送出先は、アプリケーションが内部通信（準備の応答）で返す取り込み先だけで、利用者が宛先を指定する手段は存在しない。
// 中継は、送出の前に、もう一度、その取り込み先を検証する（アプリケーションの検証と二重にする）。許すのは、
//   - スキームが rtmps であること（平文の rtmp を拒否する）
//   - ホストが許可リスト（YouTube の取り込み口）に一致すること。IP アドレスで接続しない（SNI にホスト名を設定する）
//   - ポートが許可リストのものと一致すること（YouTube は 443 のみ。省略も拒否する）
//   - ユーザー情報・クエリ（?backup=1 を含む）・フラグメントを含まないこと
//   - パスが、1 つのアプリ名（英数字・_・-。長さの上限あり）であること。配信キーは URL に混ぜず、別に受け取る
// 判定できないものは、すべて拒否する（フォールバックしない）。エラーは、URL の内容を含まない。

const (
	// schemeRTMPS は、許可する唯一のスキーム（契約 rtmps_ingest・dev_ingest のスキームは、どちらも rtmps）。
	schemeRTMPS = contract.RTMPSIngestScheme

	// maxURLBytes は、検証する URL の長さの上限（バイト）。YouTube の取り込み先は 40 バイトほど。
	maxURLBytes = 256
	// maxAppNameBytes は、アプリ名（URL のパス）の長さの上限（バイト）。YouTube は live2。「過大なパス」を拒否する。
	maxAppNameBytes = 64

	// maxHostBytes・maxLabelBytes は、ホスト名・ラベルの長さの上限（DNS の規則）。
	maxHostBytes  = 253
	maxLabelBytes = 63

	minPort = 1
	maxPort = 65535

	// firstPrintable・lastPrintable は、URL に使ってよい文字の範囲（空白・制御文字・DEL・非 ASCII を拒否する）。
	firstPrintable = 0x21
	lastPrintable  = 0x7E

	// devTLSSelfSigned は、契約 dev_ingest.tls の値のうち、証明書の検証を省略してよいもの。ほかの値なら、省略しない。
	devTLSSelfSigned = "self_signed"

	redactedDestination = "[rtmps destination]"
)

// Target は、許可する送出先の 1 つ（ホストとポート）。
type Target struct {
	// Host は、ホスト名（小文字の ASCII の英数字・ハイフン・ドット。IP アドレスは不可。IP アドレスでは接続しない）。
	Host string
	// Port は、ポート（YouTube は 443）。
	Port int
}

// allowedTarget は、許可リストの 1 つ。skipTLSVerify は、PolicyFor が、開発用の疑似の取り込み口にだけ付ける
// （NewPolicy で作ったものは、常に検証する）。
type allowedTarget struct {
	Target
	skipTLSVerify bool
}

// Policy は、許可する送出先の一覧。ゼロ値は、何も許可しない。作成後は変わらない（Targets はコピーを返す）。
type Policy struct {
	allowed []allowedTarget
}

// NewPolicy は、指定した送出先だけを許可する Policy を作る（試験で、許可リストを注入するため）。TLS の証明書は、常に検証する。
// 空・不正なホストやポートは、ErrInvalidPolicy。ホストは、小文字の ASCII のホスト名に限る（そろえずに拒否する）。
func NewPolicy(targets ...Target) (Policy, error) {
	allowed := make([]allowedTarget, len(targets))
	for i, target := range targets {
		allowed[i] = allowedTarget{Target: target}
	}
	return newPolicy(allowed)
}

// PolicyFor は、環境の許可リストを返す。
//
// production は、YouTube の取り込み口（契約 rtmps_ingest：ホスト a.rtmps.youtube.com・b.rtmps.youtube.com、ポート 443）だけ。
// 開発・試験の環境（契約 dev_ingest.allowed_environments：development・test）は、これに加えて、疑似の取り込み口
// （契約 dev_ingest：ホスト fake-ingest・ポート 1935）を許可し、そのホストに限り、TLS の証明書の検証を省略できる
// （疑似の取り込み口は、自己署名の証明書のため）。production には、この許可が存在しない。
// development・test・production のどれでもない環境は ErrUnknownEnvironment（既定の環境へ倒さない）。
func PolicyFor(env appenv.Environment) (Policy, error) {
	switch env {
	case appenv.Production, appenv.Development, appenv.Test:
	default:
		return Policy{}, fmt.Errorf("%w: %q", ErrUnknownEnvironment, string(env))
	}

	hosts := contract.RTMPSIngestHosts()
	allowed := make([]allowedTarget, 0, len(hosts)+1)
	for _, host := range hosts {
		allowed = append(allowed, allowedTarget{Target: Target{Host: host, Port: contract.RTMPSIngestPort}})
	}
	if slices.Contains(contract.DevIngestAllowedEnvironments(), string(env)) {
		allowed = append(allowed, allowedTarget{
			Target:        Target{Host: contract.DevIngestHost, Port: contract.DevIngestPort},
			skipTLSVerify: contract.DevIngestTLS == devTLSSelfSigned,
		})
	}
	return newPolicy(allowed)
}

// PolicyForGinMode は、GIN_MODE の値（debug・test・release）から、PolicyFor の環境を決める（環境変数の名前を増やさない）。
// release（production）でないときに限り、開発用の許可が加わる。未設定・未知の値は、エラー（既定の環境へ倒さない）。
func PolicyForGinMode(ginMode string) (Policy, error) {
	env, err := appenv.FromGinMode(ginMode)
	if err != nil {
		return Policy{}, fmt.Errorf("rtmps: resolve the destination policy: %w", err)
	}
	return PolicyFor(env)
}

// Targets は、許可する送出先の一覧を、コピーで返す。
func (p Policy) Targets() []Target {
	targets := make([]Target, len(p.allowed))
	for i, allowed := range p.allowed {
		targets[i] = allowed.Target
	}
	return targets
}

// newPolicy は、許可リストを検査して、Policy を作る。
func newPolicy(allowed []allowedTarget) (Policy, error) {
	if len(allowed) == 0 {
		return Policy{}, fmt.Errorf("%w: no targets", ErrInvalidPolicy)
	}
	for i, target := range allowed {
		if err := validateHostName(target.Host); err != nil {
			return Policy{}, fmt.Errorf("%w: target %d: %w", ErrInvalidPolicy, i, err)
		}
		if target.Port < minPort || target.Port > maxPort {
			return Policy{}, fmt.Errorf("%w: target %d: port %d (want %d..%d)", ErrInvalidPolicy, i, target.Port, minPort, maxPort)
		}
	}
	return Policy{allowed: slices.Clone(allowed)}, nil
}

// validateHostName は、許可リストのホスト名を検査する。小文字の ASCII のホスト名に限る。IP アドレス（IPv4 の省略形を含む）を拒否する。
// 文言には、ホスト名の中身を含めない。
func validateHostName(host string) error {
	if host == "" {
		return errors.New("host is empty")
	}
	if len(host) > maxHostBytes {
		return fmt.Errorf("host is %d bytes (want at most %d)", len(host), maxHostBytes)
	}
	labels := strings.Split(host, ".")
	for _, label := range labels {
		if label == "" {
			return errors.New("host has an empty label")
		}
		if len(label) > maxLabelBytes {
			return fmt.Errorf("host has a label of %d bytes (want at most %d)", len(label), maxLabelBytes)
		}
		if label[0] == '-' || label[len(label)-1] == '-' {
			return errors.New("host has a label that starts or ends with a hyphen")
		}
		for i := 0; i < len(label); i++ {
			if !isHostByte(label[i]) {
				return errors.New("host must be lower-case ASCII letters, digits, hyphens and dots")
			}
		}
	}
	// IP アドレスでは接続しない（SNI にホスト名を設定する）。IPv6 は、「:」が、文字の検査で外れる。IPv4 の標準の形（127.0.0.1）と、
	// 省略形（127.1）・整数の形（2130706433）・16 進の形（0x7f.0x1）は、最後のラベルが、数字だけ・16 進の数だけになる。
	// 実在の最上位のドメインは、そのような形にならない。
	if looksNumeric(labels[len(labels)-1]) {
		return errors.New("host ends with a numeric label (it could be read as an IP address; connect by host name)")
	}
	return nil
}

func isHostByte(b byte) bool {
	return (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '-'
}

// looksNumeric は、ラベルが、10 進の数だけ、または、0x で始まる 16 進の数だけか。
func looksNumeric(label string) bool {
	digits := label
	isDigit := func(b byte) bool { return b >= '0' && b <= '9' }
	if strings.HasPrefix(label, "0x") && len(label) > 2 {
		digits = label[2:]
		isDigit = func(b byte) bool { return (b >= '0' && b <= '9') || (b >= 'a' && b <= 'f') }
	}
	for i := 0; i < len(digits); i++ {
		if !isDigit(digits[i]) {
			return false
		}
	}
	return digits != ""
}

// find は、ホストとポートが、許可リストの 1 つと一致するかを調べる。ホストが無ければ ErrHostNotAllowed、ホストはあるが
// ポートが違えば（ポートの省略を含む）ErrPortNotAllowed。ポートは、文字列のまま比べる（0443 は 443 と別）。
func (p Policy) find(host, port string) (allowedTarget, error) {
	hostKnown := false
	for _, allowed := range p.allowed {
		if allowed.Host != host {
			continue
		}
		hostKnown = true
		if port == strconv.Itoa(allowed.Port) {
			return allowed, nil
		}
	}
	if !hostKnown {
		return allowedTarget{}, ErrHostNotAllowed
	}
	return allowedTarget{}, ErrPortNotAllowed
}

// ValidatedDestination は、Validate を通った送出先。フィールドは非公開で、Validate 以外では作れない
// （Dial は、ゼロ値を ErrInvalidDestination で拒否する）。ログ・%v へは、中身を出さない。
type ValidatedDestination struct {
	host          string
	port          int
	app           string
	skipTLSVerify bool
}

func (d ValidatedDestination) valid() bool {
	return d.host != "" && d.port >= minPort && d.port <= maxPort && d.app != ""
}

// addr は、接続先（ホスト名:ポート）。IP アドレスではなくホスト名で接続する。
func (d ValidatedDestination) addr() string {
	return net.JoinHostPort(d.host, strconv.Itoa(d.port))
}

// tcURL は、RTMP の connect の tcUrl（rtmps://ホスト:ポート/アプリ名）。
func (d ValidatedDestination) tcURL() string {
	return schemeRTMPS + "://" + d.addr() + "/" + d.app
}

// String は、取り込み先を含まない文字列を返す。
func (d ValidatedDestination) String() string { return redactedDestination }

// Format は、どの書式動詞でも、取り込み先を含まない文字列を書く（%v・%+v・%#v・%s）。
func (d ValidatedDestination) Format(f fmt.State, _ rune) {
	_, _ = io.WriteString(f, redactedDestination)
}

// Validate は、URL（取り込み先。配信キーを含まない）を、policy に照らして検証する。違反は、型付きのエラー
// （ErrInvalidURL・ErrSchemeNotAllowed・ErrUserInfoNotAllowed・ErrQueryNotAllowed・ErrHostNotAllowed・ErrPortNotAllowed・
// ErrPathNotAllowed）で、ゼロ値の ValidatedDestination を返す。エラーは URL の内容を含まない。
func Validate(rawURL string, policy Policy) (ValidatedDestination, error) {
	if err := checkSyntax(rawURL); err != nil {
		return ValidatedDestination{}, err
	}
	// url.Parse のエラーは、URL の文字列を含む（ユーザー情報・パスに混ざった配信キーを漏らし得る）ので、原因は捨てる
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return ValidatedDestination{}, ErrInvalidURL
	}
	if parsed.Scheme != schemeRTMPS {
		return ValidatedDestination{}, ErrSchemeNotAllowed
	}
	if parsed.Opaque != "" {
		return ValidatedDestination{}, fmt.Errorf("%w: no authority", ErrInvalidURL)
	}
	if parsed.User != nil {
		return ValidatedDestination{}, ErrUserInfoNotAllowed
	}
	if parsed.RawQuery != "" || parsed.ForceQuery || parsed.Fragment != "" || parsed.RawFragment != "" || strings.ContainsAny(rawURL, "?#") {
		return ValidatedDestination{}, ErrQueryNotAllowed
	}
	// 非 ASCII は、checkSyntax で拒否済み。ホスト名の大文字・小文字は区別しない（小文字へそろえる）
	target, err := policy.find(strings.ToLower(parsed.Hostname()), parsed.Port())
	if err != nil {
		return ValidatedDestination{}, err
	}
	app, err := appName(parsed)
	if err != nil {
		return ValidatedDestination{}, err
	}
	return ValidatedDestination{host: target.Host, port: target.Port, app: app, skipTLSVerify: target.skipTLSVerify}, nil
}

// checkSyntax は、URL の文字を検査する（空・長すぎる・空白や制御文字や非 ASCII の文字を拒否する）。
// 非 ASCII のホスト（全角の文字・ケルビン記号など、小文字へそろえると別の文字になるもの）を、ここで止める。
func checkSyntax(rawURL string) error {
	if rawURL == "" {
		return fmt.Errorf("%w: empty", ErrInvalidURL)
	}
	if len(rawURL) > maxURLBytes {
		return fmt.Errorf("%w: %d bytes (want at most %d)", ErrInvalidURL, len(rawURL), maxURLBytes)
	}
	for i := 0; i < len(rawURL); i++ {
		if rawURL[i] < firstPrintable || rawURL[i] > lastPrintable {
			return fmt.Errorf("%w: unexpected character at position %d", ErrInvalidURL, i)
		}
	}
	return nil
}

// appName は、URL のパスから、アプリ名を取り出す。パスは、「/」と、英数字・_・- の 1 つのアプリ名だけ（長さの上限あり）。
// パーセントエンコードは、すべて拒否する。配信キーを URL に混ぜた形（/live2/キー）も、ここで拒否する。
func appName(parsed *url.URL) (string, error) {
	if parsed.RawPath != "" {
		return "", fmt.Errorf("%w: encoded path", ErrPathNotAllowed)
	}
	if !strings.HasPrefix(parsed.Path, "/") {
		return "", fmt.Errorf("%w: no path", ErrPathNotAllowed)
	}
	app := parsed.Path[1:]
	if len(app) < 1 || len(app) > maxAppNameBytes {
		return "", fmt.Errorf("%w: length %d (want 1..%d)", ErrPathNotAllowed, len(app), maxAppNameBytes)
	}
	for i := 0; i < len(app); i++ {
		if !isAppNameByte(app[i]) {
			return "", fmt.Errorf("%w: unexpected character at position %d", ErrPathNotAllowed, i)
		}
	}
	return app, nil
}

func isAppNameByte(b byte) bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_' || b == '-'
}
