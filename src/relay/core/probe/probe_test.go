package probe

// 回線計測（ProbeMeter）の検査（requirements.md 11.8、ws-protocol.md 5.2）。
//
//   - 最初の計測データの受信から 3 秒後に 1 回、その 3 秒間の受領量から実効スループットを返す
//   - throughput_kbps = 3 秒間に受けた計測データ全体（ヘッダを含む）のバイト数 × 8 ÷ 3,000 の切り捨て（1 kbps = 1,000 bit/s）
//   - 計測データを受けていなければ、エラー（黙って 0 を返さない）
//   - 計測の最大の送信レート（6,000 kbps）を大きく超える異常な値は、エラー（上限は受信ビットレートの上限 = 720p の 9,000 kbps）

import (
	"errors"
	"math"
	"testing"
	"time"
)

func epoch() time.Time { return time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC) }

func at(offset time.Duration) time.Time { return epoch().Add(offset) }

func mustAdd(t *testing.T, m *ProbeMeter, offset time.Duration, bytes int) {
	t.Helper()
	if err := m.Add(at(offset), bytes); err != nil {
		t.Fatalf("Add(+%v, %d) = %v", offset, bytes, err)
	}
}

func mustThroughput(t *testing.T, m *ProbeMeter) int {
	t.Helper()
	got, err := m.ThroughputKbps()
	if err != nil {
		t.Fatalf("ThroughputKbps() = (%d, %v)", got, err)
	}
	return got
}

func TestNoDataIsAnError(t *testing.T) {
	m := &ProbeMeter{}
	if got, err := m.ThroughputKbps(); !errors.Is(err, ErrNoData) || got != 0 {
		t.Fatalf("ThroughputKbps() = (%d, %v), want (0, ErrNoData)", got, err)
	}
	// 計測データを 1 つも受けていなければ、3 秒を数え始めないので、いつまでたっても期限にならない
	for _, offset := range []time.Duration{0, 3 * time.Second, time.Hour} {
		if m.Due(at(offset)) {
			t.Errorf("Due(+%v) = true before any data was received", offset)
		}
	}
}

func TestDueThreeSecondsAfterTheFirstData(t *testing.T) {
	m := &ProbeMeter{}
	mustAdd(t, m, 10*time.Second, 100) // 最初の計測データ（この時刻から 3 秒を数える）
	mustAdd(t, m, 11*time.Second, 100)

	cases := []struct {
		offset time.Duration
		want   bool
	}{
		{10 * time.Second, false},
		{12 * time.Second, false},
		{13*time.Second - time.Nanosecond, false}, // 3 秒に 1 ナノ秒足りない
		{13 * time.Second, true},                  // ちょうど 3 秒（以上）
		{13*time.Second + time.Nanosecond, true},
		{20 * time.Second, true},
		{5 * time.Second, false}, // 最初の受信より前の時刻で尋ねても、期限ではない
	}
	for _, c := range cases {
		if got := m.Due(at(c.offset)); got != c.want {
			t.Errorf("Due(+%v) = %t, want %t", c.offset, got, c.want)
		}
	}
}

func TestThroughputKbps(t *testing.T) {
	cases := []struct {
		name  string
		bytes int
		want  int
	}{
		{"6,000 kbps（2,250,000 バイト = 18 Mbit ÷ 3 秒）", 2_250_000, 6_000},
		{"720p の閾値 4,100 kbps（1,537,500 バイト）", 1_537_500, 4_100},
		{"480p の閾値 1,200 kbps（450,000 バイト）", 450_000, 1_200},
		{"1,200 kbps に満たない（448,875 バイト = 3,591,000 bit ÷ 3,000 = 1,197）", 448_875, 1_197},
		{"切り捨て（1,000 バイト = 8,000 bit ÷ 3,000 = 2.67 → 2）", 1_000, 2},
		{"切り捨て（374 バイト = 2,992 bit → 0）", 374, 0},
		{"切り捨て（375 バイト = 3,000 bit → 1）", 375, 1},
		{"0 バイト（最初の計測データが空でも、計測は始まっている）", 0, 0},
		{"異常でない最大（9,000 kbps = 3,375,000 バイト）", 3_375_000, 9_000},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := &ProbeMeter{}
			mustAdd(t, m, 0, c.bytes)
			if got := mustThroughput(t, m); got != c.want {
				t.Fatalf("ThroughputKbps() = %d, want %d", got, c.want)
			}
		})
	}

	t.Run("複数の計測データの合計（その間に受けた量）", func(t *testing.T) {
		m := &ProbeMeter{}
		mustAdd(t, m, 0, 750_000)
		mustAdd(t, m, time.Second, 750_000)
		mustAdd(t, m, 2*time.Second, 750_000)
		if got := mustThroughput(t, m); got != 6_000 {
			t.Fatalf("ThroughputKbps() = %d, want 6000", got)
		}
		if again := mustThroughput(t, m); again != 6_000 {
			t.Fatalf("a second call returned %d; the result must be stable", again)
		}
	})
}

// 3 秒より後に届いた計測データは、数えない（その間に受けた量だけ。送出の遅れで、後から届く分がある）。
func TestDataAfterTheWindowIsNotCounted(t *testing.T) {
	m := &ProbeMeter{}
	mustAdd(t, m, 0, 450_000)
	mustAdd(t, m, 3*time.Second-time.Nanosecond, 450_000) // 3 秒に 1 ナノ秒足りない：数える
	mustAdd(t, m, 3*time.Second, 450_000)                 // ちょうど 3 秒：窓の外
	mustAdd(t, m, 5*time.Second, 9_000_000)               // 窓の外（異常な量でも、結果に影響しない）
	if got := mustThroughput(t, m); got != 2_400 {        // 900,000 バイト = 7.2 Mbit ÷ 3 秒
		t.Fatalf("ThroughputKbps() = %d, want 2400 (only the first two messages count)", got)
	}
}

func TestAbnormalValuesAreAnError(t *testing.T) {
	cases := []struct {
		name         string
		bytes        int
		wantAbnormal bool
	}{
		{"9,000 kbps ちょうど（3,375,000 バイト）は、異常ではない", 3_375_000, false},
		{"9,000 kbps を 1 バイト超えたら、異常", 3_375_001, true},
		{"6,000 kbps（計測の最大のレート）は、異常ではない", 2_250_000, false},
		{"100 MB は、異常", 100_000_000, true},
		{"int の最大でも、桁あふれせず、異常", math.MaxInt, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := &ProbeMeter{}
			mustAdd(t, m, 0, c.bytes)
			got, err := m.ThroughputKbps()
			if c.wantAbnormal {
				if !errors.Is(err, ErrAbnormal) || got != 0 {
					t.Fatalf("ThroughputKbps() = (%d, %v), want (0, ErrAbnormal)", got, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("ThroughputKbps() err = %v, want nil", err)
			}
		})
	}

	t.Run("合計が桁あふれする入力を重ねても、異常のまま（飽和する）", func(t *testing.T) {
		m := &ProbeMeter{}
		mustAdd(t, m, 0, math.MaxInt)
		mustAdd(t, m, time.Second, math.MaxInt)
		mustAdd(t, m, 2*time.Second, math.MaxInt)
		if _, err := m.ThroughputKbps(); !errors.Is(err, ErrAbnormal) {
			t.Fatalf("err = %v, want ErrAbnormal", err)
		}
	})
}

func TestAddErrors(t *testing.T) {
	t.Run("負のバイト数は、エラー（計測は始まらない）", func(t *testing.T) {
		m := &ProbeMeter{}
		if err := m.Add(at(0), -1); !errors.Is(err, ErrNegativeBytes) {
			t.Fatalf("err = %v, want ErrNegativeBytes", err)
		}
		if _, err := m.ThroughputKbps(); !errors.Is(err, ErrNoData) {
			t.Fatalf("after a rejected Add: err = %v, want ErrNoData", err)
		}
		if m.Due(at(time.Hour)) {
			t.Fatal("a rejected Add must not start the 3 second count")
		}
	})

	t.Run("時刻が、直前の追加より前なら、エラー（同じ時刻は可）。失敗した追加は数えない", func(t *testing.T) {
		m := &ProbeMeter{}
		mustAdd(t, m, 2*time.Second, 375)
		mustAdd(t, m, 2*time.Second, 375) // 同じ時刻
		if err := m.Add(at(2*time.Second-time.Nanosecond), 375); !errors.Is(err, ErrTimeRegression) {
			t.Fatalf("err = %v, want ErrTimeRegression", err)
		}
		if got := mustThroughput(t, m); got != 2 { // 750 バイト = 6,000 bit ÷ 3,000 = 2
			t.Fatalf("ThroughputKbps() = %d, want 2", got)
		}
	})
}

// ブラウザが、3 秒間、6,000 kbps 相当で、32 KB のメッセージ（ヘッダ 17 バイトを含む）を送ったときの、受信側の計測。
func TestRealisticBrowserPacing(t *testing.T) {
	const (
		messageBytes = 32_768 + 17
		rateKbps     = 6_000
	)
	interval := time.Duration(int64(messageBytes) * 8 * int64(time.Second) / (rateKbps * 1000)) // 約 43.7 ms
	m := &ProbeMeter{}
	var sent int
	for offset := time.Duration(0); offset < 3*time.Second; offset += interval {
		mustAdd(t, m, offset, messageBytes)
		sent++
	}
	if !m.Due(at(3 * time.Second)) {
		t.Fatal("Due(+3s) = false")
	}
	got := mustThroughput(t, m)
	want := sent * messageBytes * 8 / 3000
	if got != want {
		t.Fatalf("ThroughputKbps() = %d, want %d (%d messages)", got, want, sent)
	}
	if got < 5_900 || got > 6_100 {
		t.Fatalf("ThroughputKbps() = %d, want about 6000 (a compliant sender is not abnormal)", got)
	}
}

// 独立したインスタンスを、複数のゴルーチンで使っても競合しない（グローバルな状態を持たない。-race で確かめる）。
func TestConcurrentUseOfIndependentInstances(t *testing.T) {
	results := make(chan error, 6)
	for worker := 0; worker < 6; worker++ {
		go func() {
			m := &ProbeMeter{}
			for i := 0; i < 100; i++ {
				if err := m.Add(at(time.Duration(i)*20*time.Millisecond), 1_000); err != nil {
					results <- err
					return
				}
			}
			_, err := m.ThroughputKbps()
			results <- err
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
	utc, local := &ProbeMeter{}, &ProbeMeter{}
	mustAdd(t, utc, 5*time.Second, 1)
	if err := local.Add(at(5*time.Second).In(jst), 1); err != nil {
		t.Fatal(err)
	}
	errUTC := utc.Add(at(time.Second), 1)
	errJST := local.Add(at(time.Second).In(jst), 1)
	if !errors.Is(errUTC, ErrTimeRegression) || errUTC.Error() != errJST.Error() {
		t.Fatalf("UTC: %v\nJST: %v", errUTC, errJST)
	}
}
