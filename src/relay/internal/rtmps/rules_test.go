package rtmps

// internal/rtmps のソースの走査（requirements.md 6.1・10.1・28.1。CLAUDE.md の不変条件）。
//
//   - 平文の RTMP を使わない：go-rtmp の平文の Dial・DialWithDialer を呼ばない。rtmp:// の文字列を持たない。RTMPS の
//     DialWithTLSDialer だけを使う
//   - TLS の証明書の検証を、勝手に省略しない：InsecureSkipVerify は、dial.go の tlsConfigFor の中だけで、検証済みの送出先の
//     印（dest.skipTLSVerify）の値だけを入れる。skipTLSVerify に、真の定数を入れない（印は、PolicyFor が、契約の値から決める）
//   - 配信キーを出さない：reveal()（配信キーの中身を得る呼び出し）は、dial.go の publish の呼び出しに、1 回だけ
//   - メディア・配信キーをファイルへ保存しない：os・ioutil を参照しない。標準出力へ書かない。ほかの層（セッション・サーバー）を参照しない
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
	"path"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"testing"
)

const (
	scanModulePrefix = "github.com/rictaworks/browser-youtube-live-mvp/relay/"
	goRTMPImportPath = "github.com/yutopp/go-rtmp"
)

type violation struct {
	file   string
	line   int
	rule   string
	detail string
}

func (v violation) String() string {
	return fmt.Sprintf("%s:%d: [%s] %s", v.file, v.line, v.rule, v.detail)
}

func forbiddenImportPaths() []string {
	return []string{"os", "io/ioutil", "log", "net/http", "database/sql", "math/rand", "math/rand/v2", "crypto/rand", "plugin", "unsafe"}
}

func forbiddenImportPrefixes() []string {
	return []string{"os/", "net/http/", "github.com/gorilla/", "github.com/gin-gonic/", "golang.org/x/net"}
}

// allowedModuleImports は、このパッケージが参照してよい、中継の別のパッケージ（core は契約の定数だけ。環境の判定）。
func allowedModuleImports() []string {
	return []string{"core/contract", "internal/appenv"}
}

func forbiddenCalls() map[string][]string {
	return map[string][]string{
		"fmt":            {"Print", "Printf", "Println", "Fprint", "Fprintf", "Fprintln", "Scan", "Scanf", "Scanln", "Fscan", "Fscanf", "Fscanln"},
		goRTMPImportPath: {"Dial", "DialWithDialer"}, // 平文の接続
	}
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

// fileScan は、1 つのソースの走査結果。
type fileScan struct {
	violations  []violation
	revealCalls int
}

func scanFile(fset *token.FileSet, file *ast.File, name string) fileScan {
	var result fileScan
	add := func(pos token.Pos, rule, detail string) {
		result.violations = append(result.violations, violation{file: name, line: fset.Position(pos).Line, rule: rule, detail: detail})
	}

	// import
	localToPath := map[string]string{}
	for _, spec := range file.Imports {
		importPath, err := strconv.Unquote(spec.Path.Value)
		if err != nil {
			add(spec.Pos(), "import", "cannot read the import path "+spec.Path.Value)
			continue
		}
		localToPath[importLocalName(spec, importPath)] = importPath
		forbidden := containsString(forbiddenImportPaths(), importPath)
		for _, prefix := range forbiddenImportPrefixes() {
			if strings.HasPrefix(importPath, prefix) {
				forbidden = true
			}
		}
		if forbidden {
			add(spec.Pos(), "import", "imports "+importPath+" (no files, no HTTP, no randomness, no other logger)")
		}
		if strings.HasPrefix(importPath, scanModulePrefix) {
			relative := strings.TrimPrefix(importPath, scanModulePrefix)
			if !containsString(allowedModuleImports(), relative) {
				add(spec.Pos(), "import", "imports "+importPath+" (this package may use only "+strings.Join(allowedModuleImports(), " and ")+")")
			}
		}
	}

	// 呼び出し（標準出力・平文の接続）と、reveal の呼び出し
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
			if containsString(forbiddenCalls()[importPath], typed.Sel.Name) {
				add(typed.Pos(), "call", importPath+"."+typed.Sel.Name+" is forbidden (write to no stdout; never connect without TLS)")
			}
		case *ast.CallExpr:
			if selector, ok := typed.Fun.(*ast.SelectorExpr); ok && selector.Sel.Name == "reveal" {
				result.revealCalls++
				if name != "dial.go" {
					add(typed.Pos(), "key", "reveal() is called outside dial.go (the stream key must be used only to publish)")
				}
			}
		}
		return true
	})

	// グローバル変数
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

	// 文字列リテラル：非 ASCII を直書きしない。平文のスキームを持たない
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
		if literal.Kind == token.STRING && (value == "rtmp" || strings.HasPrefix(value, "rtmp:") || strings.HasPrefix(value, "rtmpe") || strings.HasPrefix(value, "rtmpt")) {
			add(literal.Pos(), "plaintext", "the plaintext scheme "+literal.Value+" must not appear (RTMPS only)")
		}
		return true
	})

	// TLS の検証：InsecureSkipVerify・skipTLSVerify の置き場と値
	ast.Inspect(file, func(node ast.Node) bool {
		pair, ok := node.(*ast.KeyValueExpr)
		if !ok {
			return true
		}
		key, ok := pair.Key.(*ast.Ident)
		if !ok {
			return true
		}
		switch key.Name {
		case "InsecureSkipVerify":
			if name != "dial.go" {
				add(pair.Pos(), "tls", "InsecureSkipVerify may be set only in dial.go (tlsConfigFor)")
			}
			selector, isSelector := pair.Value.(*ast.SelectorExpr)
			if !isSelector || selector.Sel.Name != "skipTLSVerify" {
				add(pair.Pos(), "tls", "InsecureSkipVerify must take only the destination's skipTLSVerify mark")
			}
		case "skipTLSVerify":
			if ident, isIdent := pair.Value.(*ast.Ident); isIdent && (ident.Name == "true" || ident.Name == "false") {
				add(pair.Pos(), "tls", "skipTLSVerify must come from the contract (PolicyFor) or a validated destination, not a constant")
			}
		}
		return true
	})
	return result
}

func scanSource(t *testing.T, name, source string) fileScan {
	t.Helper()
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, name, source, 0)
	if err != nil {
		t.Fatalf("cannot parse the sample source %s: %v", name, err)
	}
	return scanFile(fset, file, name)
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
		file      string
		source    string
		wantRules []string
	}{
		{"os の import", "x.go", "package p\nimport _ \"os\"\n", []string{"import"}},
		{"os/exec の import", "x.go", "package p\nimport _ \"os/exec\"\n", []string{"import"}},
		{"io/ioutil の import", "x.go", "package p\nimport _ \"io/ioutil\"\n", []string{"import"}},
		{"log の import", "x.go", "package p\nimport _ \"log\"\n", []string{"import"}},
		{"net/http の import", "x.go", "package p\nimport _ \"net/http\"\n", []string{"import"}},
		{"math/rand の import", "x.go", "package p\nimport _ \"math/rand\"\n", []string{"import"}},
		{"gin の import", "x.go", "package p\nimport _ \"github.com/gin-gonic/gin\"\n", []string{"import"}},
		{"gorilla の import", "x.go", "package p\nimport _ \"github.com/gorilla/websocket\"\n", []string{"import"}},
		{"flv（別の層）の import", "x.go", "package p\nimport _ \"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/flv\"\n", []string{"import"}},
		{"セッション（別の層）の import", "x.go", "package p\nimport _ \"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/session\"\n", []string{"import"}},
		{"core/frame（契約以外の core）の import", "x.go", "package p\nimport _ \"github.com/rictaworks/browser-youtube-live-mvp/relay/core/frame\"\n", []string{"import"}},
		{"平文の Dial", "x.go", "package p\nimport rtmp \"github.com/yutopp/go-rtmp\"\nfunc f() { _, _ = rtmp.Dial(\"rtmp\", \"x\", nil) }\n", []string{"call", "plaintext"}},
		{"平文の DialWithDialer", "x.go", "package p\nimport rtmp \"github.com/yutopp/go-rtmp\"\nfunc f() { _, _ = rtmp.DialWithDialer(nil, \"p\", \"x\", nil) }\n", []string{"call"}},
		{"rtmp:// の文字列", "x.go", "package p\nconst u = \"rtmp://example.com/live\"\n", []string{"plaintext"}},
		{"rtmp だけの文字列", "x.go", "package p\nconst scheme = \"rtmp\"\n", []string{"plaintext"}},
		{"rtmpe の文字列", "x.go", "package p\nconst scheme = \"rtmpe://x\"\n", []string{"plaintext"}},
		{"fmt.Println", "x.go", "package p\nimport \"fmt\"\nfunc f() { fmt.Println(1) }\n", []string{"call"}},
		{"fmt.Fprintf", "x.go", "package p\nimport \"fmt\"\nimport \"io\"\nfunc f(w io.Writer) { fmt.Fprintf(w, \"x\") }\n", []string{"call"}},
		{"パッケージレベルの var", "x.go", "package p\nvar counter = 0\n", []string{"global"}},
		{"init 関数", "x.go", "package p\nfunc init() {}\n", []string{"global"}},
		{"日本語の文字列リテラル", "x.go", "package p\nconst message = \"配信を開始します\"\n", []string{"literal"}},
		{"InsecureSkipVerify を別のファイルで設定", "x.go", "package p\nimport \"crypto/tls\"\nfunc f(d struct{ skipTLSVerify bool }) *tls.Config { return &tls.Config{InsecureSkipVerify: d.skipTLSVerify} }\n", []string{"tls"}},
		{"InsecureSkipVerify に真を入れる", "dial.go", "package p\nimport \"crypto/tls\"\nfunc f() *tls.Config { return &tls.Config{InsecureSkipVerify: true} }\n", []string{"tls"}},
		{"InsecureSkipVerify に、送出先の印以外を入れる", "dial.go", "package p\nimport \"crypto/tls\"\nfunc f(skip bool) *tls.Config { return &tls.Config{InsecureSkipVerify: skip} }\n", []string{"tls"}},
		{"skipTLSVerify に真の定数", "destination.go", "package p\ntype t struct{ skipTLSVerify bool }\nfunc f() t { return t{skipTLSVerify: true} }\n", []string{"tls"}},
		{"skipTLSVerify に偽の定数", "destination.go", "package p\ntype t struct{ skipTLSVerify bool }\nfunc f() t { return t{skipTLSVerify: false} }\n", []string{"tls"}},
		{"reveal を別のファイルで呼ぶ", "publisher.go", "package p\ntype k string\nfunc (k) reveal() string { return \"\" }\nfunc f(x k) string { return x.reveal() }\n", []string{"key"}},

		// 違反ではないもの
		{"RTMPS の DialWithTLSDialer は可", "dial.go", "package p\nimport rtmp \"github.com/yutopp/go-rtmp\"\nfunc f() { _, _ = rtmp.DialWithTLSDialer(nil, \"rtmps\", \"x\", nil) }\n", nil},
		{"rtmps の文字列は可", "x.go", "package p\nconst scheme = \"rtmps\"\nconst u = \"rtmps://example.com:443/live2\"\nconst name = \"rtmps.Publisher\"\n", nil},
		{"契約の定数と appenv の import は可", "x.go", "package p\nimport _ \"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract\"\nimport _ \"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/appenv\"\n", nil},
		{"InsecureSkipVerify に送出先の印は可（dial.go）", "dial.go", "package p\nimport \"crypto/tls\"\nfunc f(dest struct{ skipTLSVerify bool }) *tls.Config { return &tls.Config{InsecureSkipVerify: dest.skipTLSVerify} }\n", nil},
		{"skipTLSVerify に式は可", "destination.go", "package p\ntype t struct{ skipTLSVerify bool }\nfunc f(a, b string) t { return t{skipTLSVerify: a == b} }\n", nil},
		{"reveal の呼び出しは、dial.go なら可", "dial.go", "package p\ntype k string\nfunc (k) reveal() string { return \"\" }\nfunc f(x k) string { return x.reveal() }\n", nil},
		{"fmt.Errorf・Sprintf は可", "x.go", "package p\nimport \"fmt\"\nfunc f(x int) error { _ = fmt.Sprintf(\"%d\", x); return fmt.Errorf(\"x %d\", x) }\n", nil},
		{"slog・crypto/tls・net は可", "x.go", "package p\nimport (\n\t\"crypto/tls\"\n\t\"log/slog\"\n\t\"net\"\n)\nvar _ = slog.New\nvar _ tls.Config\nvar _ net.Conn\n", nil},
		{"ASCII の文字列は可", "x.go", "package p\nconst code = \"too_large\"\n", nil},
		{"_ への代入の確認用の宣言は可", "x.go", "package p\ntype i interface{}\ntype t struct{}\nvar _ i = (*t)(nil)\n", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := rulesOf(scanSource(t, c.file, c.source).violations)
			if strings.Join(got, ",") != strings.Join(c.wantRules, ",") {
				t.Fatalf("rules = %v, want %v", got, c.wantRules)
			}
		})
	}
}

func TestScannerCountsRevealCalls(t *testing.T) {
	source := "package p\ntype k string\nfunc (k) reveal() string { return \"\" }\nfunc f(x k) (string, string) { return x.reveal(), x.reveal() }\n"
	if got := scanSource(t, "dial.go", source).revealCalls; got != 2 {
		t.Fatalf("revealCalls = %d, want 2", got)
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

func sourceFiles(t *testing.T, root string) []string {
	t.Helper()
	var files []string
	err := filepath.WalkDir(root, func(current string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			if entry.Name() == "testdata" {
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

func TestRtmpsSourcesFollowTheRules(t *testing.T) {
	root := packageDir(t)
	files := sourceFiles(t, root)

	// 空振りの防止：このパッケージの主なソースが、走査の対象に入っている
	scanned := map[string]bool{}
	for _, file := range files {
		scanned[filepath.Base(file)] = true
	}
	for _, want := range []string{"destination.go", "dial.go", "publisher.go", "streamkey.go", "sink_rtmp.go", "killswitch_unix.go", "config.go", "errors.go"} {
		if !scanned[want] {
			t.Errorf("%s is not scanned", want)
		}
	}

	fset := token.NewFileSet()
	revealCalls := 0
	for _, file := range files {
		parsed, err := parser.ParseFile(fset, file, nil, 0)
		if err != nil {
			t.Fatalf("cannot parse %s: %v", file, err)
		}
		result := scanFile(fset, parsed, filepath.Base(file))
		revealCalls += result.revealCalls
		for _, v := range result.violations {
			t.Error(v.String())
		}
	}
	if revealCalls != 1 {
		t.Errorf("reveal() is called %d times, want exactly once (the publish command)", revealCalls)
	}
}
