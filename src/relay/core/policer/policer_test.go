package policer

// 受信量の監視（IngressPolicer）の検査（requirements.md 11.9・28.1、契約 limits.json の relay）。
//
//   - 直近 10 秒の平均の受信ビットレート（窓が満ちていなくても 10 秒で割る。開始直後に過大に見せない）
//   - 上限 = プロファイルの映像ビットレートの上限の 1.5 倍（720p は 9,000 kbps、480p は 3,750 kbps）。
//     プロファイルが未確定の間は 720p の上限。上限ちょうどは超過ではない（超えたら真）
//   - 窓の境界：ちょうど 10 秒前の記録は、窓の外
// 時刻はすべて引数。固定の起点からの経過で表す。

import (
	"errors"
	"math"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

func epoch() time.Time { return time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC) }

func at(offset time.Duration) time.Time { return epoch().Add(offset) }

func mustRecord(t *testing.T, p *IngressPolicer, offset time.Duration, bytes int) {
	t.Helper()
	if err := p.Record(at(offset), bytes); err != nil {
		t.Fatalf("Record(+%v, %d) = %v", offset, bytes, err)
	}
}

func mustExceed(t *testing.T, p *IngressPolicer, offset time.Duration, profile contract.Profile) bool {
	t.Helper()
	got, err := p.Exceeds(at(offset), profile)
	if err != nil {
		t.Fatalf("Exceeds(+%v, %q) = %v", offset, profile, err)
	}
	return got
}

func TestLimitKbps(t *testing.T) {
	cases := []struct {
		profile contract.Profile
		want    int
	}{
		{contract.Profile720p, 9_000},
		{contract.Profile480p, 3_750},
		{"", 9_000}, // プロファイルが未確定の間は、720p の上限
	}
	for _, c := range cases {
		got, err := LimitKbps(c.profile)
		if err != nil || got != c.want {
			t.Errorf("LimitKbps(%q) = (%d, %v), want %d", c.profile, got, err, c.want)
		}
	}
	for _, bad := range []contract.Profile{"1080p", "720P", " 720p", "480"} {
		if _, err := LimitKbps(bad); !errors.Is(err, ErrInvalidProfile) {
			t.Errorf("LimitKbps(%q) err = %v, want ErrInvalidProfile", bad, err)
		}
	}
}

func TestBitrateKbps(t *testing.T) {
	type record struct {
		offset time.Duration
		bytes  int
	}
	cases := []struct {
		name    string
		records []record
		query   time.Duration
		want    int
	}{
		{"記録が無ければ 0", nil, 0, 0},
		{"1 つの記録は、10 秒の窓で割る（1,250,000 バイト = 10 Mbit → 1,000 kbps）", []record{{0, 1_250_000}}, 0, 1_000},
		{"窓が満ちていなくても、10 秒で割る（1 秒目に 10 Mbit でも 1,000 kbps。1 秒で割れば 10,000 kbps の誤検知になる）", []record{{0, 1_250_000}}, time.Second, 1_000},
		{"複数の記録の合計（10 回 × 125,000 バイト）", []record{
			{0, 125_000}, {time.Second, 125_000}, {2 * time.Second, 125_000}, {3 * time.Second, 125_000}, {4 * time.Second, 125_000},
			{5 * time.Second, 125_000}, {6 * time.Second, 125_000}, {7 * time.Second, 125_000}, {8 * time.Second, 125_000}, {9 * time.Second, 125_000},
		}, 9 * time.Second, 1_000},
		{"窓の境界：10 秒より 1 ナノ秒前は、窓の内", []record{{0, 1_250_000}}, 10*time.Second - time.Nanosecond, 1_000},
		{"窓の境界：ちょうど 10 秒前の記録は、窓の外", []record{{0, 1_250_000}}, 10 * time.Second, 0},
		{"窓の境界：古い記録だけが外へ出る", []record{{0, 1_250_000}, {5 * time.Second, 1_250_000}}, 10 * time.Second, 1_000},
		{"窓の境界：外へ出る前は、両方を数える", []record{{0, 1_250_000}, {5 * time.Second, 1_250_000}}, 10*time.Second - time.Nanosecond, 2_000},
		{"窓の境界：すべて外へ出たら 0", []record{{0, 1_250_000}, {5 * time.Second, 1_250_000}}, 15 * time.Second, 0},
		{"kbps は切り捨て（1,249 バイト = 9,992 bit → 0 kbps）", []record{{0, 1_249}}, 0, 0},
		{"kbps は切り捨て（1,250 バイト = 10,000 bit → 1 kbps）", []record{{0, 1_250}}, 0, 1},
		{"0 バイトの記録は、何も足さない", []record{{0, 0}, {time.Second, 0}}, time.Second, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := &IngressPolicer{}
			for _, r := range c.records {
				mustRecord(t, p, r.offset, r.bytes)
			}
			if got := p.BitrateKbps(at(c.query)); got != c.want {
				t.Fatalf("BitrateKbps(+%v) = %d, want %d", c.query, got, c.want)
			}
		})
	}
}

func TestExceedsThresholds(t *testing.T) {
	const (
		limit720 = 11_250_000 // 9,000 kbps × 10 秒 ÷ 8
		limit480 = 4_687_500  // 3,750 kbps × 10 秒 ÷ 8
	)
	cases := []struct {
		name    string
		profile contract.Profile
		bytes   int
		want    bool
	}{
		{"720p：何も受けていない", contract.Profile720p, 0, false},
		{"720p：上限ちょうど（9,000 kbps）は、超過ではない", contract.Profile720p, limit720, false},
		{"720p：上限を 1 バイト超えたら超過", contract.Profile720p, limit720 + 1, true},
		{"720p：上限の半分", contract.Profile720p, limit720 / 2, false},
		{"480p：上限ちょうど（3,750 kbps）は、超過ではない", contract.Profile480p, limit480, false},
		{"480p：上限を 1 バイト超えたら超過", contract.Profile480p, limit480 + 1, true},
		{"未確定：720p の上限を使う（480p の上限を超えても、超過ではない）", "", limit480 + 1, false},
		{"未確定：720p の上限ちょうどは、超過ではない", "", limit720, false},
		{"未確定：720p の上限を超えたら超過", "", limit720 + 1, true},
		{"720p のままなら、480p の上限を超えても超過ではない", contract.Profile720p, limit480 + 1, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := &IngressPolicer{}
			mustRecord(t, p, 0, c.bytes)
			if got := mustExceed(t, p, 0, c.profile); got != c.want {
				t.Fatalf("Exceeds(%q) with %d bytes = %t, want %t", c.profile, c.bytes, got, c.want)
			}
		})
	}
}

func TestExceedsAtTheWindowBoundary(t *testing.T) {
	p := &IngressPolicer{}
	mustRecord(t, p, 0, 11_250_001) // 上限を 1 バイト超える
	if !mustExceed(t, p, 0, contract.Profile720p) {
		t.Fatal("at the record time: want exceeded")
	}
	if !mustExceed(t, p, 10*time.Second-time.Nanosecond, contract.Profile720p) {
		t.Fatal("1 ns before the window ends: want exceeded")
	}
	if mustExceed(t, p, 10*time.Second, contract.Profile720p) {
		t.Fatal("exactly 10 s later the record leaves the window: want not exceeded")
	}

	q := &IngressPolicer{}
	mustRecord(t, q, 0, 11_250_000) // 上限ちょうど
	mustRecord(t, q, time.Second, 1)
	if !mustExceed(t, q, time.Second, contract.Profile720p) {
		t.Fatal("limit + 1 byte: want exceeded")
	}
	if mustExceed(t, q, 10*time.Second, contract.Profile720p) {
		t.Fatal("after the large record left the window: want not exceeded")
	}
}

func TestExceedsRejectsAnInvalidProfile(t *testing.T) {
	p := &IngressPolicer{}
	mustRecord(t, p, 0, 100)
	for _, bad := range []contract.Profile{"1080p", "720P", "x"} {
		if _, err := p.Exceeds(at(0), bad); !errors.Is(err, ErrInvalidProfile) {
			t.Errorf("Exceeds(%q) err = %v, want ErrInvalidProfile (no fallback to another profile)", bad, err)
		}
	}
}

// 実際の配信に近い列（映像 30 fps・音声）を、プロファイルの最大のビットレートで流し続けても、超過にならない（誤検知なし）。
func TestNoFalsePositiveOnARealisticStreamAtTheProfileMaximum(t *testing.T) {
	cases := []struct {
		name      string
		profile   contract.Profile
		videoKbps int
	}{
		{"720p の最大（映像 6,000 kbps）", contract.Profile720p, 6_000},
		{"480p の最大（映像 2,500 kbps）", contract.Profile480p, 2_500},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := &IngressPolicer{}
			const (
				audioKbps = 128
				fps       = 30
				seconds   = 60
			)
			normalFrame := c.videoKbps * 1000 / 8 / fps // 通常のフレームの大きさ（バイト）
			audioChunk := audioKbps * 1000 / 8 / fps    // 音声（1 フレーム分の時間あたり）
			maxKbps := 0
			for frame := 0; frame < seconds*fps; frame++ {
				offset := time.Duration(frame) * time.Second / fps
				size := normalFrame + audioChunk
				if frame%(2*fps) == 0 {
					size += 4 * normalFrame // キーフレーム（2 秒ごと）は、通常のフレームの 5 倍
				}
				mustRecord(t, p, offset, size)
				if mustExceed(t, p, offset, c.profile) {
					t.Fatalf("frame %d (+%v): exceeded at %d kbps on a stream at the profile maximum", frame, offset, p.BitrateKbps(at(offset)))
				}
				if kbps := p.BitrateKbps(at(offset)); kbps > maxKbps {
					maxKbps = kbps
				}
			}
			limit, _ := LimitKbps(c.profile)
			if maxKbps > limit*9/10 {
				t.Fatalf("max average %d kbps is not safely below the limit %d kbps", maxKbps, limit)
			}
		})
	}

	t.Run("回線計測（480p になる回線の上限 4,100 kbps で 3 秒）のあとに、480p の最大で送っても、超過にならない", func(t *testing.T) {
		p := &IngressPolicer{}
		probeBytes := 4_100 * 1000 / 8 * 3 // 3 秒
		const messages = 69
		for i := 0; i < messages; i++ {
			mustRecord(t, p, time.Duration(i)*3*time.Second/messages, probeBytes/messages)
		}
		video := (2_500 + 128) * 1000 / 8 / 30
		for frame := 0; frame < 30*40; frame++ {
			offset := 3*time.Second + time.Duration(frame)*time.Second/30
			mustRecord(t, p, offset, video)
			if mustExceed(t, p, offset, contract.Profile480p) {
				t.Fatalf("frame %d (+%v): exceeded at %d kbps", frame, offset, p.BitrateKbps(at(offset)))
			}
		}
	})
}

// 上限の 1.5 倍を超える流入（12,000 kbps）を、窓の平均が上限を超えた時点で検出する。
func TestDetectsAFloodWhenTheWindowAverageExceedsTheLimit(t *testing.T) {
	cases := []struct {
		name           string
		profile        contract.Profile
		notExceededAt  time.Duration // この時点（含む）では、まだ超過ではない
		exceededAtOrBy time.Duration // この時点では、超過
	}{
		// 150,000 バイトを 100 ms ごと（= 12,000 kbps）。720p の上限 11,250,000 バイトは、75 回分（7.4 秒）でちょうど
		{"720p", contract.Profile720p, 7400 * time.Millisecond, 7500 * time.Millisecond},
		// 480p の上限 4,687,500 バイトは、31.25 回分。31 回分（3.0 秒）までは超えない
		{"480p", contract.Profile480p, 3000 * time.Millisecond, 3100 * time.Millisecond},
		{"未確定（720p の上限）", "", 7400 * time.Millisecond, 7500 * time.Millisecond},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := &IngressPolicer{}
			for step := 0; step <= int(c.exceededAtOrBy/(100*time.Millisecond)); step++ {
				offset := time.Duration(step) * 100 * time.Millisecond
				mustRecord(t, p, offset, 150_000)
				got := mustExceed(t, p, offset, c.profile)
				switch {
				case offset <= c.notExceededAt && got:
					t.Fatalf("+%v: exceeded too early (%d kbps)", offset, p.BitrateKbps(at(offset)))
				case offset >= c.exceededAtOrBy && !got:
					t.Fatalf("+%v: not exceeded (%d kbps), want exceeded", offset, p.BitrateKbps(at(offset)))
				}
			}
		})
	}
}

func TestRecordErrors(t *testing.T) {
	t.Run("負のバイト数は、エラー（状態は変わらない）", func(t *testing.T) {
		p := &IngressPolicer{}
		mustRecord(t, p, 0, 100)
		if err := p.Record(at(time.Second), -1); !errors.Is(err, ErrNegativeBytes) {
			t.Fatalf("err = %v, want ErrNegativeBytes", err)
		}
		if got := p.BitrateKbps(at(time.Second)); got != 0 { // 100 バイト = 800 bit → 0 kbps（切り捨て）
			t.Fatalf("BitrateKbps = %d", got)
		}
		mustRecord(t, p, time.Second, 1_250) // エラーの後も、同じ時刻から記録できる（時刻の基準が進んでいない）
	})

	t.Run("時刻が、直前の記録より前なら、エラー（同じ時刻は可）", func(t *testing.T) {
		p := &IngressPolicer{}
		mustRecord(t, p, 5*time.Second, 1_250)
		mustRecord(t, p, 5*time.Second, 1_250) // 同じ時刻
		if err := p.Record(at(5*time.Second-time.Nanosecond), 1); !errors.Is(err, ErrTimeRegression) {
			t.Fatalf("err = %v, want ErrTimeRegression", err)
		}
		if got := p.BitrateKbps(at(5 * time.Second)); got != 2 { // 2,500 バイト = 20,000 bit → 2 kbps（失敗した記録は数えない）
			t.Fatalf("BitrateKbps = %d, want 2", got)
		}
	})

	t.Run("窓の合計が桁あふれする大きさは、エラー", func(t *testing.T) {
		p := &IngressPolicer{}
		if err := p.Record(at(0), math.MaxInt); !errors.Is(err, ErrBytesOutOfRange) {
			t.Fatalf("err = %v, want ErrBytesOutOfRange", err)
		}
		half := math.MaxInt / 16
		mustRecord(t, p, 0, half)
		if err := p.Record(at(time.Millisecond), half+half); !errors.Is(err, ErrBytesOutOfRange) {
			t.Fatalf("err = %v, want ErrBytesOutOfRange (the window sum would overflow)", err)
		}
		if p.BitrateKbps(at(time.Millisecond)) <= 0 {
			t.Fatal("the first record must still count")
		}
	})
}

// 問い合わせ（BitrateKbps・Exceeds）は、状態を変えない。先の時刻で尋ねても、記録は消えず、後から古い時刻の記録もできる。
func TestQueriesDoNotChangeState(t *testing.T) {
	p := &IngressPolicer{}
	mustRecord(t, p, 0, 1_250_000)
	if got := p.BitrateKbps(at(100 * time.Second)); got != 0 {
		t.Fatalf("BitrateKbps far in the future = %d, want 0", got)
	}
	if mustExceed(t, p, 100*time.Second, contract.Profile720p) {
		t.Fatal("Exceeds far in the future: want false")
	}
	// 先の時刻の問い合わせの後でも、窓の中の記録は残っている
	if got := p.BitrateKbps(at(0)); got != 1_000 {
		t.Fatalf("BitrateKbps(+0) after a future query = %d, want 1000", got)
	}
	// 問い合わせで時刻の基準が進まないので、続きの記録ができる
	mustRecord(t, p, time.Second, 1_250_000)
	if got := p.BitrateKbps(at(time.Second)); got != 2_000 {
		t.Fatalf("BitrateKbps(+1s) = %d, want 2000", got)
	}
	// 同じ問い合わせは、何度でも同じ値
	for i := 0; i < 3; i++ {
		if got := p.BitrateKbps(at(time.Second)); got != 2_000 {
			t.Fatalf("repeat %d: BitrateKbps = %d, want 2000", i, got)
		}
	}
}

// 大量のメッセージ（小さなフレームの洪水）でも、保持する項目が、窓の 10 秒あたり最大 10,000 件（1 ミリ秒ごと）に収まる。
func TestEntriesAreBounded(t *testing.T) {
	t.Run("1 ミリ秒以内に続く記録は、1 つの項目へまとめる（合計は変わらない）", func(t *testing.T) {
		p := &IngressPolicer{}
		const records = 100_000
		for i := 0; i < records; i++ {
			mustRecord(t, p, time.Duration(i)*10*time.Microsecond, 10) // 1 秒の間に 10 万回
		}
		if live := p.liveEntries(); live > 1_001 {
			t.Fatalf("live entries = %d, want <= 1001 (one per millisecond)", live)
		}
		if got := p.BitrateKbps(at(time.Second)); got != 800 { // 1,000,000 バイト = 8 Mbit ÷ 10 秒
			t.Fatalf("BitrateKbps = %d, want 800 (coalescing must not lose bytes)", got)
		}
	})

	t.Run("ちょうど 10 秒前の項目は、記録のとき、保持から外れる", func(t *testing.T) {
		p := &IngressPolicer{}
		mustRecord(t, p, 0, 1_250)
		mustRecord(t, p, 5*time.Second, 1_250)
		mustRecord(t, p, 10*time.Second-time.Nanosecond, 1_250)
		if live := p.liveEntries(); live != 3 {
			t.Fatalf("live entries = %d, want 3 (the first is 1 ns short of leaving the window)", live)
		}
		mustRecord(t, p, 10*time.Second, 1_250) // 直前の項目へまとまる（1 ナノ秒差）。ちょうど 10 秒前の最初の項目は、外れる
		if live := p.liveEntries(); live != 2 {
			t.Fatalf("live entries = %d, want 2 (the entry from exactly 10 s ago left the window)", live)
		}
	})

	t.Run("0 バイトの記録は、項目を増やさない", func(t *testing.T) {
		p := &IngressPolicer{}
		for i := 0; i < 1_000; i++ {
			mustRecord(t, p, time.Duration(i)*2*time.Millisecond, 0)
		}
		if live := p.liveEntries(); live != 0 {
			t.Fatalf("live entries = %d, want 0", live)
		}
	})

	t.Run("1 ミリ秒ちょうど離れた記録は、別の項目（境界の精度を保つ）", func(t *testing.T) {
		p := &IngressPolicer{}
		for i := 0; i < 5; i++ {
			mustRecord(t, p, time.Duration(i)*time.Millisecond, 1_250)
		}
		if live := p.liveEntries(); live != 5 {
			t.Fatalf("live entries = %d, want 5", live)
		}
	})

	t.Run("窓の外の項目は破棄され、長時間（1 時間）でも、保持する領域が増え続けない", func(t *testing.T) {
		p := &IngressPolicer{}
		for i := 0; i < 36_000; i++ {
			mustRecord(t, p, time.Duration(i)*100*time.Millisecond, 25_000)
		}
		if live := p.liveEntries(); live > 101 {
			t.Fatalf("live entries = %d, want about 100 (10 s of 100 ms records)", live)
		}
		if capacity := p.capacity(); capacity > 1_024 {
			t.Fatalf("capacity = %d entries after an hour; the storage must not grow with the stream length", capacity)
		}
		if got := p.BitrateKbps(at(3600*time.Second - 100*time.Millisecond)); got != 2_000 { // 25,000 バイト × 10 回/秒 = 2,000 kbps
			t.Fatalf("BitrateKbps = %d, want 2000", got)
		}
	})
}

// 独立したインスタンスを、複数のゴルーチンで使っても競合しない（グローバルな状態を持たない。-race で確かめる）。
func TestConcurrentUseOfIndependentInstances(t *testing.T) {
	results := make(chan error, 6)
	for worker := 0; worker < 6; worker++ {
		go func() {
			p := &IngressPolicer{}
			for i := 0; i < 2_000; i++ {
				offset := time.Duration(i) * 10 * time.Millisecond
				if err := p.Record(at(offset), 1_000); err != nil {
					results <- err
					return
				}
				if _, err := p.Exceeds(at(offset), contract.Profile720p); err != nil {
					results <- err
					return
				}
			}
			results <- nil
		}()
	}
	for worker := 0; worker < 6; worker++ {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
}

// エラーの文面が、時刻の表示（ローカルのタイムゾーンの読み込み）に依存しない（同じ入力に、同じ出力。Domain Core は環境を読まない）。
func TestRegressionErrorTextDoesNotDependOnTheLocation(t *testing.T) {
	jst := time.FixedZone("JST", 9*60*60)
	utc, local := &IngressPolicer{}, &IngressPolicer{}
	mustRecord(t, utc, 5*time.Second, 1)
	if err := local.Record(at(5*time.Second).In(jst), 1); err != nil {
		t.Fatal(err)
	}
	errUTC := utc.Record(at(time.Second), 1)
	errJST := local.Record(at(time.Second).In(jst), 1)
	if !errors.Is(errUTC, ErrTimeRegression) || errUTC.Error() != errJST.Error() {
		t.Fatalf("UTC: %v\nJST: %v", errUTC, errJST)
	}
}
