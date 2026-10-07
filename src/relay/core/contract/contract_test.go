package contract

// 契約（src/contracts）と、このパッケージの定数の一致。
//
// 契約のディレクトリを、/contracts・../contracts・../../contracts・このファイルから src/contracts へ上る相対パスの順に探し、
// 見つからなければ、探した場所を並べて失敗する（黙ってスキップしない）。
// JSON にあるものがパッケージに無い、パッケージにあるものが JSON に無い、のどちらも失敗する（両方向）。

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// markerFile は、契約のディレクトリの目印のファイル。
const markerFile = "enums.json"

// relativeFromTestDir は、このテストのあるディレクトリ（src/relay/core/contract）から、src/contracts へ上る相対パス。
const relativeFromTestDir = "../../../contracts"

// candidateDirs は、契約のディレクトリの候補を、探す順に返す。同じ場所を指す候補は、最初の 1 つだけを残す。
//  1. /contracts          docker compose のマウント（読み取り専用）
//  2. <cwd>/../contracts  CI のチェックアウト（作業ディレクトリが src/<層>）
//  3. <cwd>/../../contracts
//  4. このファイルから src/contracts へ上る相対パス（作業ディレクトリに依らない）
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
// 1 つも無ければ、探した場所を並べたエラーを返す。markerExists は、ファイルシステムを使わずに試すための差し替え口。
func locateContractsDir(candidates []string, markerExists func(dir string) bool) (string, error) {
	for _, dir := range candidates {
		if markerExists(dir) {
			return dir, nil
		}
	}
	lines := make([]string, 0, len(candidates))
	for _, dir := range candidates {
		lines = append(lines, fmt.Sprintf("  - %s（%s が無い）", dir, markerFile))
	}
	return "", fmt.Errorf("%s", strings.Join([]string{
		"契約のディレクトリ（src/contracts）が見つかりません。黙ってスキップせず、失敗します。",
		"探した場所（この順）:",
		strings.Join(lines, "\n"),
		"対処: docker compose の環境では scripts/test_relay.sh を使ってください（/contracts へ読み取り専用でマウントされます）。",
		"CI では、リポジトリをチェックアウトしたうえで、src/relay を作業ディレクトリにして実行してください（../contracts が src/contracts になります）。",
	}, "\n"))
}

// testSourceDir は、このテストのファイルのあるディレクトリ。
func testSourceDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("テストのファイルの位置を取得できません")
	}
	return filepath.Dir(file)
}

// contractsDir は、契約のディレクトリ。見つからなければ、テストを失敗させる。
func contractsDir(t *testing.T) string {
	t.Helper()
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("作業ディレクトリを取得できません: %v", err)
	}
	dir, err := locateContractsDir(candidateDirs(cwd, testSourceDir(t)), func(dir string) bool {
		_, statErr := os.Stat(filepath.Join(dir, markerFile))
		return statErr == nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

// readJSON は、契約の JSON を読む（文書用のキーを含む）。
func readJSON(t *testing.T, name string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(contractsDir(t), name))
	if err != nil {
		t.Fatalf("%s を読めません: %v", name, err)
	}
	var parsed map[string]any
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("%s が JSON として不正です: %v", name, err)
	}
	return parsed
}

// isDocumentKey は、文書用のキー（$comment・note・*_note）か。定数モジュールへは複製しない。
func isDocumentKey(key string) bool {
	return key == "$comment" || key == "note" || strings.HasSuffix(key, "_note")
}

// stripDocumentKeys は、文書用のキーを、再帰的に取り除いた複製を返す。
func stripDocumentKeys(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		out := make(map[string]any, len(typed))
		for key, child := range typed {
			if !isDocumentKey(key) {
				out[key] = stripDocumentKeys(child)
			}
		}
		return out
	case []any:
		out := make([]any, len(typed))
		for index, child := range typed {
			out[index] = stripDocumentKeys(child)
		}
		return out
	default:
		return value
	}
}

// flattenJSON は、葉（スカラーと配列）のパス → 値。オブジェクトは再帰する。
func flattenJSON(prefix string, value any, out map[string]any) {
	if object, ok := value.(map[string]any); ok {
		for key, child := range object {
			path := key
			if prefix != "" {
				path = prefix + "." + key
			}
			flattenJSON(path, child, out)
		}
		return
	}
	out[prefix] = value
}

// normalize は、Go の値を、JSON を経由して、JSON のデコード結果と同じ形（float64・string・bool・[]any）へそろえる。
func normalize(t *testing.T, value any) any {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("JSON へ変換できません: %v", err)
	}
	var out any
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatalf("JSON から戻せません: %v", err)
	}
	return out
}

// compareLeaves は、JSON の葉と、パッケージの値の葉を、両方向に比べ、食い違いを返す。
func compareLeaves(t *testing.T, want map[string]any, got map[string]any) []string {
	t.Helper()
	var problems []string
	for path, expected := range want {
		actual, ok := got[path]
		if !ok {
			problems = append(problems, fmt.Sprintf("パッケージに無い: %s", path))
			continue
		}
		if !reflect.DeepEqual(normalize(t, actual), expected) {
			problems = append(problems, fmt.Sprintf("値が違う: %s（JSON %v、パッケージ %v）", path, expected, actual))
		}
	}
	for path := range got {
		if _, ok := want[path]; !ok {
			problems = append(problems, fmt.Sprintf("JSON に無い: %s", path))
		}
	}
	sort.Strings(problems)
	return problems
}

func toStrings[T ~string](values []T) []string {
	out := make([]string, len(values))
	for index, value := range values {
		out[index] = string(value)
	}
	return out
}

func profileLimits(t *testing.T, profile Profile) ProfileLimits {
	t.Helper()
	limits, ok := ProfileLimitsOf(profile)
	if !ok {
		t.Fatalf("ProfileLimitsOf(%q) が false", profile)
	}
	return limits
}

func frameDirection(t *testing.T, frameType FrameType) string {
	t.Helper()
	direction, ok := frameType.Direction()
	if !ok {
		t.Fatalf("FrameType(0x%02X).Direction() が false", uint8(frameType))
	}
	return string(direction)
}

func rejection(t *testing.T, reason RejectionReason) HTTPRejection {
	t.Helper()
	entry, ok := HTTPRejectionOf(reason)
	if !ok {
		t.Fatalf("HTTPRejectionOf(%q) が false", reason)
	}
	return entry
}

// ---------------------------------------------------------------------------
// 契約のディレクトリの探し方
// ---------------------------------------------------------------------------

func TestCandidateDirs(t *testing.T) {
	cases := []struct {
		name    string
		cwd     string
		testDir string
		want    []string
	}{
		{
			name:    "/contracts・../contracts・../../contracts・テストの隣からの相対パスの順（同じ場所は 1 つにまとめる）",
			cwd:     "/work/src/relay",
			testDir: "/work/src/relay/core/contract",
			want:    []string{"/contracts", "/work/src/contracts", "/work/contracts"},
		},
		{
			name:    "コンテナの中（作業ディレクトリが /app/core/contract）では、すべて /contracts になる",
			cwd:     "/app/core/contract",
			testDir: "/app/core/contract",
			want:    []string{"/contracts", "/app/core/contracts", "/app/contracts"},
		},
		{
			name:    "go test の作業ディレクトリ（パッケージのディレクトリ）では、src/contracts への相対パスの候補が効く",
			cwd:     "/repo/src/relay/core/contract",
			testDir: "/repo/src/relay/core/contract",
			want:    []string{"/contracts", "/repo/src/relay/core/contracts", "/repo/src/relay/contracts", "/repo/src/contracts"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := candidateDirs(tc.cwd, tc.testDir)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("候補 = %v、期待 %v", got, tc.want)
			}
		})
	}
}

func TestLocateContractsDir(t *testing.T) {
	t.Run("最初に見つかった候補を返す", func(t *testing.T) {
		got, err := locateContractsDir([]string{"/a", "/b", "/c"}, func(dir string) bool { return dir == "/b" || dir == "/c" })
		if err != nil || got != "/b" {
			t.Fatalf("got %q, err %v", got, err)
		}
	})
	t.Run("1 つも無ければ、探した場所をすべて並べて失敗する（黙ってスキップしない）", func(t *testing.T) {
		candidates := []string{"/contracts", "/x/contracts", "/contracts-missing"}
		_, err := locateContractsDir(candidates, func(string) bool { return false })
		if err == nil {
			t.Fatal("エラーになりませんでした")
		}
		for _, dir := range candidates {
			if !strings.Contains(err.Error(), dir) {
				t.Errorf("メッセージに %s が無い: %v", dir, err)
			}
		}
		if !strings.Contains(err.Error(), "スキップせず") || !strings.Contains(err.Error(), markerFile) {
			t.Errorf("メッセージが不十分: %v", err)
		}
	})
	t.Run("実際の環境で、契約のディレクトリが見つかる", func(t *testing.T) {
		if _, err := os.Stat(filepath.Join(contractsDir(t), markerFile)); err != nil {
			t.Fatal(err)
		}
	})
}

// ---------------------------------------------------------------------------
// 列挙
// ---------------------------------------------------------------------------

type enumCase struct {
	name     string
	count    int
	from20x4 bool
	values   func() []string
	valid    func(string) bool
	mutate   func()
}

func enumCases() []enumCase {
	return []enumCase{
		{
			name: "source_kind", count: 5, from20x4: true,
			values: func() []string { return toStrings(SourceKindValues()) },
			valid:  func(s string) bool { return SourceKind(s).Valid() },
			mutate: func() { v := SourceKindValues(); v[0] = "mutated" },
		},
		{
			name: "layout", count: 4, from20x4: true,
			values: func() []string { return toStrings(LayoutValues()) },
			valid:  func(s string) bool { return Layout(s).Valid() },
			mutate: func() { v := LayoutValues(); v[0] = "mutated" },
		},
		{
			name: "profile", count: 2, from20x4: true,
			values: func() []string { return toStrings(ProfileValues()) },
			valid:  func(s string) bool { return Profile(s).Valid() },
			mutate: func() { v := ProfileValues(); v[0] = "mutated" },
		},
		{
			name: "broadcast_state", count: 6, from20x4: true,
			values: func() []string { return toStrings(BroadcastStateValues()) },
			valid:  func(s string) bool { return BroadcastState(s).Valid() },
			mutate: func() { v := BroadcastStateValues(); v[0] = "mutated" },
		},
		{
			name: "settlement_state", count: 4, from20x4: true,
			values: func() []string { return toStrings(SettlementStateValues()) },
			valid:  func(s string) bool { return SettlementState(s).Valid() },
			mutate: func() { v := SettlementStateValues(); v[0] = "mutated" },
		},
		{
			name: "end_reason", count: 13, from20x4: true,
			values: func() []string { return toStrings(EndReasonValues()) },
			valid:  func(s string) bool { return EndReason(s).Valid() },
			mutate: func() { v := EndReasonValues(); v[0] = "mutated" },
		},
		{
			name: "rejection_reason", count: 14, from20x4: true,
			values: func() []string { return toStrings(RejectionReasonValues()) },
			valid:  func(s string) bool { return RejectionReason(s).Valid() },
			mutate: func() { v := RejectionReasonValues(); v[0] = "mutated" },
		},
		{
			name: "youtube_connection_state", count: 4, from20x4: true,
			values: func() []string { return toStrings(YouTubeConnectionStateValues()) },
			valid:  func(s string) bool { return YouTubeConnectionState(s).Valid() },
			mutate: func() { v := YouTubeConnectionStateValues(); v[0] = "mutated" },
		},
		{
			name: "studio_state", count: 10, from20x4: true,
			values: func() []string { return toStrings(StudioStateValues()) },
			valid:  func(s string) bool { return StudioState(s).Valid() },
			mutate: func() { v := StudioStateValues(); v[0] = "mutated" },
		},
		{
			name: "source_state", count: 5, from20x4: true,
			values: func() []string { return toStrings(SourceStateValues()) },
			valid:  func(s string) bool { return SourceState(s).Valid() },
			mutate: func() { v := SourceStateValues(); v[0] = "mutated" },
		},
		{
			name: "ws_message_type", count: 14, from20x4: true,
			values: func() []string { return toStrings(WSMessageTypeValues()) },
			valid:  func(s string) bool { return WSMessageType(s).Valid() },
			mutate: func() { v := WSMessageTypeValues(); v[0] = "mutated" },
		},
		{
			name: "internal_call", count: 4, from20x4: true,
			values: func() []string { return toStrings(InternalCallValues()) },
			valid:  func(s string) bool { return InternalCall(s).Valid() },
			mutate: func() { v := InternalCallValues(); v[0] = "mutated" },
		},
		{
			name: "broadcast_event_type", count: 24, from20x4: true,
			values: func() []string { return toStrings(BroadcastEventTypeValues()) },
			valid:  func(s string) bool { return BroadcastEventType(s).Valid() },
			mutate: func() { v := BroadcastEventTypeValues(); v[0] = "mutated" },
		},
		{
			name: "usage_event_type", count: 20, from20x4: true,
			values: func() []string { return toStrings(UsageEventTypeValues()) },
			valid:  func(s string) bool { return UsageEventType(s).Valid() },
			mutate: func() { v := UsageEventTypeValues(); v[0] = "mutated" },
		},
		{
			name: "setting_key", count: 9, from20x4: true,
			values: func() []string { return toStrings(SettingKeyValues()) },
			valid:  func(s string) bool { return SettingKey(s).Valid() },
			mutate: func() { v := SettingKeyValues(); v[0] = "mutated" },
		},
		{
			name: "adaptive_condition", count: 7, from20x4: true,
			values: func() []string { return toStrings(AdaptiveConditionValues()) },
			valid:  func(s string) bool { return AdaptiveCondition(s).Valid() },
			mutate: func() { v := AdaptiveConditionValues(); v[0] = "mutated" },
		},
		{
			name: "color_role", count: 12, from20x4: true,
			values: func() []string { return toStrings(ColorRoleValues()) },
			valid:  func(s string) bool { return ColorRole(s).Valid() },
			mutate: func() { v := ColorRoleValues(); v[0] = "mutated" },
		},
		{
			name: "fatal_code", count: 10, from20x4: false,
			values: func() []string { return toStrings(FatalCodeValues()) },
			valid:  func(s string) bool { return FatalCode(s).Valid() },
			mutate: func() { v := FatalCodeValues(); v[0] = "mutated" },
		},
		{
			name: "relay_event_kind", count: 6, from20x4: false,
			values: func() []string { return toStrings(RelayEventKindValues()) },
			valid:  func(s string) bool { return RelayEventKind(s).Valid() },
			mutate: func() { v := RelayEventKindValues(); v[0] = "mutated" },
		},
		{
			name: "interrupt_cause", count: 4, from20x4: false,
			values: func() []string { return toStrings(InterruptCauseValues()) },
			valid:  func(s string) bool { return InterruptCause(s).Valid() },
			mutate: func() { v := InterruptCauseValues(); v[0] = "mutated" },
		},
		{
			name: "browser_event_kind", count: 8, from20x4: false,
			values: func() []string { return toStrings(BrowserEventKindValues()) },
			valid:  func(s string) bool { return BrowserEventKind(s).Valid() },
			mutate: func() { v := BrowserEventKindValues(); v[0] = "mutated" },
		},
		{
			name: "connect_result", count: 6, from20x4: false,
			values: func() []string { return toStrings(ConnectResultValues()) },
			valid:  func(s string) bool { return ConnectResult(s).Valid() },
			mutate: func() { v := ConnectResultValues(); v[0] = "mutated" },
		},
		{
			name: "login_error", count: 2, from20x4: false,
			values: func() []string { return toStrings(LoginErrorValues()) },
			valid:  func(s string) bool { return LoginError(s).Valid() },
			mutate: func() { v := LoginErrorValues(); v[0] = "mutated" },
		},
		{
			name: "resolution", count: 11, from20x4: false,
			values: func() []string { return toStrings(ResolutionValues()) },
			valid:  func(s string) bool { return Resolution(s).Valid() },
			mutate: func() { v := ResolutionValues(); v[0] = "mutated" },
		},
	}
}

// codePattern は、符号の形式（英小文字の snake_case。数字を含んでよい）。
func codePattern() *regexp.Regexp {
	return regexp.MustCompile(`^[a-z0-9]+(_[a-z0-9]+)*$`)
}

func TestEnumsMatchJSON(t *testing.T) {
	definitions, ok := readJSON(t, "enums.json")["enums"].(map[string]any)
	if !ok {
		t.Fatal("enums.json に enums がありません")
	}
	cases := enumCases()

	t.Run("24 の列挙がある（20.4 の 17 区分と、契約独自の 7 区分）。名前は JSON と過不足なく一致する", func(t *testing.T) {
		var names []string
		for _, tc := range cases {
			names = append(names, tc.name)
		}
		var jsonNames []string
		for name := range definitions {
			jsonNames = append(jsonNames, name)
		}
		sort.Strings(names)
		sort.Strings(jsonNames)
		if !reflect.DeepEqual(names, jsonNames) {
			t.Fatalf("パッケージ %v、JSON %v", names, jsonNames)
		}
		if len(cases) != 24 {
			t.Fatalf("列挙は %d 件", len(cases))
		}
	})

	t.Run("20.4 の件数は 5・4・2・6・4・13・14・4・10・5・14・4・24・20・9・7・12", func(t *testing.T) {
		var counts []int
		for _, tc := range cases {
			if tc.from20x4 {
				counts = append(counts, tc.count)
			}
		}
		want := []int{5, 4, 2, 6, 4, 13, 14, 4, 10, 5, 14, 4, 24, 20, 9, 7, 12}
		if !reflect.DeepEqual(counts, want) {
			t.Fatalf("件数 = %v、期待 %v", counts, want)
		}
	})

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			definition, ok := definitions[tc.name].(map[string]any)
			if !ok {
				t.Fatalf("enums.json に %s がありません", tc.name)
			}
			rawValues, _ := definition["values"].([]any)
			want := make([]string, len(rawValues))
			for index, raw := range rawValues {
				want[index], _ = raw.(string)
			}
			got := tc.values()

			if len(got) != tc.count {
				t.Errorf("件数 = %d、期待 %d", len(got), tc.count)
			}
			if !reflect.DeepEqual(got, want) {
				t.Errorf("値が JSON と違う（順も含む）:\n  パッケージ %v\n  JSON       %v", got, want)
			}
			seen := map[string]bool{}
			for _, value := range got {
				if !codePattern().MatchString(value) {
					t.Errorf("符号の形式が不正: %q", value)
				}
				if seen[value] {
					t.Errorf("符号が重複: %q", value)
				}
				seen[value] = true
				if !tc.valid(value) {
					t.Errorf("Valid() が偽: %q", value)
				}
			}

			// 符号に似ていても、符号でないものは偽（大文字・空白・未知の値）
			invalid := []string{"", " ", "unknown", strings.Repeat("x", 100)}
			for _, value := range got {
				invalid = append(invalid, " "+value, value+" ", value+"\n", strings.ToUpper(value), value+"_")
			}
			for _, candidate := range invalid {
				if seen[candidate] {
					continue
				}
				if tc.valid(candidate) {
					t.Errorf("Valid() が真: %q", candidate)
				}
			}

			// 値の一覧は、呼び出しのたびに新しいスライス（変更しても、次の呼び出しへ影響しない）
			tc.mutate()
			if !reflect.DeepEqual(tc.values(), want) {
				t.Errorf("一覧を変更すると、次の呼び出しに影響する")
			}
		})
	}
}

func TestColorRoles(t *testing.T) {
	definition := readJSON(t, "enums.json")["enums"].(map[string]any)["color_role"].(map[string]any)
	attributes := definition["attributes"].(map[string]any)
	roles := []struct {
		role ColorRole
		name string
	}{
		{ColorRoleBase, "base"},
		{ColorRoleSurface, "surface"},
		{ColorRoleSurfaceRaised, "surface_raised"},
		{ColorRoleDivider, "divider"},
		{ColorRoleControlBorder, "control_border"},
		{ColorRoleTextPrimary, "text_primary"},
		{ColorRoleTextSecondary, "text_secondary"},
		{ColorRoleAccent, "accent"},
		{ColorRoleLive, "live"},
		{ColorRoleWarning, "warning"},
		{ColorRoleSuccess, "success"},
		{ColorRoleFocus, "focus"},
	}

	if len(roles) != 12 || len(attributes) != 12 {
		t.Fatalf("役割は 12（パッケージ %d、JSON %d）", len(roles), len(attributes))
	}
	for _, item := range roles {
		attribute, ok := attributes[item.name].(map[string]any)
		if !ok {
			t.Errorf("JSON に %s の属性が無い", item.name)
			continue
		}
		hex, ok := item.role.Hex()
		if !ok || hex != attribute["hex"] {
			t.Errorf("%s: Hex() = %q、JSON %v", item.name, hex, attribute["hex"])
		}
		onHex, hasOn := item.role.OnHex()
		jsonOn, jsonHasOn := attribute["on_hex"]
		if hasOn != jsonHasOn || (hasOn && onHex != jsonOn) {
			t.Errorf("%s: OnHex() = %q（%v）、JSON %v（%v）", item.name, onHex, hasOn, jsonOn, jsonHasOn)
		}
	}
	if hex, ok := ColorRole("unknown").Hex(); ok || hex != "" {
		t.Errorf("未知の役割の Hex() は、空文字列と false: %q %v", hex, ok)
	}
	if hex, ok := ColorRole("unknown").OnHex(); ok || hex != "" {
		t.Errorf("未知の役割の OnHex() は、空文字列と false: %q %v", hex, ok)
	}
}

// ---------------------------------------------------------------------------
// 制限値
// ---------------------------------------------------------------------------

// limitLeaves は、パッケージの制限値を、limits.json の葉（パス）と同じ名前で並べたもの。
// JSON に葉を足したら、ここへ足さないと、テストが失敗する（両方向）。
func limitLeaves(t *testing.T) map[string]any {
	t.Helper()
	return map[string]any{
		"profiles.720p.width":                                            profileLimits(t, Profile720p).Width,
		"profiles.720p.height":                                           profileLimits(t, Profile720p).Height,
		"profiles.720p.framerate":                                        profileLimits(t, Profile720p).Framerate,
		"profiles.720p.video_bitrate_min_kbps":                           profileLimits(t, Profile720p).VideoBitrateMinKbps,
		"profiles.720p.video_bitrate_initial_kbps":                       profileLimits(t, Profile720p).VideoBitrateInitialKbps,
		"profiles.720p.video_bitrate_max_kbps":                           profileLimits(t, Profile720p).VideoBitrateMaxKbps,
		"profiles.720p.line_threshold_kbps":                              profileLimits(t, Profile720p).LineThresholdKbps,
		"profiles.480p.width":                                            profileLimits(t, Profile480p).Width,
		"profiles.480p.height":                                           profileLimits(t, Profile480p).Height,
		"profiles.480p.framerate":                                        profileLimits(t, Profile480p).Framerate,
		"profiles.480p.video_bitrate_min_kbps":                           profileLimits(t, Profile480p).VideoBitrateMinKbps,
		"profiles.480p.video_bitrate_initial_kbps":                       profileLimits(t, Profile480p).VideoBitrateInitialKbps,
		"profiles.480p.video_bitrate_max_kbps":                           profileLimits(t, Profile480p).VideoBitrateMaxKbps,
		"profiles.480p.line_threshold_kbps":                              profileLimits(t, Profile480p).LineThresholdKbps,
		"video.codec_main":                                               VideoCodecMain,
		"video.codec_constrained_baseline":                               VideoCodecConstrainedBaseline,
		"video.keyframe_interval_seconds":                                VideoKeyframeIntervalSeconds,
		"audio.codec":                                                    AudioCodec,
		"audio.sample_rate_hz":                                           AudioSampleRateHz,
		"audio.channels":                                                 AudioChannels,
		"audio.bitrate_kbps":                                             AudioBitrateKbps,
		"audio.samples_per_video_frame":                                  AudioSamplesPerVideoFrame,
		"line_probe.duration_seconds":                                    LineProbeDurationSeconds,
		"line_probe.max_rate_kbps":                                       LineProbeMaxRateKbps,
		"line_probe.message_bytes_hint":                                  LineProbeMessageBytesHint,
		"line_probe.start_bitrate_throughput_ratio":                      LineProbeStartBitrateThroughputRatio,
		"adaptive.evaluation_interval_ms":                                AdaptiveEvaluationIntervalMs,
		"adaptive.target_change_min_interval_ms":                         AdaptiveTargetChangeMinIntervalMs,
		"adaptive.encoder_queue_max_frames":                              AdaptiveEncoderQueueMaxFrames,
		"adaptive.conditions.backlog_high_twice.backlog_over_ms":         AdaptiveConditionsBacklogHighTwiceBacklogOverMs,
		"adaptive.conditions.backlog_high_twice.consecutive_evaluations": AdaptiveConditionsBacklogHighTwiceConsecutiveEvaluations,
		"adaptive.conditions.backlog_high_twice.decrease_percent":        AdaptiveConditionsBacklogHighTwiceDecreasePercent,
		"adaptive.conditions.backlog_low_no_drop.backlog_under_ms":       AdaptiveConditionsBacklogLowNoDropBacklogUnderMs,
		"adaptive.conditions.backlog_low_no_drop.no_drop_window_seconds": AdaptiveConditionsBacklogLowNoDropNoDropWindowSeconds,
		"adaptive.conditions.backlog_low_no_drop.increase_percent":       AdaptiveConditionsBacklogLowNoDropIncreasePercent,
		"adaptive.conditions.backlog_critical.backlog_over_ms":           AdaptiveConditionsBacklogCriticalBacklogOverMs,
		"adaptive.conditions.video_ack_stalled.stalled_seconds":          AdaptiveConditionsVideoAckStalledStalledSeconds,
		"adaptive.conditions.backlog_severe_sustained.backlog_over_ms":   AdaptiveConditionsBacklogSevereSustainedBacklogOverMs,
		"adaptive.conditions.backlog_severe_sustained.duration_seconds":  AdaptiveConditionsBacklogSevereSustainedDurationSeconds,
		"adaptive.conditions.degraded_enter.backlog_over_ms":             AdaptiveConditionsDegradedEnterBacklogOverMs,
		"adaptive.conditions.degraded_enter.duration_seconds":            AdaptiveConditionsDegradedEnterDurationSeconds,
		"adaptive.conditions.degraded_exit.backlog_at_most_ms":           AdaptiveConditionsDegradedExitBacklogAtMostMs,
		"adaptive.conditions.degraded_exit.duration_seconds":             AdaptiveConditionsDegradedExitDurationSeconds,
		"ws_frame.magic":                                                 WSFrameMagic(),
		"ws_frame.version":                                               WSFrameVersion,
		"ws_frame.header_bytes":                                          WSFrameHeaderBytes,
		"ws_frame.header_fields.magic.offset":                            WSFrameHeaderFieldsMagicOffset,
		"ws_frame.header_fields.magic.length":                            WSFrameHeaderFieldsMagicLength,
		"ws_frame.header_fields.version.offset":                          WSFrameHeaderFieldsVersionOffset,
		"ws_frame.header_fields.version.length":                          WSFrameHeaderFieldsVersionLength,
		"ws_frame.header_fields.type.offset":                             WSFrameHeaderFieldsTypeOffset,
		"ws_frame.header_fields.type.length":                             WSFrameHeaderFieldsTypeLength,
		"ws_frame.header_fields.attributes.offset":                       WSFrameHeaderFieldsAttributesOffset,
		"ws_frame.header_fields.attributes.length":                       WSFrameHeaderFieldsAttributesLength,
		"ws_frame.header_fields.timestamp_us.offset":                     WSFrameHeaderFieldsTimestampUsOffset,
		"ws_frame.header_fields.timestamp_us.length":                     WSFrameHeaderFieldsTimestampUsLength,
		"ws_frame.header_fields.body_length.offset":                      WSFrameHeaderFieldsBodyLengthOffset,
		"ws_frame.header_fields.body_length.length":                      WSFrameHeaderFieldsBodyLengthLength,
		"ws_frame.keyframe_attribute_bit":                                WSFrameKeyframeAttributeBit,
		"ws_frame.max_message_bytes":                                     WSFrameMaxMessageBytes,
		"ws_frame.directions":                                            FrameDirectionValues(),
		"ws_frame.types.hello.code":                                      int(FrameTypeHello),
		"ws_frame.types.hello.direction":                                 frameDirection(t, FrameTypeHello),
		"ws_frame.types.probe.code":                                      int(FrameTypeProbe),
		"ws_frame.types.probe.direction":                                 frameDirection(t, FrameTypeProbe),
		"ws_frame.types.start.code":                                      int(FrameTypeStart),
		"ws_frame.types.start.direction":                                 frameDirection(t, FrameTypeStart),
		"ws_frame.types.video.code":                                      int(FrameTypeVideo),
		"ws_frame.types.video.direction":                                 frameDirection(t, FrameTypeVideo),
		"ws_frame.types.audio.code":                                      int(FrameTypeAudio),
		"ws_frame.types.audio.direction":                                 frameDirection(t, FrameTypeAudio),
		"ws_frame.types.report.code":                                     int(FrameTypeReport),
		"ws_frame.types.report.direction":                                frameDirection(t, FrameTypeReport),
		"ws_frame.types.end.code":                                        int(FrameTypeEnd),
		"ws_frame.types.end.direction":                                   frameDirection(t, FrameTypeEnd),
		"ws_frame.types.accepted.code":                                   int(FrameTypeAccepted),
		"ws_frame.types.accepted.direction":                              frameDirection(t, FrameTypeAccepted),
		"ws_frame.types.probe_result.code":                               int(FrameTypeProbeResult),
		"ws_frame.types.probe_result.direction":                          frameDirection(t, FrameTypeProbeResult),
		"ws_frame.types.ack.code":                                        int(FrameTypeAck),
		"ws_frame.types.ack.direction":                                   frameDirection(t, FrameTypeAck),
		"ws_frame.types.keyframe_request.code":                           int(FrameTypeKeyframeRequest),
		"ws_frame.types.keyframe_request.direction":                      frameDirection(t, FrameTypeKeyframeRequest),
		"ws_frame.types.throttle.code":                                   int(FrameTypeThrottle),
		"ws_frame.types.throttle.direction":                              frameDirection(t, FrameTypeThrottle),
		"ws_frame.types.status.code":                                     int(FrameTypeStatus),
		"ws_frame.types.status.direction":                                frameDirection(t, FrameTypeStatus),
		"ws_frame.types.fatal.code":                                      int(FrameTypeFatal),
		"ws_frame.types.fatal.direction":                                 frameDirection(t, FrameTypeFatal),
		"relay.hello_timeout_seconds":                                    RelayHelloTimeoutSeconds,
		"relay.ingress_bitrate_limit_factor":                             RelayIngressBitrateLimitFactor,
		"relay.ingress_bitrate_window_seconds":                           RelayIngressBitrateWindowSeconds,
		"relay.ingress_bitrate_limit_probe_profile":                      string(RelayIngressBitrateLimitProbeProfile),
		"relay.media_stall_seconds":                                      RelayMediaStallSeconds,
		"relay.heartbeat_interval_seconds":                               RelayHeartbeatIntervalSeconds,
		"relay.heartbeat_lost_stop_seconds":                              RelayHeartbeatLostStopSeconds,
		"relay.egress_buffer_limit_ms":                                   RelayEgressBufferLimitMs,
		"relay.egress_throttle_ms":                                       RelayEgressThrottleMs,
		"relay.ack_interval_ms":                                          RelayAckIntervalMs,
		"relay.report_interval_ms":                                       RelayReportIntervalMs,
		"tickets.ttl_seconds":                                            TicketsTTLSeconds,
		"deadlines.reserved_seconds":                                     DeadlinesReservedSeconds,
		"deadlines.awaiting_media_seconds":                               DeadlinesAwaitingMediaSeconds,
		"deadlines.confirming_seconds":                                   DeadlinesConfirmingSeconds,
		"deadlines.interrupted_relay_notified_seconds":                   DeadlinesInterruptedRelayNotifiedSeconds,
		"deadlines.interrupted_heartbeat_lost_seconds":                   DeadlinesInterruptedHeartbeatLostSeconds,
		"deadlines.heartbeat_lost_detect_seconds":                        DeadlinesHeartbeatLostDetectSeconds,
		"deadlines.max_resumes":                                          DeadlinesMaxResumes,
		"deadlines.live_confirm_poll_interval_seconds":                   DeadlinesLiveConfirmPollIntervalSeconds,
		"deadlines.live_check_interval_seconds":                          DeadlinesLiveCheckIntervalSeconds,
		"deadlines.deadline_monitor_max_interval_seconds":                DeadlinesDeadlineMonitorMaxIntervalSeconds,
		"deadlines.reconnect_backoff_cap_ms":                             DeadlinesReconnectBackoffCapMs,
		"deadlines.time_limit_notice_before_seconds":                     DeadlinesTimeLimitNoticeBeforeSeconds,
		"deadlines.settlement_retry_delays_seconds":                      DeadlinesSettlementRetryDelaysSeconds(),
		"quota.common_units":                                             QuotaCommonUnits,
		"quota.safety_margin_units":                                      QuotaSafetyMarginUnits,
		"quota.broadcast_usable_units_at_default":                        QuotaBroadcastUsableUnitsAtDefault,
		"quota.broadcast_reservation_units":                              QuotaBroadcastReservationUnits,
		"quota.prep_reservation_units":                                   QuotaPrepReservationUnits,
		"quota.settle_reservation_units":                                 QuotaSettleReservationUnits,
		"quota.unit_costs.list":                                          QuotaUnitCostsList,
		"quota.unit_costs.insert":                                        QuotaUnitCostsInsert,
		"quota.unit_costs.update":                                        QuotaUnitCostsUpdate,
		"quota.unit_costs.bind":                                          QuotaUnitCostsBind,
		"quota.unit_costs.transition":                                    QuotaUnitCostsTransition,
		"quota.unit_costs.delete":                                        QuotaUnitCostsDelete,
		"rtmps_ingest.scheme":                                            RTMPSIngestScheme,
		"rtmps_ingest.hosts":                                             RTMPSIngestHosts(),
		"rtmps_ingest.port":                                              RTMPSIngestPort,
		"rtmps_ingest.userinfo_allowed":                                  RTMPSIngestUserinfoAllowed,
		"rtmps_ingest.query_allowed":                                     RTMPSIngestQueryAllowed,
		"dev_ingest.scheme":                                              DevIngestScheme,
		"dev_ingest.host":                                                DevIngestHost,
		"dev_ingest.port":                                                DevIngestPort,
		"dev_ingest.tls":                                                 DevIngestTLS,
		"dev_ingest.allowed_environments":                                DevIngestAllowedEnvironments(),
		"rate_limits.login_start.scope":                                  RateLimitsLoginStartScope,
		"rate_limits.login_start.limit":                                  RateLimitsLoginStartLimit,
		"rate_limits.login_start.window_seconds":                         RateLimitsLoginStartWindowSeconds,
		"rate_limits.connect_start.scope":                                RateLimitsConnectStartScope,
		"rate_limits.connect_start.limit":                                RateLimitsConnectStartLimit,
		"rate_limits.connect_start.window_seconds":                       RateLimitsConnectStartWindowSeconds,
		"rate_limits.recheck_per_minute.scope":                           RateLimitsRecheckPerMinuteScope,
		"rate_limits.recheck_per_minute.limit":                           RateLimitsRecheckPerMinuteLimit,
		"rate_limits.recheck_per_minute.window_seconds":                  RateLimitsRecheckPerMinuteWindowSeconds,
		"rate_limits.recheck_per_day.scope":                              RateLimitsRecheckPerDayScope,
		"rate_limits.recheck_per_day.limit":                              RateLimitsRecheckPerDayLimit,
		"rate_limits.recheck_per_day.window_seconds":                     RateLimitsRecheckPerDayWindowSeconds,
		"rate_limits.intake.scope":                                       RateLimitsIntakeScope,
		"rate_limits.intake.limit_setting":                               string(RateLimitsIntakeLimitSetting),
		"rate_limits.intake.window_seconds":                              RateLimitsIntakeWindowSeconds,
		"retention.youtube_broadcast_id_days_after_end":                  RetentionYouTubeBroadcastIDDaysAfterEnd,
		"retention.health_samples_days":                                  RetentionHealthSamplesDays,
		"retention.broadcast_events_days":                                RetentionBroadcastEventsDays,
		"retention.relay_ticket_days_after_expiry":                       RetentionRelayTicketDaysAfterExpiry,
		"retention.session_days_after_last_use":                          RetentionSessionDaysAfterLastUse,
		"retention.stream_id_days_after_last_verified":                   RetentionStreamIDDaysAfterLastVerified,
		"retention.channel_title_memory_max_minutes":                     RetentionChannelTitleMemoryMaxMinutes,
		"setting_defaults.daily_allowance":                               SettingDefaultsDailyAllowance,
		"setting_defaults.attempt_limit":                                 SettingDefaultsAttemptLimit,
		"setting_defaults.concurrent_limit":                              SettingDefaultsConcurrentLimit,
		"setting_defaults.time_limit_minutes":                            SettingDefaultsTimeLimitMinutes,
		"setting_defaults.intake_rate_per_hour":                          SettingDefaultsIntakeRatePerHour,
		"setting_defaults.monthly_transfer_budget_gb":                    SettingDefaultsMonthlyTransferBudgetGB,
		"setting_defaults.daily_quota_units":                             SettingDefaultsDailyQuotaUnits,
		"setting_defaults.bot_score_threshold":                           SettingDefaultsBotScoreThreshold,
		"setting_defaults.intake_paused":                                 SettingDefaultsIntakePaused,
	}
}

func TestLimitsMatchJSON(t *testing.T) {
	want := make(map[string]any)
	flattenJSON("", stripDocumentKeys(readJSON(t, "limits.json")), want)
	delete(want, "")

	if problems := compareLeaves(t, want, limitLeaves(t)); len(problems) > 0 {
		t.Fatalf("limits.json との食い違い（%d 件）:\n%s", len(problems), strings.Join(problems, "\n"))
	}
	if len(want) < 100 {
		t.Fatalf("葉が %d 個しかありません（読み込みの誤りの疑い）", len(want))
	}
}

func TestProfileLimitsOf(t *testing.T) {
	for _, profile := range ProfileValues() {
		if _, ok := ProfileLimitsOf(profile); !ok {
			t.Errorf("ProfileLimitsOf(%q) が false", profile)
		}
	}
	for _, unknown := range []Profile{"", "1080p", "720P", " 720p"} {
		if limits, ok := ProfileLimitsOf(unknown); ok || limits != (ProfileLimits{}) {
			t.Errorf("未知のプロファイル %q は、零値と false: %v %v", unknown, limits, ok)
		}
	}
}

func TestArrayLimitsReturnCopies(t *testing.T) {
	hosts := RTMPSIngestHosts()
	hosts[0] = "mutated"
	if RTMPSIngestHosts()[0] != "a.rtmps.youtube.com" {
		t.Error("RTMPSIngestHosts() の変更が、次の呼び出しへ影響する")
	}
	delays := DeadlinesSettlementRetryDelaysSeconds()
	delays[0] = 1
	if DeadlinesSettlementRetryDelaysSeconds()[0] != 60 {
		t.Error("DeadlinesSettlementRetryDelaysSeconds() の変更が、次の呼び出しへ影響する")
	}
	magic := WSFrameMagic()
	magic[0] = 0
	if WSFrameMagic() != [2]byte{0x42, 0x4C} {
		t.Error("WSFrameMagic() の変更が、次の呼び出しへ影響する")
	}
}

func TestSpotCheckDesignMemoValues(t *testing.T) {
	// 設計メモ（issue #3）の値の抜き取り（定数どうしの整合）
	if SettingDefaultsDailyQuotaUnits-QuotaCommonUnits-QuotaSafetyMarginUnits != QuotaBroadcastUsableUnitsAtDefault {
		t.Error("1 日の割り当て − 共通枠 − 安全余裕 = 配信に使える上限（9,000）")
	}
	if QuotaPrepReservationUnits+QuotaSettleReservationUnits != QuotaBroadcastReservationUnits {
		t.Error("配信 1 本の予約 550 = 準備・確認 340 + 終了・清算 210")
	}
	if DeadlinesInterruptedHeartbeatLostSeconds <= RelayHeartbeatLostStopSeconds {
		t.Error("中断の期限（心拍の途絶）75 秒は、中継が自ら送出を止めるまでの 60 秒より長い")
	}
	if WSFrameMaxMessageBytes != 2*1024*1024 || WSFrameHeaderBytes != 17 || WSFrameVersion != 1 {
		t.Error("フレームの定数（2 MiB・ヘッダ 17 バイト・版 1）")
	}
	if RelayHelloTimeoutSeconds != 10 || RelayHeartbeatIntervalSeconds != 2 || RelayHeartbeatLostStopSeconds != 60 {
		t.Error("中継の時間（接続通知 10 秒・心拍 2 秒・応答なし 60 秒）")
	}
	if p720 := profileLimits(t, Profile720p); p720.LineThresholdKbps != 4100 || p720.VideoBitrateMaxKbps != 6000 {
		t.Errorf("720p: %+v", p720)
	}
	if p480 := profileLimits(t, Profile480p); p480.LineThresholdKbps != 1200 || p480.Width != 854 {
		t.Errorf("480p: %+v", p480)
	}
	if SettingDefaultsBotScoreThreshold != 0.5 || SettingDefaultsIntakePaused {
		t.Error("bot 判定の閾値の既定値は 0.5（仮置き）、受付停止の既定値は false")
	}
	if DevIngestHost != "fake-ingest" || DevIngestPort != 1935 || RTMPSIngestPort != 443 {
		t.Error("疑似の取り込み口（fake-ingest・1935）と、RTMPS の送出先のポート 443")
	}
}

// ---------------------------------------------------------------------------
// WebSocket フレームの種別符号
// ---------------------------------------------------------------------------

func TestFrameTypes(t *testing.T) {
	cases := []struct {
		frameType FrameType
		message   WSMessageType
	}{
		{FrameTypeHello, WSMessageTypeHello},
		{FrameTypeProbe, WSMessageTypeProbe},
		{FrameTypeStart, WSMessageTypeStart},
		{FrameTypeVideo, WSMessageTypeVideo},
		{FrameTypeAudio, WSMessageTypeAudio},
		{FrameTypeReport, WSMessageTypeReport},
		{FrameTypeEnd, WSMessageTypeEnd},
		{FrameTypeAccepted, WSMessageTypeAccepted},
		{FrameTypeProbeResult, WSMessageTypeProbeResult},
		{FrameTypeAck, WSMessageTypeAck},
		{FrameTypeKeyframeRequest, WSMessageTypeKeyframeRequest},
		{FrameTypeThrottle, WSMessageTypeThrottle},
		{FrameTypeStatus, WSMessageTypeStatus},
		{FrameTypeFatal, WSMessageTypeFatal},
	}

	if len(cases) != 14 || len(FrameTypes()) != 14 || len(WSMessageTypeValues()) != 14 {
		t.Fatal("種別は 14 種")
	}
	seen := map[FrameType]bool{}
	for index, tc := range cases {
		if seen[tc.frameType] {
			t.Errorf("種別符号が重複: 0x%02X", uint8(tc.frameType))
		}
		seen[tc.frameType] = true
		if FrameTypes()[index] != tc.frameType || WSMessageTypeValues()[index] != tc.message {
			t.Errorf("契約の順と違う（%d 番目）", index)
		}
		message, ok := tc.frameType.MessageType()
		if !ok || message != tc.message {
			t.Errorf("0x%02X.MessageType() = %q、期待 %q", uint8(tc.frameType), message, tc.message)
		}
		frameType, ok := FrameTypeOf(tc.message)
		if !ok || frameType != tc.frameType {
			t.Errorf("FrameTypeOf(%q) = 0x%02X、期待 0x%02X", tc.message, uint8(frameType), uint8(tc.frameType))
		}
		direction, ok := tc.frameType.Direction()
		want := FrameDirectionBrowserToRelay
		if uint8(tc.frameType)&0x80 != 0 {
			want = FrameDirectionRelayToBrowser
		}
		if !ok || direction != want {
			t.Errorf("0x%02X の方向 = %q、期待 %q（符号の最上位ビット）", uint8(tc.frameType), direction, want)
		}
	}
	for _, unknown := range []FrameType{0x00, 0x08, 0x80, 0x88, 0xFF} {
		if _, ok := unknown.MessageType(); ok {
			t.Errorf("未知の種別符号 0x%02X の MessageType() が true", uint8(unknown))
		}
		if _, ok := unknown.Direction(); ok {
			t.Errorf("未知の種別符号 0x%02X の Direction() が true", uint8(unknown))
		}
	}
	if _, ok := FrameTypeOf("unknown"); ok {
		t.Error("未知のメッセージ種別の FrameTypeOf() が true")
	}
	for _, direction := range FrameDirectionValues() {
		if !direction.Valid() {
			t.Errorf("方向 %q の Valid() が偽", direction)
		}
	}
	if FrameDirection("sideways").Valid() {
		t.Error("未知の方向の Valid() が真")
	}
}

// ---------------------------------------------------------------------------
// 受付の拒否理由
// ---------------------------------------------------------------------------

func rejectionLeaves(t *testing.T) map[string]any {
	t.Helper()
	return map[string]any{
		"rejections.invalid_input.order":                    rejection(t, RejectionReasonInvalidInput).Order,
		"rejections.invalid_input.http_status":              rejection(t, RejectionReasonInvalidInput).HTTPStatus,
		"rejections.invalid_input.resolution":               string(rejection(t, RejectionReasonInvalidInput).Resolution),
		"rejections.invalid_input.retry_at_rule":            string(rejection(t, RejectionReasonInvalidInput).RetryAtRule),
		"rejections.not_logged_in.order":                    rejection(t, RejectionReasonNotLoggedIn).Order,
		"rejections.not_logged_in.http_status":              rejection(t, RejectionReasonNotLoggedIn).HTTPStatus,
		"rejections.not_logged_in.resolution":               string(rejection(t, RejectionReasonNotLoggedIn).Resolution),
		"rejections.not_logged_in.retry_at_rule":            string(rejection(t, RejectionReasonNotLoggedIn).RetryAtRule),
		"rejections.rate_limited.order":                     rejection(t, RejectionReasonRateLimited).Order,
		"rejections.rate_limited.http_status":               rejection(t, RejectionReasonRateLimited).HTTPStatus,
		"rejections.rate_limited.resolution":                string(rejection(t, RejectionReasonRateLimited).Resolution),
		"rejections.rate_limited.retry_at_rule":             string(rejection(t, RejectionReasonRateLimited).RetryAtRule),
		"rejections.bot_check_failed.order":                 rejection(t, RejectionReasonBotCheckFailed).Order,
		"rejections.bot_check_failed.http_status":           rejection(t, RejectionReasonBotCheckFailed).HTTPStatus,
		"rejections.bot_check_failed.resolution":            string(rejection(t, RejectionReasonBotCheckFailed).Resolution),
		"rejections.bot_check_failed.retry_at_rule":         string(rejection(t, RejectionReasonBotCheckFailed).RetryAtRule),
		"rejections.broadcast_in_progress.order":            rejection(t, RejectionReasonBroadcastInProgress).Order,
		"rejections.broadcast_in_progress.http_status":      rejection(t, RejectionReasonBroadcastInProgress).HTTPStatus,
		"rejections.broadcast_in_progress.resolution":       string(rejection(t, RejectionReasonBroadcastInProgress).Resolution),
		"rejections.broadcast_in_progress.retry_at_rule":    string(rejection(t, RejectionReasonBroadcastInProgress).RetryAtRule),
		"rejections.youtube_not_connected.order":            rejection(t, RejectionReasonYouTubeNotConnected).Order,
		"rejections.youtube_not_connected.http_status":      rejection(t, RejectionReasonYouTubeNotConnected).HTTPStatus,
		"rejections.youtube_not_connected.resolution":       string(rejection(t, RejectionReasonYouTubeNotConnected).Resolution),
		"rejections.youtube_not_connected.retry_at_rule":    string(rejection(t, RejectionReasonYouTubeNotConnected).RetryAtRule),
		"rejections.authorization_revoked.order":            rejection(t, RejectionReasonAuthorizationRevoked).Order,
		"rejections.authorization_revoked.http_status":      rejection(t, RejectionReasonAuthorizationRevoked).HTTPStatus,
		"rejections.authorization_revoked.resolution":       string(rejection(t, RejectionReasonAuthorizationRevoked).Resolution),
		"rejections.authorization_revoked.retry_at_rule":    string(rejection(t, RejectionReasonAuthorizationRevoked).RetryAtRule),
		"rejections.live_not_enabled.order":                 rejection(t, RejectionReasonLiveNotEnabled).Order,
		"rejections.live_not_enabled.http_status":           rejection(t, RejectionReasonLiveNotEnabled).HTTPStatus,
		"rejections.live_not_enabled.resolution":            string(rejection(t, RejectionReasonLiveNotEnabled).Resolution),
		"rejections.live_not_enabled.retry_at_rule":         string(rejection(t, RejectionReasonLiveNotEnabled).RetryAtRule),
		"rejections.allowance_consumed.order":               rejection(t, RejectionReasonAllowanceConsumed).Order,
		"rejections.allowance_consumed.http_status":         rejection(t, RejectionReasonAllowanceConsumed).HTTPStatus,
		"rejections.allowance_consumed.resolution":          string(rejection(t, RejectionReasonAllowanceConsumed).Resolution),
		"rejections.allowance_consumed.retry_at_rule":       string(rejection(t, RejectionReasonAllowanceConsumed).RetryAtRule),
		"rejections.attempts_exhausted.order":               rejection(t, RejectionReasonAttemptsExhausted).Order,
		"rejections.attempts_exhausted.http_status":         rejection(t, RejectionReasonAttemptsExhausted).HTTPStatus,
		"rejections.attempts_exhausted.resolution":          string(rejection(t, RejectionReasonAttemptsExhausted).Resolution),
		"rejections.attempts_exhausted.retry_at_rule":       string(rejection(t, RejectionReasonAttemptsExhausted).RetryAtRule),
		"rejections.intake_paused.order":                    rejection(t, RejectionReasonIntakePaused).Order,
		"rejections.intake_paused.http_status":              rejection(t, RejectionReasonIntakePaused).HTTPStatus,
		"rejections.intake_paused.resolution":               string(rejection(t, RejectionReasonIntakePaused).Resolution),
		"rejections.intake_paused.retry_at_rule":            string(rejection(t, RejectionReasonIntakePaused).RetryAtRule),
		"rejections.transfer_budget_exceeded.order":         rejection(t, RejectionReasonTransferBudgetExceeded).Order,
		"rejections.transfer_budget_exceeded.http_status":   rejection(t, RejectionReasonTransferBudgetExceeded).HTTPStatus,
		"rejections.transfer_budget_exceeded.resolution":    string(rejection(t, RejectionReasonTransferBudgetExceeded).Resolution),
		"rejections.transfer_budget_exceeded.retry_at_rule": string(rejection(t, RejectionReasonTransferBudgetExceeded).RetryAtRule),
		"rejections.capacity_full.order":                    rejection(t, RejectionReasonCapacityFull).Order,
		"rejections.capacity_full.http_status":              rejection(t, RejectionReasonCapacityFull).HTTPStatus,
		"rejections.capacity_full.resolution":               string(rejection(t, RejectionReasonCapacityFull).Resolution),
		"rejections.capacity_full.retry_at_rule":            string(rejection(t, RejectionReasonCapacityFull).RetryAtRule),
		"rejections.quota_insufficient.order":               rejection(t, RejectionReasonQuotaInsufficient).Order,
		"rejections.quota_insufficient.http_status":         rejection(t, RejectionReasonQuotaInsufficient).HTTPStatus,
		"rejections.quota_insufficient.resolution":          string(rejection(t, RejectionReasonQuotaInsufficient).Resolution),
		"rejections.quota_insufficient.retry_at_rule":       string(rejection(t, RejectionReasonQuotaInsufficient).RetryAtRule),
		"retry_at_rules": RetryAtRuleValues(),
	}
}

func TestHTTPRejectionsMatchJSON(t *testing.T) {
	want := make(map[string]any)
	flattenJSON("", stripDocumentKeys(readJSON(t, "http-rejections.json")), want)
	delete(want, "")

	if problems := compareLeaves(t, want, rejectionLeaves(t)); len(problems) > 0 {
		t.Fatalf("http-rejections.json との食い違い（%d 件）:\n%s", len(problems), strings.Join(problems, "\n"))
	}
}

func TestHTTPRejectionOf(t *testing.T) {
	reasons := RejectionReasonValues()
	if len(reasons) != 14 {
		t.Fatalf("拒否理由は 14 種（%d）", len(reasons))
	}
	used := map[Resolution]bool{}
	for index, reason := range reasons {
		entry := rejection(t, reason)
		if entry.Order != index {
			t.Errorf("%s の order = %d、列挙の添字 %d（9.2 の順）", reason, entry.Order, index)
		}
		if !entry.Resolution.Valid() || !entry.RetryAtRule.Valid() {
			t.Errorf("%s: 区分または規則が契約の値でない: %+v", reason, entry)
		}
		used[entry.Resolution] = true
	}
	if len(used) != len(ResolutionValues()) {
		t.Errorf("使われる区分は 11 値すべて（%d）", len(used))
	}
	for _, unknown := range []RejectionReason{"", "unknown", "INVALID_INPUT", " invalid_input"} {
		if entry, ok := HTTPRejectionOf(unknown); ok || entry != (HTTPRejection{}) {
			t.Errorf("未知の拒否理由 %q は、零値と false: %+v %v", unknown, entry, ok)
		}
	}
	for _, rule := range RetryAtRuleValues() {
		if !rule.Valid() {
			t.Errorf("規則 %q の Valid() が偽", rule)
		}
	}
	if RetryAtRule("sometime").Valid() {
		t.Error("未知の規則の Valid() が真")
	}
}

// ---------------------------------------------------------------------------
// ソースの規則（Domain Core・画面に出す文言を含まない）
// ---------------------------------------------------------------------------

// literalPattern は、文字列リテラルとして許す形（符号・16 進の色・ホスト名・コーデック文字列など。文章は許さない）。
func literalPattern() *regexp.Regexp {
	return regexp.MustCompile(`^[A-Za-z0-9_.#:/-]*$`)
}

// packageFiles は、パッケージのソース（テストを除く）の構文木。
func packageFiles(t *testing.T) map[string]*ast.File {
	t.Helper()
	dir := testSourceDir(t)
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	files := map[string]*ast.File{}
	fset := token.NewFileSet()
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, filepath.Join(dir, name), nil, parser.ParseComments)
		if err != nil {
			t.Fatalf("%s を解析できません: %v", name, err)
		}
		files[name] = file
	}
	return files
}

func TestSourceRules(t *testing.T) {
	files := packageFiles(t)

	t.Run("ファイルは、doc・enums・limits・frame・http_rejections だけ", func(t *testing.T) {
		var names []string
		for name := range files {
			names = append(names, name)
		}
		sort.Strings(names)
		want := []string{"doc.go", "enums.go", "frame.go", "http_rejections.go", "limits.go"}
		if !reflect.DeepEqual(names, want) {
			t.Fatalf("ファイル = %v、期待 %v", names, want)
		}
	})

	t.Run("文字列リテラルは、すべて ASCII（日本語はコメントだけ）で、文章に見えるものが無い", func(t *testing.T) {
		for name, file := range files {
			ast.Inspect(file, func(node ast.Node) bool {
				literal, ok := node.(*ast.BasicLit)
				if !ok || literal.Kind != token.STRING {
					return true
				}
				value, err := strconv.Unquote(literal.Value)
				if err != nil {
					t.Errorf("%s: %s を解釈できません", name, literal.Value)
					return true
				}
				if !literalPattern().MatchString(value) {
					t.Errorf("%s: 文章に見える文字列リテラル %q", name, value)
				}
				return true
			})
		}
	})

	t.Run("import が無い（入出力・時計・環境変数を参照しない。Domain Core）", func(t *testing.T) {
		for name, file := range files {
			if len(file.Imports) > 0 {
				t.Errorf("%s が import を持つ: %v", name, file.Imports[0].Path.Value)
			}
		}
	})

	t.Run("パッケージレベルの var と init が無い（グローバル変数を持たない）", func(t *testing.T) {
		for name, file := range files {
			for _, declaration := range file.Decls {
				switch typed := declaration.(type) {
				case *ast.GenDecl:
					if typed.Tok == token.VAR {
						t.Errorf("%s にパッケージレベルの var がある", name)
					}
				case *ast.FuncDecl:
					if typed.Recv == nil && typed.Name.Name == "init" {
						t.Errorf("%s に init がある", name)
					}
				}
			}
		}
	})

	t.Run("パッケージ名は contract", func(t *testing.T) {
		for name, file := range files {
			if file.Name.Name != "contract" {
				t.Errorf("%s のパッケージ名が %s", name, file.Name.Name)
			}
		}
	})
}
