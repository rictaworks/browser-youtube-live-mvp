package wsapi

// internal/wsapi・internal/server・internal/config・main.go のソースの走査（requirements.md 6.1・27・28.1。CLAUDE.md の不変条件）。
//
// wsapi（WebSocket の受け口と送信）
//   - 実時計を直接使わない：time.Now・Sleep・After・AfterFunc・NewTimer・NewTicker・Tick・Since・Until と、context の期限を使わない。
//     ping・無通信・書き込み・切断の待ちは、注入された時計（session.Clock）のタイマーで数える
//   - 接続に、実時間の期限を設定しない：SetReadDeadline・SetWriteDeadline・SetDeadline を呼ばない。WriteControl の期限は、零値の
//     time.Time{}（期限は、時計のタイマーが持つ）
//   - SetReadLimit を使わない（超過した時点で、ライブラリが Close コード 1009 を送って終わり、致命通知 message_too_large を
//     先に送れない。自前で数える）。圧縮を有効にしない（EnableCompression。展開による膨張を避ける）
//   - 入出力に触れない：os・log・ファイル・標準出力・乱数を使わない（メディアをファイルへ保存しない）
//   - 接続元の Origin を検査しない旨と理由が、CheckOrigin のコメントにある
//   - 受信した内容（メッセージ・本文・データ）と、秘密値を、ログに渡さない。エラーの文言（.Error()）も渡さない
//
// server・config・main
//   - 送出先の許可リストを、本番のコードで作らない（rtmps.NewPolicy は試験だけ。本番の経路は PolicyFor）。TLS の検証を省略しない
//   - 環境変数を読むのは、main.go だけ（os.LookupEnv）。server・config は os を参照しない
//   - 秘密値をログに渡さない。エラーの文言（.Error()）も渡さない
//
// 共通
//   - グローバル変数を持たない（パッケージレベルの var と init が無い）
//   - 利用者に表示する文字列を直書きしない（文字列リテラルに日本語などの非 ASCII を含めない）
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

const rulesModulePrefix = "github.com/rictaworks/browser-youtube-live-mvp/relay/"

type ruleSet struct {
	name                    string
	allowedModuleImports    []string
	forbiddenImports        []string
	forbiddenImportPrefixes []string
	// fileOnlyCalls は、特定のファイルだけで呼んでよい関数（"パッケージ.関数" → ファイル名）
	fileOnlyCalls map[string]string
	// forbiddenCalls は、どのファイルでも呼ばない関数（"パッケージ.関数"）
	forbiddenCalls []string
	// forbiddenMethods は、どのファイルでも呼ばないメソッド（名前だけで判定する）
	forbiddenMethods []string
	// secretNames は、ログの引数に渡してはならない名前
	secretNames []string
	// zeroDeadlineControl が真なら、WriteControl の 3 番目の引数は、零値の time.Time{} に限る
	zeroDeadlineControl bool
}

func baseSecretNames() []string {
	return []string{"key", "streamKey", "StreamKey", "ingestURL", "IngestURL", "URL", "ticket", "Ticket", "secret", "Secret", "accountKey", "AccountKey", "watchURL", "WatchURL"}
}

func realTimeCalls() []string {
	return []string{"time.Now", "time.Sleep", "time.After", "time.AfterFunc", "time.NewTimer", "time.NewTicker", "time.Tick", "time.Since", "time.Until"}
}

func joined(lists ...[]string) []string {
	var out []string
	for _, list := range lists {
		out = append(out, list...)
	}
	return out
}

func printCalls() []string {
	return []string{"fmt.Print", "fmt.Printf", "fmt.Println", "fmt.Scan", "fmt.Scanf", "fmt.Scanln", "fmt.Fscan", "fmt.Fscanf", "fmt.Fscanln"}
}

func wsapiRuleSet() ruleSet {
	return ruleSet{
		name:                 "wsapi",
		allowedModuleImports: []string{"core/contract", "internal/session"},
		forbiddenImports:     []string{"os", "io/ioutil", "log", "database/sql", "math/rand", "math/rand/v2", "crypto/rand", "crypto/tls", "plugin", "unsafe"},
		forbiddenImportPrefixes: []string{
			"os/", "github.com/gin-gonic/", "github.com/yutopp/", "github.com/sirupsen/",
		},
		forbiddenCalls: joined(realTimeCalls(), printCalls(), []string{
			"fmt.Fprint", "fmt.Fprintf", "fmt.Fprintln", "rtmps.NewPolicy", "context.WithTimeout", "context.WithDeadline",
		}),
		forbiddenMethods:    []string{"SetReadLimit", "SetReadDeadline", "SetWriteDeadline", "SetDeadline", "EnableCompression"},
		secretNames:         joined(baseSecretNames(), []string{"message", "data", "body", "payload"}),
		zeroDeadlineControl: true,
	}
}

func serverRuleSet() ruleSet {
	return ruleSet{
		name: "server",
		allowedModuleImports: []string{
			"core/contract", "internal/appenv", "internal/backend", "internal/config", "internal/rtmps", "internal/session", "internal/wsapi",
		},
		forbiddenImports:        []string{"os", "io/ioutil", "database/sql", "math/rand", "math/rand/v2", "crypto/rand", "crypto/tls", "plugin", "unsafe"},
		forbiddenImportPrefixes: []string{"os/", "github.com/yutopp/"},
		forbiddenCalls:          joined(printCalls(), []string{"rtmps.NewPolicy", "http.DefaultClient", "http.Get", "http.Post"}),
		secretNames:             baseSecretNames(),
	}
}

func configRuleSet() ruleSet {
	return ruleSet{
		name:                    "config",
		allowedModuleImports:    []string{"internal/appenv", "internal/backend"},
		forbiddenImports:        []string{"os", "io/ioutil", "log", "net/http", "database/sql", "math/rand", "crypto/rand", "plugin", "unsafe"},
		forbiddenImportPrefixes: []string{"os/", "github.com/gin-gonic/", "github.com/gorilla/"},
		forbiddenCalls:          printCalls(),
		secretNames:             baseSecretNames(),
	}
}

func mainRuleSet() ruleSet {
	return ruleSet{
		name:                    "main",
		allowedModuleImports:    []string{"internal/appenv", "internal/config", "internal/server"},
		forbiddenImports:        []string{"io/ioutil", "log", "database/sql", "math/rand", "crypto/rand", "plugin", "unsafe"},
		forbiddenImportPrefixes: []string{"github.com/gorilla/", "github.com/yutopp/"},
		forbiddenCalls:          joined(printCalls(), []string{"rtmps.NewPolicy"}),
		secretNames:             baseSecretNames(),
	}
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

func containsString(values []string, want string) bool {
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
func scanLogArguments(rules ruleSet, call *ast.CallExpr, add func(pos token.Pos, rule, detail string)) {
	selectorNames := map[*ast.Ident]bool{}
	for _, arg := range call.Args {
		ast.Inspect(arg, func(node ast.Node) bool {
			switch typed := node.(type) {
			case *ast.Ident:
				if !selectorNames[typed] && containsString(rules.secretNames, typed.Name) {
					add(typed.Pos(), "log", "a log argument uses the name "+typed.Name+" (it may carry a secret or received content)")
				}
			case *ast.SelectorExpr:
				selectorNames[typed.Sel] = true
				if containsString(rules.secretNames, typed.Sel.Name) {
					add(typed.Pos(), "log", "a log argument uses the name "+typed.Sel.Name+" (it may carry a secret or received content)")
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

// isZeroTimeLiteral は、time.Time{} か。
func isZeroTimeLiteral(expr ast.Expr) bool {
	literal, ok := expr.(*ast.CompositeLit)
	if !ok || len(literal.Elts) != 0 {
		return false
	}
	selector, ok := literal.Type.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	pkg, ok := selector.X.(*ast.Ident)
	return ok && pkg.Name == "time" && selector.Sel.Name == "Time"
}

func scanRulesFile(rules ruleSet, fset *token.FileSet, file *ast.File, name string) []violation {
	var found []violation
	add := func(pos token.Pos, rule, detail string) {
		found = append(found, violation{file: name, line: fset.Position(pos).Line, rule: rule, detail: detail})
	}

	localToPath := map[string]string{}
	for _, spec := range file.Imports {
		importPath, err := strconv.Unquote(spec.Path.Value)
		if err != nil {
			add(spec.Pos(), "import", "cannot read the import path "+spec.Path.Value)
			continue
		}
		localToPath[importLocalName(spec, importPath)] = importPath
		forbidden := containsString(rules.forbiddenImports, importPath)
		for _, prefix := range rules.forbiddenImportPrefixes {
			if strings.HasPrefix(importPath, prefix) {
				forbidden = true
			}
		}
		if forbidden {
			add(spec.Pos(), "import", "imports "+importPath+" (not allowed in "+rules.name+")")
		}
		if strings.HasPrefix(importPath, rulesModulePrefix) {
			relative := strings.TrimPrefix(importPath, rulesModulePrefix)
			if !containsString(rules.allowedModuleImports, relative) {
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
			if allowedFile, restricted := rules.fileOnlyCalls[qualified]; restricted {
				if name != allowedFile {
					add(typed.Pos(), "call", qualified+" may be used only in "+allowedFile)
				}
			} else if containsString(rules.forbiddenCalls, qualified) {
				add(typed.Pos(), "call", qualified+" is forbidden in "+rules.name)
			}
		case *ast.CallExpr:
			if selector, ok := typed.Fun.(*ast.SelectorExpr); ok {
				if containsString(rules.forbiddenMethods, selector.Sel.Name) {
					add(typed.Pos(), "method", selector.Sel.Name+" is forbidden in "+rules.name)
				}
				if rules.zeroDeadlineControl && selector.Sel.Name == "WriteControl" && (len(typed.Args) != 3 || !isZeroTimeLiteral(typed.Args[2])) {
					add(typed.Pos(), "deadline", "WriteControl must take time.Time{} as its deadline (deadlines come from the clock timers)")
				}
			}
			if isLogCall(typed) {
				scanLogArguments(rules, typed, add)
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
	return found
}

func scanRulesSource(t *testing.T, rules ruleSet, name, source string) []violation {
	t.Helper()
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, name, source, 0)
	if err != nil {
		t.Fatalf("cannot parse the sample source %s: %v", name, err)
	}
	return scanRulesFile(rules, fset, file, name)
}

func ruleNames(violations []violation) []string {
	rules := make([]string, 0, len(violations))
	for _, v := range violations {
		rules = append(rules, v.rule)
	}
	sort.Strings(rules)
	return rules
}

// 走査器が、違反を見逃さず、違反でないものを誤検知しないこと。
func TestRulesScannerFindsViolations(t *testing.T) {
	cases := []struct {
		name      string
		rules     ruleSet
		file      string
		source    string
		wantRules []string
	}{
		{"os の import", wsapiRuleSet(), "x.go", "package p\nimport _ \"os\"\n", []string{"import"}},
		{"log の import", wsapiRuleSet(), "x.go", "package p\nimport _ \"log\"\n", []string{"import"}},
		{"gin の import（wsapi）", wsapiRuleSet(), "x.go", "package p\nimport _ \"github.com/gin-gonic/gin\"\n", []string{"import"}},
		{"gorilla の import（wsapi は可）", wsapiRuleSet(), "x.go", "package p\nimport _ \"github.com/gorilla/websocket\"\n", nil},
		{"別の層の import", wsapiRuleSet(), "x.go", "package p\nimport _ \"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend\"\n", []string{"import"}},
		{"session の import は可", wsapiRuleSet(), "x.go", "package p\nimport _ \"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/session\"\n", nil},
		{"time.Now", wsapiRuleSet(), "x.go", "package p\nimport \"time\"\nfunc f() { _ = time.Now() }\n", []string{"call"}},
		{"time.AfterFunc", wsapiRuleSet(), "x.go", "package p\nimport \"time\"\nfunc f() { _ = time.AfterFunc(1, func() {}) }\n", []string{"call"}},
		{"time.Duration は可", wsapiRuleSet(), "x.go", "package p\nimport \"time\"\nconst d = 2 * time.Second\nfunc f(x time.Duration) time.Duration { return x }\n", nil},
		{"time.Time{} は可", wsapiRuleSet(), "x.go", "package p\nimport \"time\"\nfunc f() time.Time { return time.Time{} }\n", nil},
		{"context.WithTimeout（wsapi）", wsapiRuleSet(), "x.go", "package p\nimport \"context\"\nfunc f() { _, _ = context.WithTimeout(context.Background(), 1) }\n", []string{"call"}},
		{"context.WithTimeout（server は可）", serverRuleSet(), "x.go", "package p\nimport \"context\"\nfunc f() { _, _ = context.WithTimeout(context.Background(), 1) }\n", nil},
		{"time.Until（server は可）", serverRuleSet(), "x.go", "package p\nimport \"time\"\nfunc f(t time.Time) { _ = time.Until(t) }\n", nil},
		{"SetReadLimit", wsapiRuleSet(), "x.go", "package p\ntype c struct{}\nfunc (c) SetReadLimit(int64) {}\nfunc f(x c) { x.SetReadLimit(1) }\n", []string{"method"}},
		{"SetReadDeadline", wsapiRuleSet(), "x.go", "package p\ntype c struct{}\nfunc (c) SetReadDeadline(int) {}\nfunc f(x c) { x.SetReadDeadline(1) }\n", []string{"method"}},
		{"SetWriteDeadline", wsapiRuleSet(), "x.go", "package p\ntype c struct{}\nfunc (c) SetWriteDeadline(int) {}\nfunc f(x c) { x.SetWriteDeadline(1) }\n", []string{"method"}},
		{"EnableCompression", wsapiRuleSet(), "x.go", "package p\ntype c struct{}\nfunc (c) EnableCompression(bool) {}\nfunc f(x c) { x.EnableCompression(true) }\n", []string{"method"}},
		{"WriteControl の期限が零値", wsapiRuleSet(), "x.go", "package p\nimport \"time\"\ntype c struct{}\nfunc (c) WriteControl(int, []byte, time.Time) error { return nil }\nfunc f(x c) { _ = x.WriteControl(9, nil, time.Time{}) }\n", nil},
		{"WriteControl の期限が零値ではない", wsapiRuleSet(), "x.go", "package p\nimport \"time\"\ntype c struct{}\nfunc (c) WriteControl(int, []byte, time.Time) error { return nil }\nfunc f(x c, d time.Time) { _ = x.WriteControl(9, nil, d) }\n", []string{"deadline"}},
		{"rtmps.NewPolicy", serverRuleSet(), "x.go", "package p\nimport \"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps\"\nfunc f() { _, _ = rtmps.NewPolicy() }\n", []string{"call"}},
		{"rtmps.PolicyFor は可", serverRuleSet(), "x.go", "package p\nimport \"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps\"\nfunc f() { _, _ = rtmps.PolicyFor(\"\") }\n", nil},
		{"InsecureSkipVerify", serverRuleSet(), "x.go", "package p\nimport \"crypto/tls\"\nfunc f() *tls.Config { return &tls.Config{InsecureSkipVerify: true} }\n", []string{"import", "tls"}},
		{"http.DefaultClient（server）", serverRuleSet(), "x.go", "package p\nimport \"net/http\"\nfunc f() { _ = http.DefaultClient }\n", []string{"call"}},
		{"fmt.Println", wsapiRuleSet(), "x.go", "package p\nimport \"fmt\"\nfunc f() { fmt.Println(1) }\n", []string{"call"}},
		{"fmt.Errorf・Sprintf は可", wsapiRuleSet(), "x.go", "package p\nimport \"fmt\"\nfunc f(x int) error { _ = fmt.Sprintf(\"%d\", x); return fmt.Errorf(\"x %d\", x) }\n", nil},
		{"パッケージレベルの var", wsapiRuleSet(), "x.go", "package p\nvar counter = 0\n", []string{"global"}},
		{"init 関数", wsapiRuleSet(), "x.go", "package p\nfunc init() {}\n", []string{"global"}},
		{"確認用の blank の var は可", wsapiRuleSet(), "x.go", "package p\ntype i interface{}\ntype t struct{}\nvar _ i = (*t)(nil)\n", nil},
		{"日本語の文字列リテラル", wsapiRuleSet(), "x.go", "package p\nconst message = \"配信を開始します\"\n", []string{"literal"}},
		{"ASCII の文字列は可", wsapiRuleSet(), "x.go", "package p\nconst code = \"too_large\"\n", nil},
		{"ログにチケット", wsapiRuleSet(), "x.go", "package p\nimport \"log/slog\"\nfunc f(l *slog.Logger, ticket string) { l.Info(\"m\", \"t\", ticket) }\n", []string{"log"}},
		{"ログに受信したメッセージ", wsapiRuleSet(), "x.go", "package p\nimport \"log/slog\"\nfunc f(l *slog.Logger, message []byte) { l.Info(\"m\", \"m\", message) }\n", []string{"log"}},
		{"ログに受信した本文", wsapiRuleSet(), "x.go", "package p\nimport \"log/slog\"\ntype m struct{ body []byte }\nfunc f(l *slog.Logger, x m) { l.Warn(\"m\", \"b\", x.body) }\n", []string{"log"}},
		{"ログにエラーの文言", wsapiRuleSet(), "x.go", "package p\nimport \"log/slog\"\nfunc f(l *slog.Logger, err error) { l.Warn(\"m\", slog.String(\"e\", err.Error())) }\n", []string{"log"}},
		{"ログに分類は可", wsapiRuleSet(), "x.go", "package p\nimport \"log/slog\"\nfunc f(l *slog.Logger, id string) { l.Warn(\"m\", slog.String(\"reason\", \"idle_timeout\"), slog.String(\"broadcast_id\", id)) }\n", nil},
		{"server は message をログに渡してよい（外部の記録の写し）", serverRuleSet(), "x.go", "package p\nimport \"log/slog\"\nfunc f(l *slog.Logger, message string) { l.Info(\"m\", slog.String(\"message\", message)) }\n", nil},
		{"config の net/http", configRuleSet(), "x.go", "package p\nimport _ \"net/http\"\n", []string{"import"}},
		{"main が環境変数を読むのは可", mainRuleSet(), "x.go", "package p\nimport \"os\"\nfunc f() { _, _ = os.LookupEnv(\"X\") }\n", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := ruleNames(scanRulesSource(t, c.rules, c.file, c.source))
			if strings.Join(got, ",") != strings.Join(c.wantRules, ",") {
				t.Fatalf("rules = %v, want %v", got, c.wantRules)
			}
		})
	}
}

func rulesPackageDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot determine the test source location")
	}
	return filepath.Dir(file)
}

func nonTestGoSources(t *testing.T, root string) []string {
	t.Helper()
	var files []string
	err := filepath.WalkDir(root, func(current string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			if current != root {
				return filepath.SkipDir
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

func scanRulesFiles(t *testing.T, rules ruleSet, files []string, mustScan []string) {
	t.Helper()
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
	for _, file := range files {
		parsed, err := parser.ParseFile(fset, file, nil, parser.ParseComments)
		if err != nil {
			t.Fatalf("cannot parse %s: %v", file, err)
		}
		for _, v := range scanRulesFile(rules, fset, parsed, filepath.Base(file)) {
			t.Error(v.String())
		}
	}
}

func TestWsapiSourcesFollowTheRules(t *testing.T) {
	dir := rulesPackageDir(t)
	scanRulesFiles(t, wsapiRuleSet(), nonTestGoSources(t, dir), []string{
		"doc.go", "errors.go", "options.go", "socket.go", "read.go", "link.go", "handler.go",
	})
}

func TestServerSourcesFollowTheRules(t *testing.T) {
	dir := filepath.Join(rulesPackageDir(t), "..", "server")
	scanRulesFiles(t, serverRuleSet(), nonTestGoSources(t, dir), []string{"server.go", "logging.go", "app.go", "errors.go", "thirdparty.go"})
}

func TestConfigSourcesFollowTheRules(t *testing.T) {
	dir := filepath.Join(rulesPackageDir(t), "..", "config")
	scanRulesFiles(t, configRuleSet(), nonTestGoSources(t, dir), []string{"config.go"})
}

func TestMainSourceFollowsTheRules(t *testing.T) {
	file := filepath.Join(rulesPackageDir(t), "..", "..", "main.go")
	scanRulesFiles(t, mainRuleSet(), []string{file}, []string{"main.go"})
}

// 接続元の Origin を検査しない旨と、その理由（Cookie を使わず、チケットで認可する）が、CheckOrigin の直前のコメントにある
// （セキュリティレビューで説明できるように。issue #21）
func TestCheckOriginIsExplicitAndExplained(t *testing.T) {
	source, err := os.ReadFile(filepath.Join(rulesPackageDir(t), "handler.go"))
	if err != nil {
		t.Fatalf("cannot read handler.go: %v", err)
	}
	lines := strings.Split(string(source), "\n")
	found := false
	for index, line := range lines {
		if !strings.Contains(line, "CheckOrigin:") {
			continue
		}
		found = true
		comment := strings.Join(lines[max(0, index-14):index], "\n")
		for _, want := range []string{"Origin", "Cookie", "チケット", "クロスサイト"} {
			if !strings.Contains(comment, want) {
				t.Errorf("the comment above CheckOrigin does not mention %q:\n%s", want, comment)
			}
		}
		if !strings.Contains(line, "return true") {
			t.Errorf("CheckOrigin must allow every origin explicitly: %s", line)
		}
	}
	if !found {
		t.Fatal("handler.go does not set CheckOrigin (the library default rejects other origins, so the browser could not connect)")
	}
}

// gorilla/websocket の既定（CheckOrigin が nil）に頼らない：Upgrader を作る箇所は 1 つで、CheckOrigin を持つ
func TestTheUpgraderIsBuiltInOnePlaceWithCheckOrigin(t *testing.T) {
	count := 0
	for _, file := range nonTestGoSources(t, rulesPackageDir(t)) {
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatalf("cannot read %s: %v", file, err)
		}
		count += strings.Count(string(data), "websocket.Upgrader{")
	}
	if count != 1 {
		t.Errorf("websocket.Upgrader{ appears %d times; want exactly once (in handler.go, with CheckOrigin)", count)
	}
}
