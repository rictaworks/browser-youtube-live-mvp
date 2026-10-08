package session

// internal/session と internal/backend のソースの走査（requirements.md 6.1・10.1・11.10・28.1。CLAUDE.md の不変条件）。
//
//   - 実時計を直接使わない：time.Now・Sleep・After・AfterFunc・NewTimer・NewTicker・Tick・Since・Until を呼ばない。時刻とタイマーは、
//     注入された Clock（session）・Waiter（backend）から取る。例外は、実時間の実装（session/clock.go・backend/waiter.go）だけ
//   - 入出力に触れない：os・log・ファイル・標準出力・乱数を使わない（メディアをファイルへ保存しない）。session は、HTTP も
//     ネットワークも使わない（アプリケーションとの通信は backend、RTMPS は rtmps の境界）
//   - 秘密値を出さない：reveal()（共有の秘密値・接続チケットの中身を得る呼び出し）は backend/client.go だけ。ログの引数に、配信キー・
//     取り込み先・チケット・秘密値・アカウントの値・視聴 URL を渡さない。エラーの文言（.Error()）も渡さない（取り込み先のホスト名・
//     IP アドレス・応答の内容を含み得る。分類だけを出す）
//   - 送出先の許可リストを、本番のコードで作らない：rtmps.NewPolicy は試験だけ（本番の経路は PolicyForGinMode。#19 の申し送り）。
//     rtmps.Dial・rtmps.Validate は session/factory.go だけ
//   - TLS の検証を省略しない：InsecureSkipVerify を書かない
//   - リダイレクトを追わない・プロキシを使わない（backend）：http.DefaultClient・http.Get などを使わず、ErrUseLastResponse を持つ
//   - グローバル変数を持たない（パッケージレベルの var と init が無い）
//   - 利用者に表示する文字列を直書きしない（文字列リテラルに日本語などの非 ASCII を含めない）
//   - 機密を非公開の欄に持つ構造体（取り込みセッション・内部通信クライアント）を、書式化しても機密が出ない（Format・String・GoString を持つ）こと。
//     fmt は、非公開の欄の型のメソッドを呼ばないため、構造体自身が握らないと、%+v・log.Printf・slog.Any で中身が出る
//
// 走査器そのものが、違反を見逃さないこと（空振りでないこと）も、メモリ上のソースで確かめる。

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"testing"
)

const modulePrefix = "github.com/rictaworks/browser-youtube-live-mvp/relay/"

// ruleSet は、1 つのパッケージに課す規則。
type ruleSet struct {
	name string
	// allowedModuleImports は、参照してよい、中継の別のパッケージ（モジュール内の相対パス）。
	allowedModuleImports []string
	// forbiddenImports・forbiddenImportPrefixes は、参照しない標準・外部のパッケージ。
	forbiddenImports        []string
	forbiddenImportPrefixes []string
	// fileOnlyCalls は、特定のファイルだけで呼んでよい関数（"パッケージ.関数" → ファイル名）。ほかのファイルでは違反。
	fileOnlyCalls map[string]string
	// forbiddenCalls は、どのファイルでも呼ばない関数（"パッケージ.関数"）。
	forbiddenCalls []string
}

func sessionRules() ruleSet {
	return ruleSet{
		name: "session",
		allowedModuleImports: []string{
			"core/buffer", "core/contract", "core/frame", "core/liveness", "core/policer", "core/probe", "core/rebase", "core/watchdog",
			"internal/backend", "internal/flv", "internal/rtmps",
		},
		forbiddenImports: []string{
			"os", "io/ioutil", "log", "net", "net/http", "crypto/tls", "database/sql", "math/rand", "math/rand/v2", "crypto/rand", "plugin", "unsafe",
		},
		forbiddenImportPrefixes: []string{"os/", "net/", "github.com/gorilla/", "github.com/gin-gonic/", "golang.org/x/net", "github.com/yutopp/"},
		fileOnlyCalls: map[string]string{
			"time.Now":       "clock.go",
			"time.AfterFunc": "clock.go",
			"rtmps.Dial":     "factory.go",
			"rtmps.Validate": "factory.go",
		},
		forbiddenCalls: concat(timeCalls(), []string{
			"fmt.Print", "fmt.Printf", "fmt.Println", "fmt.Fprint", "fmt.Fprintf", "fmt.Fprintln", "fmt.Scan", "fmt.Scanf", "fmt.Scanln",
			"fmt.Fscan", "fmt.Fscanf", "fmt.Fscanln", "rtmps.NewPolicy", "context.WithTimeout", "context.WithDeadline",
		}),
	}
}

func backendRules() ruleSet {
	return ruleSet{
		name:                    "backend",
		allowedModuleImports:    []string{"core/contract", "internal/rtmps"},
		forbiddenImports:        []string{"os", "io/ioutil", "log", "database/sql", "math/rand", "math/rand/v2", "crypto/rand", "plugin", "unsafe"},
		forbiddenImportPrefixes: []string{"os/", "github.com/gorilla/", "github.com/gin-gonic/", "golang.org/x/net", "github.com/yutopp/"},
		fileOnlyCalls: map[string]string{
			"time.After":          "waiter.go",
			"context.WithTimeout": "client.go",
		},
		forbiddenCalls: concat(timeCalls(), []string{
			"fmt.Print", "fmt.Printf", "fmt.Println", "fmt.Fprint", "fmt.Fprintf", "fmt.Fprintln", "fmt.Scan", "fmt.Scanf", "fmt.Scanln",
			"rtmps.NewPolicy", "rtmps.Dial", "rtmps.Validate", "context.WithDeadline",
			"http.DefaultClient", "http.DefaultTransport", "http.Get", "http.Post", "http.PostForm", "http.Head", "http.ProxyFromEnvironment",
		}),
	}
}

// timeCalls は、実時計を読む・待つ関数。実時間の実装のファイルだけが、例外として呼べる（fileOnlyCalls）。
func timeCalls() []string {
	return []string{"time.Now", "time.Sleep", "time.After", "time.AfterFunc", "time.NewTimer", "time.NewTicker", "time.Tick", "time.Since", "time.Until"}
}

func concat(lists ...[]string) []string {
	var out []string
	for _, list := range lists {
		out = append(out, list...)
	}
	return out
}

type violation struct {
	file   string
	line   int
	rule   string
	detail string
}

func (v violation) String() string {
	return fmt.Sprintf("%s:%d: [%s] %s", v.file, v.line, v.rule, v.detail)
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func isVersionElement(element string) bool {
	if len(element) < 2 || element[0] != 'v' {
		return false
	}
	for _, r := range element[1:] {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func importLocalName(spec *ast.ImportSpec, importPath string) string {
	if spec.Name != nil {
		return spec.Name.Name
	}
	name := path.Base(importPath)
	if isVersionElement(name) {
		name = path.Base(path.Dir(importPath))
	}
	return name
}

// secretNames は、ログの引数に渡してはならない名前（配信キー・取り込み先・チケット・秘密値・アカウントの値・視聴 URL）。
func secretNames() []string {
	return []string{"key", "streamKey", "StreamKey", "ingestURL", "IngestURL", "URL", "ticket", "Ticket", "secret", "Secret",
		"accountKey", "AccountKey", "watchURL", "WatchURL"}
}

func isLogCall(call *ast.CallExpr) bool {
	selector, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	switch selector.Sel.Name {
	case "Debug", "Info", "Warn", "Error", "Log":
		return len(call.Args) > 0
	}
	return false
}

// scanLogArguments は、ログの呼び出しの引数に、秘密の名前・エラーの文言（.Error()）が無いことを確かめる。
func scanLogArguments(call *ast.CallExpr, add func(pos token.Pos, rule, detail string)) {
	selectorNames := map[*ast.Ident]bool{} // x.key の key は、セレクタとして数える（識別子としては数えない）
	for _, arg := range call.Args {
		ast.Inspect(arg, func(node ast.Node) bool {
			switch typed := node.(type) {
			case *ast.Ident:
				if !selectorNames[typed] && contains(secretNames(), typed.Name) {
					add(typed.Pos(), "log", "a log argument uses the secret-bearing name "+typed.Name)
				}
			case *ast.SelectorExpr:
				selectorNames[typed.Sel] = true
				if contains(secretNames(), typed.Sel.Name) {
					add(typed.Pos(), "log", "a log argument uses the secret-bearing name "+typed.Sel.Name)
				}
			case *ast.CallExpr:
				if selector, ok := typed.Fun.(*ast.SelectorExpr); ok && selector.Sel.Name == "Error" && len(typed.Args) == 0 {
					add(typed.Pos(), "log", "a log argument uses an error text (.Error()); log a classification instead")
				}
			}
			return true
		})
	}
}

// fileScan は、1 つのソースの走査結果。
type fileScan struct {
	violations  []violation
	revealCalls int
}

func scanFile(rules ruleSet, fset *token.FileSet, file *ast.File, name string) fileScan {
	var result fileScan
	add := func(pos token.Pos, rule, detail string) {
		result.violations = append(result.violations, violation{file: name, line: fset.Position(pos).Line, rule: rule, detail: detail})
	}

	localToPath := map[string]string{}
	for _, spec := range file.Imports {
		importPath, err := strconv.Unquote(spec.Path.Value)
		if err != nil {
			add(spec.Pos(), "import", "cannot read the import path "+spec.Path.Value)
			continue
		}
		localToPath[importLocalName(spec, importPath)] = importPath
		forbidden := contains(rules.forbiddenImports, importPath)
		for _, prefix := range rules.forbiddenImportPrefixes {
			if strings.HasPrefix(importPath, prefix) {
				forbidden = true
			}
		}
		if forbidden {
			add(spec.Pos(), "import", "imports "+importPath+" (not allowed in "+rules.name+")")
		}
		if strings.HasPrefix(importPath, modulePrefix) {
			relative := strings.TrimPrefix(importPath, modulePrefix)
			if !contains(rules.allowedModuleImports, relative) {
				add(spec.Pos(), "import", "imports "+importPath+" (allowed: "+strings.Join(rules.allowedModuleImports, ", ")+")")
			}
		}
	}

	ast.Inspect(file, func(node ast.Node) bool {
		switch typed := node.(type) {
		case *ast.SelectorExpr:
			ident, ok := typed.X.(*ast.Ident)
			if !ok {
				return true
			}
			importPath, isPackage := localToPath[ident.Name]
			if !isPackage || ident.Obj != nil {
				return true
			}
			qualified := path.Base(importPath) + "." + typed.Sel.Name
			if isVersionElement(path.Base(importPath)) {
				qualified = path.Base(path.Dir(importPath)) + "." + typed.Sel.Name
			}
			allowedFile, restricted := rules.fileOnlyCalls[qualified]
			switch {
			case restricted && name != allowedFile:
				add(typed.Pos(), "call", qualified+" may be used only in "+allowedFile)
			case !restricted && contains(rules.forbiddenCalls, qualified):
				add(typed.Pos(), "call", qualified+" is forbidden in "+rules.name)
			}
		case *ast.CallExpr:
			if selector, ok := typed.Fun.(*ast.SelectorExpr); ok && selector.Sel.Name == "reveal" {
				result.revealCalls++
				if name != "client.go" {
					add(typed.Pos(), "secret", "reveal() is called outside client.go")
				}
			}
			if isLogCall(typed) {
				scanLogArguments(typed, add)
			}
		case *ast.KeyValueExpr:
			if key, ok := typed.Key.(*ast.Ident); ok && key.Name == "InsecureSkipVerify" {
				add(typed.Pos(), "tls", "InsecureSkipVerify must not be set here")
			}
		}
		return true
	})

	for _, declaration := range file.Decls {
		switch typed := declaration.(type) {
		case *ast.GenDecl:
			if typed.Tok != token.VAR {
				continue
			}
			for _, spec := range typed.Specs {
				valueSpec := spec.(*ast.ValueSpec)
				allBlank := true
				for _, ident := range valueSpec.Names {
					if ident.Name != "_" {
						allBlank = false
					}
				}
				if !allBlank {
					add(valueSpec.Pos(), "global", "package-level var "+valueSpec.Names[0].Name+" (global variables are forbidden)")
				}
			}
		case *ast.FuncDecl:
			if typed.Recv == nil && typed.Name.Name == "init" {
				add(typed.Pos(), "global", "init function (global state is forbidden)")
			}
		}
	}

	ast.Inspect(file, func(node ast.Node) bool {
		literal, ok := node.(*ast.BasicLit)
		if !ok || (literal.Kind != token.STRING && literal.Kind != token.CHAR) {
			return true
		}
		value, err := strconv.Unquote(literal.Value)
		if err != nil {
			add(literal.Pos(), "literal", "cannot read the literal "+literal.Value)
			return true
		}
		for _, r := range value {
			if r > 0x7F {
				add(literal.Pos(), "literal", fmt.Sprintf("non-ASCII literal %s (user-facing text belongs in the message catalog, not in the code)", literal.Value))
				break
			}
		}
		return true
	})
	return result
}

func scanSource(t *testing.T, rules ruleSet, name, source string) fileScan {
	t.Helper()
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, name, source, 0)
	if err != nil {
		t.Fatalf("cannot parse the sample source %s: %v", name, err)
	}
	return scanFile(rules, fset, file, name)
}

func rulesOf(violations []violation) []string {
	rules := make([]string, 0, len(violations))
	for _, v := range violations {
		rules = append(rules, v.rule)
	}
	sort.Strings(rules)
	return rules
}

// 走査器が、違反を見逃さず、違反でないものを誤検知しないこと。
func TestScannerFindsViolations(t *testing.T) {
	cases := []struct {
		name      string
		rules     ruleSet
		file      string
		source    string
		wantRules []string
	}{
		{"os の import", sessionRules(), "x.go", "package p\nimport _ \"os\"\n", []string{"import"}},
		{"net/http の import（session）", sessionRules(), "x.go", "package p\nimport _ \"net/http\"\n", []string{"import"}},
		{"net の import（session）", sessionRules(), "x.go", "package p\nimport _ \"net\"\n", []string{"import"}},
		{"net/http の import（backend は可）", backendRules(), "x.go", "package p\nimport _ \"net/http\"\n", nil},
		{"log の import", backendRules(), "x.go", "package p\nimport _ \"log\"\n", []string{"import"}},
		{"math/rand の import", sessionRules(), "x.go", "package p\nimport _ \"math/rand\"\n", []string{"import"}},
		{"go-rtmp の import", sessionRules(), "x.go", "package p\nimport _ \"github.com/yutopp/go-rtmp\"\n", []string{"import"}},
		{"gin の import", sessionRules(), "x.go", "package p\nimport _ \"github.com/gin-gonic/gin\"\n", []string{"import"}},
		{"server（別の層）の import", sessionRules(), "x.go", "package p\nimport _ \"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/server\"\n", []string{"import"}},
		{"session（上の層）の import（backend）", backendRules(), "x.go", "package p\nimport _ \"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/session\"\n", []string{"import"}},
		{"flv の import（backend は不可）", backendRules(), "x.go", "package p\nimport _ \"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/flv\"\n", []string{"import"}},
		{"time.Now", sessionRules(), "x.go", "package p\nimport \"time\"\nfunc f() { _ = time.Now() }\n", []string{"call"}},
		{"time.Now（clock.go は可）", sessionRules(), "clock.go", "package p\nimport \"time\"\nfunc f() { _ = time.Now() }\n", nil},
		{"time.Sleep（clock.go でも不可）", sessionRules(), "clock.go", "package p\nimport \"time\"\nfunc f() { time.Sleep(1) }\n", []string{"call"}},
		{"time.AfterFunc", sessionRules(), "x.go", "package p\nimport \"time\"\nfunc f() { _ = time.AfterFunc(1, func() {}) }\n", []string{"call"}},
		{"time.After（backend の waiter.go は可）", backendRules(), "waiter.go", "package p\nimport \"time\"\nfunc f() { _ = time.After(1) }\n", nil},
		{"time.After（backend の別のファイル）", backendRules(), "events.go", "package p\nimport \"time\"\nfunc f() { _ = time.After(1) }\n", []string{"call"}},
		{"time.Since", backendRules(), "client.go", "package p\nimport \"time\"\nfunc f(t time.Time) { _ = time.Since(t) }\n", []string{"call"}},
		{"time.Duration は可", sessionRules(), "x.go", "package p\nimport \"time\"\nconst d = 2 * time.Second\nfunc f(x time.Duration) time.Duration { return x }\n", nil},
		{"context.WithTimeout（session）", sessionRules(), "x.go", "package p\nimport \"context\"\nfunc f() { _, _ = context.WithTimeout(context.Background(), 1) }\n", []string{"call"}},
		{"context.WithTimeout（backend の client.go は可）", backendRules(), "client.go", "package p\nimport \"context\"\nfunc f() { _, _ = context.WithTimeout(context.Background(), 1) }\n", nil},
		{"context.WithTimeout（backend の別のファイル）", backendRules(), "events.go", "package p\nimport \"context\"\nfunc f() { _, _ = context.WithTimeout(context.Background(), 1) }\n", []string{"call"}},
		{"rtmps.NewPolicy", sessionRules(), "factory.go", "package p\nimport \"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps\"\nfunc f() { _, _ = rtmps.NewPolicy() }\n", []string{"call"}},
		{"rtmps.Dial（factory.go は可）", sessionRules(), "factory.go", "package p\nimport \"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps\"\nfunc f() { _, _ = rtmps.Dial(nil, rtmps.ValidatedDestination{}, \"\", rtmps.Config{}) }\n", nil},
		{"rtmps.Dial（別のファイル）", sessionRules(), "session.go", "package p\nimport \"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps\"\nfunc f() { _, _ = rtmps.Dial(nil, rtmps.ValidatedDestination{}, \"\", rtmps.Config{}) }\n", []string{"call"}},
		{"rtmps.Validate（別のファイル）", sessionRules(), "session.go", "package p\nimport \"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps\"\nfunc f() { _, _ = rtmps.Validate(\"\", rtmps.Policy{}) }\n", []string{"call"}},
		{"http.DefaultClient", backendRules(), "client.go", "package p\nimport \"net/http\"\nfunc f() { _ = http.DefaultClient }\n", []string{"call"}},
		{"http.Get", backendRules(), "client.go", "package p\nimport \"net/http\"\nfunc f() { _, _ = http.Get(\"x\") }\n", []string{"call"}},
		{"http.ProxyFromEnvironment", backendRules(), "client.go", "package p\nimport \"net/http\"\nfunc f() { _ = http.ProxyFromEnvironment }\n", []string{"call"}},
		{"fmt.Println", sessionRules(), "x.go", "package p\nimport \"fmt\"\nfunc f() { fmt.Println(1) }\n", []string{"call"}},
		{"fmt.Errorf・Sprintf は可", sessionRules(), "x.go", "package p\nimport \"fmt\"\nfunc f(x int) error { _ = fmt.Sprintf(\"%d\", x); return fmt.Errorf(\"x %d\", x) }\n", nil},
		{"InsecureSkipVerify", backendRules(), "client.go", "package p\nimport \"crypto/tls\"\nfunc f() *tls.Config { return &tls.Config{InsecureSkipVerify: true} }\n", []string{"tls"}},
		{"reveal を別のファイルで呼ぶ", backendRules(), "events.go", "package p\ntype k string\nfunc (k) reveal() string { return \"\" }\nfunc f(x k) string { return x.reveal() }\n", []string{"secret"}},
		{"reveal を client.go で呼ぶ", backendRules(), "client.go", "package p\ntype k string\nfunc (k) reveal() string { return \"\" }\nfunc f(x k) string { return x.reveal() }\n", nil},
		{"パッケージレベルの var", sessionRules(), "x.go", "package p\nvar counter = 0\n", []string{"global"}},
		{"init 関数", sessionRules(), "x.go", "package p\nfunc init() {}\n", []string{"global"}},
		{"確認用の blank の var は可", sessionRules(), "x.go", "package p\ntype i interface{}\ntype t struct{}\nvar _ i = (*t)(nil)\n", nil},
		{"日本語の文字列リテラル", sessionRules(), "x.go", "package p\nconst message = \"配信を開始します\"\n", []string{"literal"}},
		{"ASCII の文字列は可", sessionRules(), "x.go", "package p\nconst code = \"too_large\"\n", nil},
		{"ログに配信キー", sessionRules(), "x.go", "package p\nimport \"log/slog\"\ntype s struct{ key string }\nfunc f(l *slog.Logger, x s) { l.Warn(\"m\", slog.String(\"k\", x.key)) }\n", []string{"log"}},
		{"ログに取り込み先", sessionRules(), "x.go", "package p\nimport \"log/slog\"\nfunc f(l *slog.Logger, ingestURL string) { l.Info(\"m\", slog.String(\"u\", ingestURL)) }\n", []string{"log"}},
		{"ログにチケット", backendRules(), "x.go", "package p\nimport \"log/slog\"\nfunc f(l *slog.Logger, ticket string) { l.Error(\"m\", \"t\", ticket) }\n", []string{"log"}},
		{"ログに視聴 URL", sessionRules(), "x.go", "package p\nimport \"log/slog\"\ntype s struct{ watchURL string }\nfunc f(l *slog.Logger, x s) { l.Info(\"m\", \"u\", x.watchURL) }\n", []string{"log"}},
		{"ログにエラーの文言", sessionRules(), "x.go", "package p\nimport \"log/slog\"\nfunc f(l *slog.Logger, err error) { l.Warn(\"m\", slog.String(\"e\", err.Error())) }\n", []string{"log"}},
		{"ログに分類は可", sessionRules(), "x.go", "package p\nimport \"log/slog\"\nfunc class(err error) string { return \"x\" }\nfunc f(l *slog.Logger, err error, id string) { l.Warn(\"m\", slog.String(\"class\", class(err)), slog.String(\"broadcast_id\", id)) }\n", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := rulesOf(scanSource(t, c.rules, c.file, c.source).violations)
			if strings.Join(got, ",") != strings.Join(c.wantRules, ",") {
				t.Fatalf("rules = %v, want %v", got, c.wantRules)
			}
		})
	}
}

func TestScannerCountsRevealCalls(t *testing.T) {
	source := "package p\ntype k string\nfunc (k) reveal() string { return \"\" }\nfunc f(x k) (string, string) { return x.reveal(), x.reveal() }\n"
	if got := scanSource(t, backendRules(), "client.go", source).revealCalls; got != 2 {
		t.Fatalf("revealCalls = %d, want 2", got)
	}
}

// ---- 機密を持つ構造体の整形 ----
//
// fmt は、非公開の欄のメソッドを呼ばない。欄の型（Secret・Ticket・IngestURL・StreamKey）が、伏せる実装を持っていても、
// その欄を持つ構造体が Format を持たないと、%+v・%#v・log.Printf・slog.Any で、中身の文字列がそのまま出る。
// 公開の欄は、fmt が欄の型のメソッドを呼ぶので、この規則の対象外（欄の型が伏せる）。

// secretTypeNames は、中身が機密の型の名前（パッケージの修飾は外して比べる）。
func secretTypeNames() []string { return []string{"Secret", "Ticket", "IngestURL", "StreamKey"} }

// formatterMethods は、機密を非公開の欄に持つ構造体が、持つべき整形のメソッド（受け手は、値でもポインタでもよい）。
func formatterMethods() []string { return []string{"Format", "String", "GoString"} }

// typeFacts は、パッケージのソースから集めた、構造体の欄とメソッド。
type typeFacts struct {
	// structs は、構造体の型の名前。
	structs map[string]bool
	// secretFields は、機密を非公開の欄に持つ構造体（型の名前）→ その欄の名前。
	secretFields map[string][]string
	// methods は、型の名前 → メソッドの名前（受け手が値でもポインタでも）。
	methods map[string]map[string]bool
}

// baseTypeName は、型の式から、中心になる型の名前を取り出す（*T・[]T・map[K]T・pkg.T・T[X] の T）。
func baseTypeName(expr ast.Expr) string {
	switch typed := expr.(type) {
	case *ast.Ident:
		return typed.Name
	case *ast.StarExpr:
		return baseTypeName(typed.X)
	case *ast.ParenExpr:
		return baseTypeName(typed.X)
	case *ast.ArrayType:
		return baseTypeName(typed.Elt)
	case *ast.MapType:
		return baseTypeName(typed.Value)
	case *ast.SelectorExpr:
		return typed.Sel.Name
	case *ast.IndexExpr:
		return baseTypeName(typed.X)
	case *ast.IndexListExpr:
		return baseTypeName(typed.X)
	}
	return ""
}

func collectTypeFacts(files []*ast.File) typeFacts {
	facts := typeFacts{structs: map[string]bool{}, secretFields: map[string][]string{}, methods: map[string]map[string]bool{}}
	for _, file := range files {
		for _, declaration := range file.Decls {
			switch typed := declaration.(type) {
			case *ast.GenDecl:
				if typed.Tok != token.TYPE {
					continue
				}
				for _, spec := range typed.Specs {
					typeSpec := spec.(*ast.TypeSpec)
					structType, isStruct := typeSpec.Type.(*ast.StructType)
					if !isStruct {
						continue
					}
					facts.structs[typeSpec.Name.Name] = true
					for _, field := range structType.Fields.List {
						typeName := baseTypeName(field.Type)
						names := []string{typeName} // 型名だけの欄（埋め込み）は、型の名前が欄の名前
						if len(field.Names) > 0 {
							names = names[:0]
							for _, name := range field.Names {
								names = append(names, name.Name)
							}
						}
						for _, name := range names {
							if ast.IsExported(name) {
								continue
							}
							if contains(secretTypeNames(), typeName) || contains(secretNames(), name) {
								facts.secretFields[typeSpec.Name.Name] = append(facts.secretFields[typeSpec.Name.Name], name)
							}
						}
					}
				}
			case *ast.FuncDecl:
				if typed.Recv == nil || len(typed.Recv.List) == 0 {
					continue
				}
				receiver := baseTypeName(typed.Recv.List[0].Type)
				if facts.methods[receiver] == nil {
					facts.methods[receiver] = map[string]bool{}
				}
				facts.methods[receiver][typed.Name.Name] = true
			}
		}
	}
	return facts
}

// missingMethods は、型 name が持たない、want のメソッド。
func (f typeFacts) missingMethods(name string, want []string) []string {
	var missing []string
	for _, method := range want {
		if !f.methods[name][method] {
			missing = append(missing, method)
		}
	}
	return missing
}

// unprotectedSecretHolders は、機密を非公開の欄に持つ構造体のうち、整形のメソッドが足りないものを返す（"型: 足りないメソッド"）。
func (f typeFacts) unprotectedSecretHolders() []string {
	var problems []string
	for name, fields := range f.secretFields {
		if missing := f.missingMethods(name, formatterMethods()); len(missing) > 0 {
			problems = append(problems, fmt.Sprintf("%s (secret fields %v): no %s", name, fields, strings.Join(missing, ", ")))
		}
	}
	sort.Strings(problems)
	return problems
}

// missingRequired は、持つべき整形のメソッドを持たない、または見つからない型を返す。
// 走査の抜けで（型の名前の変更などで）、検査が黙って空振りにならないための、名指しの一覧。
func (f typeFacts) missingRequired(required map[string][]string) []string {
	var problems []string
	for name, methods := range required {
		if !f.structs[name] {
			problems = append(problems, fmt.Sprintf("%s: the struct was not found (the required formatting guard cannot be checked)", name))
			continue
		}
		if missing := f.missingMethods(name, methods); len(missing) > 0 {
			problems = append(problems, fmt.Sprintf("%s: no %s", name, strings.Join(missing, ", ")))
		}
	}
	sort.Strings(problems)
	return problems
}

func parseNonTestSources(t *testing.T, dir string) []*ast.File {
	t.Helper()
	fset := token.NewFileSet()
	var files []*ast.File
	for _, name := range nonTestSources(t, dir) {
		parsed, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatalf("cannot parse %s: %v", name, err)
		}
		files = append(files, parsed)
	}
	return files
}

func parseFactsSource(t *testing.T, source string) typeFacts {
	t.Helper()
	parsed, err := parser.ParseFile(token.NewFileSet(), "x.go", source, 0)
	if err != nil {
		t.Fatalf("cannot parse the sample source: %v", err)
	}
	return collectTypeFacts([]*ast.File{parsed})
}

// 機密を非公開の欄に持つ構造体が、整形のメソッドを持つこと。取り込みセッション・台帳・接続・内部通信クライアントは、名指しでも確かめる。
func TestStructsHoldingSecretsDefineFormatters(t *testing.T) {
	guard := []string{"Format", "String", "GoString"}
	packages := []struct {
		name     string
		dir      string
		required map[string][]string
	}{
		{"session", packageDir(t), map[string][]string{"IngestSession": guard, "Registry": guard, "Connection": guard}},
		// Client は、共有の秘密値を非公開の欄に持つ。値レシーバで、Client の値でも *Client でも効く。slog には LogValue で伏せた値を渡す
		{"backend", filepath.Join(packageDir(t), "..", "backend"), map[string][]string{"Client": append([]string{"LogValue"}, guard...)}},
	}
	for _, pkg := range packages {
		t.Run(pkg.name, func(t *testing.T) {
			facts := collectTypeFacts(parseNonTestSources(t, pkg.dir))
			if len(facts.structs) == 0 {
				t.Fatal("no struct was found; the check would pass vacuously")
			}
			for _, problem := range facts.unprotectedSecretHolders() {
				t.Errorf("a struct holds a secret in a non-exported field but cannot be formatted safely: %s", problem)
			}
			for _, problem := range facts.missingRequired(pkg.required) {
				t.Errorf("%s", problem)
			}
		})
	}
}

// 走査器が、整形のメソッドの無い構造体を見逃さず、そうでないものを誤検知しないこと。
func TestFormatterScannerFindsUnprotectedStructs(t *testing.T) {
	const methods = "\nfunc (c %[1]sc) Format(f fmt.State, r rune) {}\nfunc (c %[1]sc) String() string { return \"\" }\nfunc (c %[1]sc) GoString() string { return \"\" }\n"
	withAll := func(receiver string) string { return fmt.Sprintf(methods, receiver) }
	cases := []struct {
		name   string
		source string
		want   int // 見つかる構造体の数
	}{
		{"機密の型の非公開の欄で、メソッドなし", "package p\ntype c struct{ secret Secret }\n", 1},
		{"他のパッケージの機密の型", "package p\ntype c struct{ k rtmps.StreamKey }\n", 1},
		{"機密の型のスライス", "package p\ntype c struct{ tickets []backend.Ticket }\n", 1},
		{"名前が機密（型は string）", "package p\ntype c struct{ key string }\n", 1},
		{"値レシーバで 3 つとも持つ", "package p\ntype c struct{ secret Secret }" + withAll(""), 0},
		{"ポインタレシーバで 3 つとも持つ", "package p\ntype c struct{ secret Secret }" + withAll("*"), 0},
		{"Format だけ", "package p\ntype c struct{ secret Secret }\nfunc (c c) Format(f fmt.State, r rune) {}\n", 1},
		{"公開の欄は対象外（欄の型が伏せる）", "package p\ntype c struct{ Secret Secret }\n", 0},
		{"機密と無関係な欄", "package p\ntype c struct{ n int; name string }\n", 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := parseFactsSource(t, c.source).unprotectedSecretHolders()
			if len(got) != c.want {
				t.Fatalf("unprotected = %v, want %d", got, c.want)
			}
		})
	}

	facts := parseFactsSource(t, "package p\ntype c struct{ secret Secret }\nfunc (c c) Format(f fmt.State, r rune) {}\n")
	if got := facts.missingRequired(map[string][]string{"c": {"Format"}}); len(got) != 0 {
		t.Fatalf("missingRequired = %v, want none", got)
	}
	if got := facts.missingRequired(map[string][]string{"c": {"Format", "LogValue"}}); len(got) != 1 {
		t.Fatalf("missingRequired = %v, want the missing LogValue to be reported", got)
	}
	if got := facts.missingRequired(map[string][]string{"gone": {"Format"}}); len(got) != 1 {
		t.Fatalf("missingRequired = %v, want the missing struct to be reported", got)
	}
}

func packageDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot determine the test source location")
	}
	return filepath.Dir(file)
}

func nonTestSources(t *testing.T, root string) []string {
	t.Helper()
	var files []string
	err := filepath.WalkDir(root, func(current string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			if current != root {
				return filepath.SkipDir // このパッケージだけ（サブディレクトリは持たない）
			}
			return nil
		}
		if strings.HasSuffix(current, ".go") && !strings.HasSuffix(current, "_test.go") {
			files = append(files, current)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("cannot walk %s: %v", root, err)
	}
	sort.Strings(files)
	return files
}

func scanPackage(t *testing.T, rules ruleSet, dir string, mustScan []string) int {
	t.Helper()
	files := nonTestSources(t, dir)
	scanned := map[string]bool{}
	for _, file := range files {
		scanned[filepath.Base(file)] = true
	}
	for _, want := range mustScan { // 空振りの防止：主なソースが、走査の対象に入っている
		if !scanned[want] {
			t.Errorf("%s: %s is not scanned", rules.name, want)
		}
	}
	fset := token.NewFileSet()
	revealCalls := 0
	for _, file := range files {
		parsed, err := parser.ParseFile(fset, file, nil, 0)
		if err != nil {
			t.Fatalf("cannot parse %s: %v", file, err)
		}
		result := scanFile(rules, fset, parsed, filepath.Base(file))
		revealCalls += result.revealCalls
		for _, v := range result.violations {
			t.Error(v.String())
		}
	}
	return revealCalls
}

func TestSessionSourcesFollowTheRules(t *testing.T) {
	scanPackage(t, sessionRules(), packageDir(t), []string{
		"session.go", "session_input.go", "session_publish.go", "session_heartbeat.go", "session_close.go", "session_output.go",
		"connection.go", "registry.go", "factory.go", "clock.go", "protocol.go", "wire.go", "options.go", "interfaces.go", "errors.go",
	})
}

func TestBackendSourcesFollowTheRules(t *testing.T) {
	backendDir := filepath.Join(packageDir(t), "..", "backend")
	revealCalls := scanPackage(t, backendRules(), backendDir, []string{
		"client.go", "events.go", "types.go", "errors.go", "redact.go", "waiter.go",
	})
	// reveal() は、共有の秘密値（ヘッダ・検査）と接続チケット（照合の要求の本文）に使う、client.go の 3 か所だけ
	if revealCalls != 3 {
		t.Errorf("reveal() is called %d times, want exactly 3 (header, secret check, ticket)", revealCalls)
	}
	// リダイレクトを追わない規則が、client.go にある
	source, err := readFile(filepath.Join(backendDir, "client.go"))
	if err != nil {
		t.Fatalf("cannot read client.go: %v", err)
	}
	if !strings.Contains(source, "http.ErrUseLastResponse") {
		t.Error("client.go does not stop redirects (http.ErrUseLastResponse)")
	}
}

func readFile(file string) (string, error) {
	data, err := os.ReadFile(file)
	return string(data), err
}
