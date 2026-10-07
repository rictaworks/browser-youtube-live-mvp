package flv

// internal/flv のソースの走査（requirements.md 11.1・11.10・27 章。CLAUDE.md の不変条件）。
//
//   - 容器の詰め替えだけを行う：ネットワーク・ファイル・ログ・実時計・乱数・RTMP の通信を参照しない。標準出力へ書かない
//     （メディアを保存せず、符号化データに触れない。時刻は、このパッケージの外が扱う）
//   - ほかの層（core・internal の別のパッケージ）を参照しない
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

const modulePrefix = "github.com/rictaworks/browser-youtube-live-mvp/relay/"

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
	return []string{"net", "os", "io/ioutil", "log", "log/slog", "time", "math/rand", "math/rand/v2", "crypto/rand", "syscall", "plugin", "unsafe"}
}

func forbiddenImportPrefixes() []string {
	return []string{"net/", "os/", "log/", "github.com/gorilla/", "github.com/gin-gonic/", "github.com/yutopp/go-rtmp", "golang.org/x/net"}
}

func forbiddenCalls() map[string][]string {
	return map[string][]string{
		"fmt": {"Print", "Printf", "Println", "Fprint", "Fprintf", "Fprintln", "Scan", "Scanf", "Scanln", "Fscan", "Fscanf", "Fscanln"},
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

func scanFile(fset *token.FileSet, file *ast.File, name string) []violation {
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
		forbidden := containsString(forbiddenImportPaths(), importPath)
		for _, prefix := range forbiddenImportPrefixes() {
			if strings.HasPrefix(importPath, prefix) {
				forbidden = true
			}
		}
		if forbidden {
			add(spec.Pos(), "import", "imports "+importPath+" (the FLV muxer must not depend on I/O, the clock, randomness, the network or RTMP)")
		}
		if strings.HasPrefix(importPath, modulePrefix) {
			add(spec.Pos(), "import", "imports "+importPath+" (the FLV muxer must not depend on other layers of the relay)")
		}
	}

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
			return true
		}
		if containsString(forbiddenCalls()[importPath], selector.Sel.Name) {
			add(selector.Pos(), "call", importPath+"."+selector.Sel.Name+" is forbidden (do not write to stdout)")
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
		{"net の import", "package p\nimport \"net\"\nvar _ net.Conn\n", []string{"import"}},
		{"net/http の import", "package p\nimport \"net/http\"\nvar _ http.Handler\n", []string{"import"}},
		{"os の import", "package p\nimport _ \"os\"\n", []string{"import"}},
		{"os/exec の import", "package p\nimport _ \"os/exec\"\n", []string{"import"}},
		{"io/ioutil の import", "package p\nimport _ \"io/ioutil\"\n", []string{"import"}},
		{"log の import", "package p\nimport _ \"log\"\n", []string{"import"}},
		{"log/slog の import", "package p\nimport _ \"log/slog\"\n", []string{"import"}},
		{"time の import（時刻を扱わない）", "package p\nimport _ \"time\"\n", []string{"import"}},
		{"math/rand の import", "package p\nimport _ \"math/rand\"\n", []string{"import"}},
		{"crypto/rand の import", "package p\nimport _ \"crypto/rand\"\n", []string{"import"}},
		{"syscall の import", "package p\nimport _ \"syscall\"\n", []string{"import"}},
		{"unsafe の import", "package p\nimport _ \"unsafe\"\n", []string{"import"}},
		{"go-rtmp の import", "package p\nimport _ \"github.com/yutopp/go-rtmp\"\n", []string{"import"}},
		{"go-rtmp/message の import", "package p\nimport _ \"github.com/yutopp/go-rtmp/message\"\n", []string{"import"}},
		{"gin の import", "package p\nimport _ \"github.com/gin-gonic/gin\"\n", []string{"import"}},
		{"gorilla の import", "package p\nimport _ \"github.com/gorilla/websocket\"\n", []string{"import"}},
		{"ほかの層（core）の import", "package p\nimport _ \"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract\"\n", []string{"import"}},
		{"ほかの層（internal）の import", "package p\nimport _ \"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps\"\n", []string{"import"}},
		{"fmt.Println", "package p\nimport \"fmt\"\nfunc f() { fmt.Println(1) }\n", []string{"call"}},
		{"fmt.Fprintf", "package p\nimport \"fmt\"\nimport \"io\"\nfunc f(w io.Writer) { fmt.Fprintf(w, \"x\") }\n", []string{"call"}},
		{"パッケージレベルの var", "package p\nvar counter = 0\n", []string{"global"}},
		{"var のまとまり", "package p\nvar (\n\ta = 1\n\tb = 2\n)\n", []string{"global", "global"}},
		{"init 関数", "package p\nfunc init() {}\n", []string{"global"}},
		{"日本語の文字列リテラル", "package p\nconst message = \"配信を開始します\"\n", []string{"literal"}},
		{"日本語のルーン", "package p\nconst r = 'あ'\n", []string{"literal"}},

		// 違反ではないもの
		{"fmt.Errorf・Sprintf は可", "package p\nimport \"fmt\"\nfunc f(x int) error { _ = fmt.Sprintf(\"%d\", x); return fmt.Errorf(\"x %d\", x) }\n", nil},
		{"標準の errors・bytes・sync・math・strings は可", "package p\nimport (\n\t\"bytes\"\n\t\"errors\"\n\t\"math\"\n\t\"strings\"\n\t\"sync\"\n)\nvar _ = errors.New\nvar _ = bytes.NewReader\nvar _ = math.MaxInt32\nvar _ = strings.Join\nvar _ sync.Mutex\n", nil},
		{"go-flv・go-amf0 は可", "package p\nimport _ \"github.com/yutopp/go-flv/tag\"\nimport _ \"github.com/yutopp/go-amf0\"\n", nil},
		{"ASCII の文字列は可", "package p\nconst code = \"too_large\"\n", nil},
		{"定数は可", "package p\nconst (\n\ta = 1\n\tb = \"x\"\n)\n", nil},
		{"_ への代入の確認用の宣言は可", "package p\ntype i interface{}\ntype t struct{}\nvar _ i = (*t)(nil)\n", nil},
		{"関数の中の var は可", "package p\nfunc f() int { var n int; n++; return n }\n", nil},
		{"fmt という名前のローカル変数は、パッケージではない", "package p\nimport \"fmt\"\ntype w struct{}\nfunc (w) Println() {}\nfunc f() { fmt := w{}; fmt.Println() }\nvar _ = fmt.Sprint\n", nil},
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

func TestFlvSourcesFollowTheRules(t *testing.T) {
	root := packageDir(t)
	files := sourceFiles(t, root)
	if len(files) == 0 {
		t.Fatalf("no source file to scan in %s", root)
	}
	fset := token.NewFileSet()
	for _, file := range files {
		parsed, err := parser.ParseFile(fset, file, nil, 0)
		if err != nil {
			t.Fatalf("cannot parse %s: %v", file, err)
		}
		relative, _ := filepath.Rel(root, file)
		for _, v := range scanFile(fset, parsed, filepath.ToSlash(relative)) {
			t.Error(v.String())
		}
	}
}
