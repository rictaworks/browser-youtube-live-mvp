package frame

// 共有テストベクタ（src/contracts/ws-frame-vectors.json）の読み込み。
//
// 契約のディレクトリを、/contracts・../contracts・../../contracts・このファイルから src/contracts へ上る相対パスの順に探し、
// 見つからなければ、探した場所を並べて失敗する（黙ってスキップしない）。

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

const (
	vectorsFileName = "ws-frame-vectors.json"
	markerFileName  = "enums.json"

	// relativeFromTestDir は、このテストのあるディレクトリ（src/relay/core/frame）から、src/contracts へ上る相対パス。
	relativeFromTestDir = "../../../contracts"

	receiverRelay   = "relay"
	receiverBrowser = "browser"
)

// candidateDirs は、契約のディレクトリの候補を、探す順に返す。同じ場所を指す候補は、最初の 1 つだけを残す。
func candidateDirs(cwd, testDir string) []string {
	candidates := []string{
		"/contracts",
		filepath.Join(cwd, "../contracts"),
		filepath.Join(cwd, "../../contracts"),
		filepath.Join(testDir, relativeFromTestDir),
	}
	seen := make(map[string]bool, len(candidates))
	unique := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		cleaned := filepath.Clean(candidate)
		if !seen[cleaned] {
			seen[cleaned] = true
			unique = append(unique, cleaned)
		}
	}
	return unique
}

// locateContractsDir は、候補を順に探し、最初に見つかったディレクトリを返す。
// 1 つも無ければ、探した場所を並べたエラーを返す（黙ってスキップしない）。
func locateContractsDir(candidates []string, markerExists func(dir string) bool) (string, error) {
	for _, dir := range candidates {
		if markerExists(dir) {
			return dir, nil
		}
	}
	lines := make([]string, 0, len(candidates))
	for _, dir := range candidates {
		lines = append(lines, fmt.Sprintf("  - %s (no %s)", dir, markerFileName))
	}
	return "", fmt.Errorf("%s", strings.Join([]string{
		"contracts directory (src/contracts) not found; failing instead of skipping silently.",
		"searched (in this order):",
		strings.Join(lines, "\n"),
		"hint: run through scripts/test_relay.sh (docker compose mounts it read-only at /contracts).",
	}, "\n"))
}

func testSourceDir(tb testing.TB) string {
	tb.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		tb.Fatal("cannot determine the test source location")
	}
	return filepath.Dir(file)
}

func contractsDir(tb testing.TB) string {
	tb.Helper()
	cwd, err := os.Getwd()
	if err != nil {
		tb.Fatalf("cannot get the working directory: %v", err)
	}
	dir, err := locateContractsDir(candidateDirs(cwd, testSourceDir(tb)), func(dir string) bool {
		_, statErr := os.Stat(filepath.Join(dir, markerFileName))
		return statErr == nil
	})
	if err != nil {
		tb.Fatal(err)
	}
	return dir
}

// decodedVector は、ベクタの decoded 欄。timestamp_us は 10 進数の文字列（JSON の数値は 2^53 を超えると厳密に表せない）。
type decodedVector struct {
	Type        string `json:"type"`
	TypeCode    int    `json:"type_code"`
	Keyframe    bool   `json:"keyframe"`
	TimestampUs string `json:"timestamp_us"`
	BodyHex     string `json:"body_hex"`
}

type validVector struct {
	Name       string        `json:"name"`
	Direction  string        `json:"direction"`
	Hex        string        `json:"hex"`
	Decoded    decodedVector `json:"decoded"`
	DecodeOnly bool          `json:"decode_only"`
}

type invalidVector struct {
	Name      string   `json:"name"`
	Receivers []string `json:"receivers"`
	Hex       string   `json:"hex"`
	Error     string   `json:"error"`
}

type vectorFile struct {
	Valid   []validVector   `json:"valid"`
	Invalid []invalidVector `json:"invalid"`
}

// loadVectors は、共有テストベクタを読む。読めない・空なら、テストを失敗させる。
func loadVectors(tb testing.TB) vectorFile {
	tb.Helper()
	path := filepath.Join(contractsDir(tb), vectorsFileName)
	data, err := os.ReadFile(path)
	if err != nil {
		tb.Fatalf("cannot read %s: %v", path, err)
	}
	var vectors vectorFile
	if err := json.Unmarshal(data, &vectors); err != nil {
		tb.Fatalf("%s is not valid JSON: %v", path, err)
	}
	if len(vectors.Valid) == 0 || len(vectors.Invalid) == 0 {
		tb.Fatalf("%s has no vectors (valid=%d invalid=%d)", path, len(vectors.Valid), len(vectors.Invalid))
	}
	return vectors
}

func mustHex(tb testing.TB, text string) []byte {
	tb.Helper()
	data, err := hex.DecodeString(text)
	if err != nil {
		tb.Fatalf("invalid hex %q: %v", text, err)
	}
	return data
}

// wantFrame は、ベクタの decoded 欄から、期待する Frame を作る。
func (v validVector) wantFrame(tb testing.TB) Frame {
	tb.Helper()
	timestamp, err := strconv.ParseUint(v.Decoded.TimestampUs, 10, 64)
	if err != nil {
		tb.Fatalf("%s: timestamp_us %q is not a uint64: %v", v.Name, v.Decoded.TimestampUs, err)
	}
	if v.Decoded.TypeCode < 0 || v.Decoded.TypeCode > 0xFF {
		tb.Fatalf("%s: type_code %d does not fit in a byte", v.Name, v.Decoded.TypeCode)
	}
	return Frame{
		Type:        contract.FrameType(v.Decoded.TypeCode),
		Keyframe:    v.Decoded.Keyframe,
		TimestampUs: timestamp,
		Body:        mustHex(tb, v.Decoded.BodyHex),
	}
}

// receiverAccepts は、ベクタの受信側（relay・browser）が受理する方向を返す。
func receiverAccepts(tb testing.TB, receiver string) contract.FrameDirection {
	tb.Helper()
	switch receiver {
	case receiverRelay:
		return contract.FrameDirectionBrowserToRelay
	case receiverBrowser:
		return contract.FrameDirectionRelayToBrowser
	}
	tb.Fatalf("unknown receiver %q in the vectors", receiver)
	return ""
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func TestLocateContractsDirFailsWhenMissing(t *testing.T) {
	candidates := []string{"/contracts", "/x/contracts", "/y/contracts"}

	t.Run("目印が無ければ、探した場所をすべて並べて失敗する", func(t *testing.T) {
		_, err := locateContractsDir(candidates, func(string) bool { return false })
		if err == nil {
			t.Fatal("err = nil, want a failure (never skip silently)")
		}
		for _, dir := range candidates {
			if !strings.Contains(err.Error(), dir) {
				t.Errorf("error does not list %s: %v", dir, err)
			}
		}
	})

	t.Run("最初に見つかった場所を返す", func(t *testing.T) {
		got, err := locateContractsDir(candidates, func(dir string) bool { return dir != "/contracts" })
		if err != nil || got != "/x/contracts" {
			t.Fatalf("got (%q, %v), want (/x/contracts, nil)", got, err)
		}
	})

	t.Run("実際の契約のディレクトリが見つかる", func(t *testing.T) {
		if dir := contractsDir(t); dir == "" {
			t.Fatal("empty contracts dir")
		}
	})
}
