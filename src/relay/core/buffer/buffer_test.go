package buffer

// 送出待ちバッファの方針（Policy）の検査（requirements.md 11.10、ws-protocol.md 5.12・9 章）。
//
//   - 3 秒分を上限とする。1.5 秒分を超えた時点で抑制指示、上限（3 秒分）に達したら送出失敗（バッファを破棄して RTMPS を再接続）
//   - 抑制指示の目標ビットレート：現在の目標の 70%、プロファイルの下限を下回らない、1 秒に 1 回まで
//     （「70%」は、仕様に数値の定めが無いための解釈。ブラウザの適応制御の「30% 引き下げ」（12 章）と同じ割合）

import (
	"errors"
	"math"
	"testing"
	"time"
)

func epoch() time.Time { return time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC) }

func at(offset time.Duration) time.Time { return epoch().Add(offset) }

func TestEvaluate(t *testing.T) {
	both := Decision{Throttle: true, Overflow: true}
	cases := []struct {
		name      string
		pendingMs int
		want      Decision
	}{
		{"空", 0, Decision{}},
		{"1 ms", 1, Decision{}},
		{"1.5 秒に 1 ms 足りない", 1499, Decision{}},
		{"1.5 秒ちょうどは、超えていないので、抑制しない", 1500, Decision{}},
		{"1.5 秒を 1 ms 超えたら、抑制指示", 1501, Decision{Throttle: true}},
		{"上限の 1 ms 手前は、抑制指示のみ", 2999, Decision{Throttle: true}},
		{"3 秒（上限）に達したら、送出失敗（抑制の条件も満たす）", 3000, both},
		{"上限を超えても、送出失敗", 3001, both},
		{"極端に大きな値でも、送出失敗", math.MaxInt, both},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var p Policy
			got, err := p.Evaluate(c.pendingMs)
			if err != nil {
				t.Fatalf("Evaluate(%d) err = %v", c.pendingMs, err)
			}
			if got != c.want {
				t.Fatalf("Evaluate(%d) = %+v, want %+v", c.pendingMs, got, c.want)
			}
		})
	}

	t.Run("負の滞留は、エラー", func(t *testing.T) {
		var p Policy
		for _, bad := range []int{-1, -1500, math.MinInt} {
			if _, err := p.Evaluate(bad); !errors.Is(err, ErrNegativePending) {
				t.Errorf("Evaluate(%d) err = %v, want ErrNegativePending", bad, err)
			}
		}
	})

	t.Run("評価は、状態を持たない（同じ入力は、何度でも同じ結果）", func(t *testing.T) {
		var p Policy
		for i := 0; i < 3; i++ {
			got, _ := p.Evaluate(2000)
			if got != (Decision{Throttle: true}) {
				t.Fatalf("repeat %d: %+v", i, got)
			}
		}
	})
}

func TestThrottleTarget(t *testing.T) {
	cases := []struct {
		name           string
		current, floor int
		want           int
	}{
		{"720p の初期値 4,500 kbps の 70% = 3,150 kbps（共有ベクタ throttle_3150_kbps と同じ）", 4500, 3000, 3150},
		{"720p の上限 6,000 kbps の 70% = 4,200 kbps", 6000, 3000, 4200},
		{"下限（3,000 kbps）を下回る値は、下限にする", 4000, 3000, 3000},
		{"すでに下限なら、下限のまま", 3000, 3000, 3000},
		{"70% がちょうど下限（4,286 × 0.7 = 3,000.2）", 4286, 3000, 3000},
		{"480p の初期値 1,500 kbps の 70% = 1,050 kbps", 1500, 800, 1050},
		{"480p の上限 2,500 kbps の 70% = 1,750 kbps", 2500, 800, 1750},
		{"480p：下限 800 kbps を下回る値は、下限", 1000, 800, 800},
		{"切り捨て（3,333 × 0.7 = 2,333.1）", 3333, 800, 2333},
		{"切り捨て（1,999 × 0.7 = 1,399.3）", 1999, 800, 1399},
		{"下限が現在の目標より大きくても、下限（上げる指示にはなるが、ブラウザは min で受ける）", 2000, 3000, 3000},
		{"最小の値", 1, 1, 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := ThrottleTarget(c.current, c.floor)
			if err != nil || got != c.want {
				t.Fatalf("ThrottleTarget(%d, %d) = (%d, %v), want %d", c.current, c.floor, got, err, c.want)
			}
		})
	}

	t.Run("目標は、常に正（throttle の target_kbps は正の整数）。70% が 0 になる小さな値でも、下限（正）になる", func(t *testing.T) {
		for current := 1; current <= 200; current++ {
			got, err := ThrottleTarget(current, 1)
			if err != nil || got < 1 {
				t.Fatalf("ThrottleTarget(%d, 1) = (%d, %v), want a positive target", current, got, err)
			}
		}
	})

	t.Run("int の最大でも、桁あふれしない", func(t *testing.T) {
		got, err := ThrottleTarget(math.MaxInt, 1)
		if err != nil || got <= math.MaxInt/2 || got >= math.MaxInt {
			t.Fatalf("ThrottleTarget(MaxInt, 1) = (%d, %v), want about 70%% of MaxInt", got, err)
		}
	})

	t.Run("現在の目標・下限が 0 以下なら、エラー", func(t *testing.T) {
		for _, c := range []struct{ current, floor int }{{0, 3000}, {-1, 3000}, {4500, 0}, {4500, -1}, {0, 0}} {
			if _, err := ThrottleTarget(c.current, c.floor); !errors.Is(err, ErrInvalidBitrate) {
				t.Errorf("ThrottleTarget(%d, %d) err = %v, want ErrInvalidBitrate", c.current, c.floor, err)
			}
		}
	})
}

func TestNextThrottleSendsAtMostOncePerSecond(t *testing.T) {
	var p Policy
	type call struct {
		offset     time.Duration
		current    int
		wantOK     bool
		wantTarget int
	}
	calls := []call{
		{0, 4500, true, 3150},
		{100 * time.Millisecond, 4500, false, 0},
		{500 * time.Millisecond, 4500, false, 0},
		{999 * time.Millisecond, 4500, false, 0},
		{time.Second, 3150, true, 3000},           // ちょうど 1 秒で、また送れる。現在の目標（3,150）から導く（下限 3,000）
		{1500 * time.Millisecond, 3000, false, 0}, // 直前に送ったのは 1 秒時点
		{1999 * time.Millisecond, 3000, false, 0},
		{2 * time.Second, 3000, true, 3000},
		{10 * time.Second, 6000, true, 4200}, // 間が空いたあとは、すぐに送れる
		{10*time.Second + time.Millisecond, 6000, false, 0},
	}
	for index, c := range calls {
		target, ok, err := p.NextThrottle(at(c.offset), c.current, 3000)
		if err != nil {
			t.Fatalf("call %d (+%v): err = %v", index, c.offset, err)
		}
		if ok != c.wantOK || target != c.wantTarget {
			t.Fatalf("call %d (+%v, current %d): got (%d, %t), want (%d, %t)", index, c.offset, c.current, target, ok, c.wantTarget, c.wantOK)
		}
	}
}

// 送らなかった呼び出し（1 秒以内）は、「最後に送った時刻」を進めない（0.9 秒ごとに呼んでも、1.8 秒で送れる）。
func TestSkippedCallsDoNotPostponeTheNextThrottle(t *testing.T) {
	var p Policy
	sentAt := []time.Duration{}
	for offset := time.Duration(0); offset <= 5*time.Second; offset += 900 * time.Millisecond {
		if _, ok, err := p.NextThrottle(at(offset), 4500, 3000); err != nil {
			t.Fatal(err)
		} else if ok {
			sentAt = append(sentAt, offset)
		}
	}
	want := []time.Duration{0, 1800 * time.Millisecond, 3600 * time.Millisecond}
	if len(sentAt) != len(want) {
		t.Fatalf("sent at %v, want %v", sentAt, want)
	}
	for i := range want {
		if sentAt[i] != want[i] {
			t.Fatalf("sent at %v, want %v", sentAt, want)
		}
	}
}

// 送出待ちが 1.5 秒を超え続ける 4 秒の間、抑制指示は 1 秒に 1 回まで（0・1・2・3・4 秒の 5 回）。3 秒分に達したら送出失敗の判定が出る。
func TestAThrottlingSession(t *testing.T) {
	var p Policy
	throttles := 0
	overflowAt := time.Duration(-1)
	for tick := 0; tick <= 40; tick++ {
		offset := time.Duration(tick) * 100 * time.Millisecond
		pendingMs := 1600 + tick*40 // 1.6 秒から、100 ms ごとに 40 ms ずつ積み上がる
		decision, err := p.Evaluate(pendingMs)
		if err != nil {
			t.Fatal(err)
		}
		if decision.Overflow && overflowAt < 0 {
			overflowAt = offset
		}
		if decision.Throttle {
			if _, ok, err := p.NextThrottle(at(offset), 4500, 3000); err != nil {
				t.Fatal(err)
			} else if ok {
				throttles++
			}
		}
	}
	if throttles != 5 { // 0・1・2・3・4 秒（40 ticks = 4.0 秒の間、抑制の条件が続く）
		t.Fatalf("throttles = %d, want 5 (once per second while pressure lasts)", throttles)
	}
	if overflowAt != 3500*time.Millisecond { // 1600 + 35 × 40 = 3000
		t.Fatalf("overflow at %v, want 3.5s (pending reaches 3000 ms)", overflowAt)
	}
}

func TestNextThrottleErrors(t *testing.T) {
	t.Run("目標・下限が 0 以下なら、エラー（送らない）", func(t *testing.T) {
		var p Policy
		if _, ok, err := p.NextThrottle(at(0), 0, 3000); !errors.Is(err, ErrInvalidBitrate) || ok {
			t.Fatalf("err = %v, ok = %t, want ErrInvalidBitrate", err, ok)
		}
		if _, ok, err := p.NextThrottle(at(0), 4500, 0); !errors.Is(err, ErrInvalidBitrate) || ok {
			t.Fatalf("err = %v, ok = %t, want ErrInvalidBitrate", err, ok)
		}
		// 失敗した呼び出しは、送ったことにならない
		if _, ok, err := p.NextThrottle(at(0), 4500, 3000); err != nil || !ok {
			t.Fatalf("after the failures: ok = %t, err = %v, want a throttle", ok, err)
		}
	})

	t.Run("時刻が、直前の呼び出しより前なら、エラー（同じ時刻は可）", func(t *testing.T) {
		var p Policy
		if _, _, err := p.NextThrottle(at(5*time.Second), 4500, 3000); err != nil {
			t.Fatal(err)
		}
		if _, ok, err := p.NextThrottle(at(5*time.Second), 4500, 3000); err != nil || ok {
			t.Fatalf("same time: ok = %t, err = %v, want a skip", ok, err)
		}
		if _, ok, err := p.NextThrottle(at(5*time.Second-time.Nanosecond), 4500, 3000); !errors.Is(err, ErrTimeRegression) || ok {
			t.Fatalf("err = %v, ok = %t, want ErrTimeRegression", err, ok)
		}
	})
}

// 独立したインスタンスを、複数のゴルーチンで使っても競合しない（グローバルな状態を持たない。-race で確かめる）。
func TestConcurrentUseOfIndependentInstances(t *testing.T) {
	results := make(chan error, 6)
	for worker := 0; worker < 6; worker++ {
		go func() {
			var p Policy
			for i := 0; i < 1_000; i++ {
				if _, err := p.Evaluate(i * 5); err != nil {
					results <- err
					return
				}
				if _, _, err := p.NextThrottle(at(time.Duration(i)*50*time.Millisecond), 4500, 3000); err != nil {
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
	var utc, local Policy
	if _, _, err := utc.NextThrottle(at(5*time.Second), 4500, 3000); err != nil {
		t.Fatal(err)
	}
	if _, _, err := local.NextThrottle(at(5*time.Second).In(jst), 4500, 3000); err != nil {
		t.Fatal(err)
	}
	_, _, errUTC := utc.NextThrottle(at(time.Second), 4500, 3000)
	_, _, errJST := local.NextThrottle(at(time.Second).In(jst), 4500, 3000)
	if !errors.Is(errUTC, ErrTimeRegression) || errUTC.Error() != errJST.Error() {
		t.Fatalf("UTC: %v\nJST: %v", errUTC, errJST)
	}
}
