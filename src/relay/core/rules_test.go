package core

// Domain Core（src/relay/core/**）のソースの走査（requirements.md 2.5・15 章・27 章。CLAUDE.md の不変条件）。
//
//   - 入出力・実時計に依存しない：net・net/http・gorilla・gin・RTMP クライアント・os・log を参照しない。
//     time.Now などの実時計の読み取りを呼ばない（時刻は引数で受け取る）。標準出力・標準エラーへ書かない
//   - グローバル変数を持たない（パッケージレベルの var と init が無い）
//   - 利用者に表示する文字列を直書きしない（文字列リテラルに日本語などの非 ASCII を含めない。文言は文言カタログの側）
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

// violation は、走査で見つけた違反 1 件。
type violation struct {
	file   string
	line   int
	rule   string
	detail string
}

func (v violation) String() string {
	return fmt.Sprintf("%s:%d: [%s] %s", v.file, v.line, v.rule, v.detail)
}

// forbiddenImportPaths は、Domain Core が参照してはならない import のパス（完全一致）。
func forbiddenImportPaths() []string {
	return []string{"net", "os", "log", "log/slog", "math/rand", "math/rand/v2", "crypto/rand", "syscall", "plugin"}
}

// forbiddenImportPrefixes は、参照してはならない import のパスの前方一致（入出力・通信のライブラリ）。
func forbiddenImportPrefixes() []string {
	return []string{
		"net/", "os/", "log/",
		"github.com/gorilla/", "github.com/gin-gonic/", "github.com/yutopp/go-rtmp",
		"golang.org/x/net",
	}
}

// forbiddenCalls は、呼んではならない関数（パッケージのパス → 関数名）。実時計の読み取り・待機と、標準出力への書き込み。
func forbiddenCalls() map[string][]string {
	return map[string][]string{
		"time": {"Now", "Since", "Until", "Sleep", "After", "AfterFunc", "Tick", "NewTimer", "NewTicker"},
		"fmt":  {"Print", "Printf", "Println", "Fprint", "Fprintf", "Fprintln", "Scan", "Scanf", "Scanln", "Fscan", "Fscanf", "Fscanln"},
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

// isVersionElement は、パスの最後の要素が、版（v2・v10 など）かどうか。
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

// importLocalName は、import したパッケージを、そのファイルの中で呼ぶ名前（別名があれば別名、なければパスの最後の要素。
// 版の要素（math/rand/v2 の v2）は読み飛ばす）。
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

// scanFile は、1 つのソースの違反を返す。
func scanFile(fset *token.FileSet, file *ast.File, name string) []violation {
	var found []violation
	add := func(pos token.Pos, rule, detail string) {
		found = append(found, violation{file: name, line: fset.Position(pos).Line, rule: rule, detail: detail})
	}

	// import：入出力・乱数・通信のライブラリ
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
			add(spec.Pos(), "import", "imports "+importPath+" (a Domain Core must not depend on I/O, the clock, randomness or the network)")
		}
	}

	// 呼び出し：実時計・待機・標準出力
	ast.Inspect(file, func(node ast.Node) bool {
		selector, ok := node.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		ident, ok := selector.X.(*ast.Ident)
		if !ok {
			return true
		}
		importPath, isPackage := localToPath[ident.Name]
		if !isPackage || ident.Obj != nil {
			return true // import したパッケージではない（ローカルの変数・メソッドの呼び出し）
		}
		if containsString(forbiddenCalls()[importPath], selector.Sel.Name) {
			add(selector.Pos(), "call", importPath+"."+selector.Sel.Name+" is forbidden (pass the time in as an argument; do not read the clock or write to stdout)")
		}
		return true
	})

	// グローバル変数：パッケージレベルの var と init（_ への代入の確認用の宣言だけは、変数ではないので許す）
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

	// 文字列リテラル：非 ASCII（日本語の文言など）を直書きしない
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

func scanSource(t *testing.T, name, source string) []violation {
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
		source    string
		wantRules []string
	}{
		{"time.Now", "package p\nimport \"time\"\nfunc f() time.Time { return time.Now() }\n", []string{"call"}},
		{"別名を付けた time.Now", "package p\nimport clock \"time\"\nfunc f() { _ = clock.Now() }\n", []string{"call"}},
		{"time.Since", "package p\nimport \"time\"\nfunc f(a time.Time) { _ = time.Since(a) }\n", []string{"call"}},
		{"time.Until", "package p\nimport \"time\"\nfunc f(a time.Time) { _ = time.Until(a) }\n", []string{"call"}},
		{"time.Sleep", "package p\nimport \"time\"\nfunc f() { time.Sleep(1) }\n", []string{"call"}},
		{"time.After", "package p\nimport \"time\"\nfunc f() { <-time.After(1) }\n", []string{"call"}},
		{"time.NewTicker", "package p\nimport \"time\"\nfunc f() { _ = time.NewTicker(1) }\n", []string{"call"}},
		{"fmt.Println", "package p\nimport \"fmt\"\nfunc f() { fmt.Println(1) }\n", []string{"call"}},
		{"fmt.Fprintf", "package p\nimport \"fmt\"\nimport \"io\"\nfunc f(w io.Writer) { fmt.Fprintf(w, \"x\") }\n", []string{"call"}},
		{"net の import", "package p\nimport \"net\"\nvar _ net.Conn\n", []string{"import"}},
		{"net/http の import", "package p\nimport \"net/http\"\nvar _ http.Handler\n", []string{"import"}},
		{"gorilla の import", "package p\nimport _ \"github.com/gorilla/websocket\"\n", []string{"import"}},
		{"gin の import", "package p\nimport _ \"github.com/gin-gonic/gin\"\n", []string{"import"}},
		{"go-rtmp の import", "package p\nimport _ \"github.com/yutopp/go-rtmp\"\n", []string{"import"}},
		{"os の import", "package p\nimport _ \"os\"\n", []string{"import"}},
		{"log の import", "package p\nimport _ \"log\"\n", []string{"import"}},
		{"log/slog の import", "package p\nimport _ \"log/slog\"\n", []string{"import"}},
		{"math/rand の import", "package p\nimport _ \"math/rand\"\n", []string{"import"}},
		{"math/rand/v2 の import", "package p\nimport _ \"math/rand/v2\"\n", []string{"import"}},
		{"パッケージレベルの var", "package p\nvar counter = 0\n", []string{"global"}},
		{"var のまとまり", "package p\nvar (\n\ta = 1\n\tb = 2\n)\n", []string{"global", "global"}},
		{"init 関数", "package p\nfunc init() {}\n", []string{"global"}},
		{"日本語の文字列リテラル", "package p\nconst message = \"配信を開始します\"\n", []string{"literal"}},
		{"日本語のルーン", "package p\nconst r = 'あ'\n", []string{"literal"}},
		{"複数の違反", "package p\nimport \"time\"\nvar x = time.Now()\n", []string{"call", "global"}},

		// 違反ではないもの
		{"time の型と演算は可", "package p\nimport \"time\"\nfunc f(a, b time.Time) time.Duration { return b.Sub(a) + 5*time.Second }\n", nil},
		{"ローカルの Now メソッドは可", "package p\ntype c struct{}\nfunc (c) Now() int { return 1 }\nfunc f(x c) int { return x.Now() }\n", nil},
		{"time という名前のローカル変数は、パッケージではない（import を隠す）", "package p\nimport \"time\"\ntype clock struct{}\nfunc (clock) Now() int { return 1 }\nfunc f() int { time := clock{}; return time.Now() }\n", nil},
		{"fmt.Sprintf・fmt.Errorf は可（書き込まない）", "package p\nimport \"fmt\"\nfunc f(x int) error { _ = fmt.Sprintf(\"%d\", x); return fmt.Errorf(\"x %d\", x) }\n", nil},
		{"ASCII の文字列は可", "package p\nconst code = \"too_large\"\n", nil},
		{"定数は可", "package p\nconst (\n\ta = 1\n\tb = \"x\"\n)\n", nil},
		{"_ への代入の確認用の宣言は可", "package p\ntype i interface{}\ntype t struct{}\nvar _ i = (*t)(nil)\n", nil},
		{"関数の中の var は可", "package p\nfunc f() int { var n int; n++; return n }\n", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := rulesOf(scanSource(t, "sample.go", c.source))
			if strings.Join(got, ",") != strings.Join(c.wantRules, ",") {
				t.Fatalf("rules = %v, want %v", got, c.wantRules)
			}
		})
	}
}

// coreDir は、このテストのあるディレクトリ（src/relay/core）。
func coreDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot determine the test source location")
	}
	return filepath.Dir(file)
}

// sourceFiles は、core の下の、テスト以外の Go のソース（testdata は除く）を返す。
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

func TestCoreSourcesFollowTheDomainCoreRules(t *testing.T) {
	root := coreDir(t)
	files := sourceFiles(t, root)

	// 空振りの防止：この issue のパッケージと、契約のパッケージが、走査の対象に入っている
	packages := map[string]bool{}
	for _, file := range files {
		relative, err := filepath.Rel(root, file)
		if err != nil {
			t.Fatal(err)
		}
		packages[filepath.Dir(relative)] = true
	}
	for _, want := range []string{"contract", "frame", "rebase", "policer", "probe", "watchdog", "buffer", "liveness"} {
		if !packages[want] {
			t.Errorf("package core/%s has no source file to scan", want)
		}
	}

	fset := token.NewFileSet()
	var all []violation
	for _, file := range files {
		parsed, err := parser.ParseFile(fset, file, nil, 0)
		if err != nil {
			t.Fatalf("cannot parse %s: %v", file, err)
		}
		relative, _ := filepath.Rel(root, file)
		all = append(all, scanFile(fset, parsed, filepath.ToSlash(relative))...)
	}
	for _, v := range all {
		t.Error(v.String())
	}
}
