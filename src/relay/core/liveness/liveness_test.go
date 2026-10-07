package liveness

// 心拍の応答の喪失の判定（HeartbeatLiveness）の検査（requirements.md 11.10・13.2・27）。
//
//   - 心拍の応答が 60 秒得られなければ、送出を止めて取り込みセッションを閉じる（真）。59.9 秒は偽、60 秒ちょうどで真
//   - 応答が得られたら復帰（60 秒の数え直し）
//   - 数え始めは、最後に応答が得られた時刻。応答がまだ 1 度も無いときは、最初の観測（失敗）の時刻

import (
	"errors"
	"testing"
	"time"
)

func epoch() time.Time { return time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC) }

func at(offset time.Duration) time.Time { return epoch().Add(offset) }

func mustObserve(t *testing.T, l *HeartbeatLiveness, ok bool, offset time.Duration) {
	t.Helper()
	if err := l.Observe(ok, at(offset)); err != nil {
		t.Fatalf("Observe(%t, +%v) = %v", ok, offset, err)
	}
}

func TestNothingObservedNeverStops(t *testing.T) {
	var l HeartbeatLiveness
	for _, offset := range []time.Duration{0, time.Minute, 24 * time.Hour} {
		if l.ShouldStop(at(offset)) {
			t.Errorf("ShouldStop(+%v) = true before any observation", offset)
		}
	}
}

func TestStopsSixtySecondsAfterTheLastResponse(t *testing.T) {
	cases := []struct {
		name   string
		offset time.Duration // 最後の成功から
		want   bool
	}{
		{"直後", 0, false},
		{"2 秒（心拍 1 回分）", 2 * time.Second, false},
		{"30 秒", 30 * time.Second, false},
		{"59.9 秒は、偽", 59*time.Second + 900*time.Millisecond, false},
		{"60 秒に 1 ナノ秒足りない", 60*time.Second - time.Nanosecond, false},
		{"60 秒ちょうどで、真", 60 * time.Second, true},
		{"60.1 秒", 60*time.Second + 100*time.Millisecond, true},
		{"10 分", 10 * time.Minute, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var l HeartbeatLiveness
			mustObserve(t, &l, true, 100*time.Second)
			if got := l.ShouldStop(at(100*time.Second + c.offset)); got != c.want {
				t.Fatalf("ShouldStop(last success + %v) = %t, want %t", c.offset, got, c.want)
			}
		})
	}
}

func TestStopsSixtySecondsAfterTheFirstObservationWhenNeverSucceeded(t *testing.T) {
	var l HeartbeatLiveness
	mustObserve(t, &l, false, 10*time.Second) // 最初の観測が失敗：ここから数える
	for second := 12; second <= 69; second += 2 {
		mustObserve(t, &l, false, time.Duration(second)*time.Second)
	}
	if l.ShouldStop(at(10*time.Second + 59*time.Second + 900*time.Millisecond)) {
		t.Fatal("ShouldStop 59.9 s after the first failure = true")
	}
	if !l.ShouldStop(at(70 * time.Second)) {
		t.Fatal("ShouldStop 60 s after the first failure = false")
	}
}

func TestASuccessResetsTheCount(t *testing.T) {
	var l HeartbeatLiveness
	mustObserve(t, &l, true, 0)
	for second := 2; second <= 50; second += 2 { // 50 秒間、失敗が続く
		mustObserve(t, &l, false, time.Duration(second)*time.Second)
	}
	if l.ShouldStop(at(59 * time.Second)) {
		t.Fatal("stopped at 59 s")
	}
	mustObserve(t, &l, true, 52*time.Second) // 応答が戻る
	// 以後、60 秒の数え直し（52 + 60 = 112 秒）
	if l.ShouldStop(at(60 * time.Second)) {
		t.Fatal("stopped at 60 s although a response arrived at 52 s")
	}
	if l.ShouldStop(at(111*time.Second + 900*time.Millisecond)) {
		t.Fatal("stopped 59.9 s after the recovery")
	}
	if !l.ShouldStop(at(112 * time.Second)) {
		t.Fatal("not stopped 60 s after the recovery")
	}
}

func TestFailuresAfterASuccessDoNotMoveTheCount(t *testing.T) {
	var l HeartbeatLiveness
	mustObserve(t, &l, true, 10*time.Second)
	mustObserve(t, &l, false, 12*time.Second)
	mustObserve(t, &l, false, 14*time.Second)
	mustObserve(t, &l, false, 69*time.Second)
	if l.ShouldStop(at(69*time.Second + 900*time.Millisecond)) {
		t.Fatal("stopped 59.9 s after the last success")
	}
	if !l.ShouldStop(at(70 * time.Second)) {
		t.Fatal("not stopped 60 s after the last success (failures must not restart the count)")
	}
}

func TestAlternatingResponsesNeverStop(t *testing.T) {
	var l HeartbeatLiveness
	for second := 0; second < 600; second += 2 {
		mustObserve(t, &l, second%20 < 18, time.Duration(second)*time.Second) // 18 秒成功・2 秒失敗の繰り返し
		if l.ShouldStop(at(time.Duration(second) * time.Second)) {
			t.Fatalf("stopped at %d s although a response arrives every 20 s", second)
		}
	}
}

func TestObserveErrors(t *testing.T) {
	var l HeartbeatLiveness
	mustObserve(t, &l, true, 5*time.Second)
	mustObserve(t, &l, false, 5*time.Second) // 同じ時刻は可
	if err := l.Observe(true, at(5*time.Second-time.Nanosecond)); !errors.Is(err, ErrTimeRegression) {
		t.Fatalf("err = %v, want ErrTimeRegression", err)
	}
	// 失敗した観測は、状態を変えない
	if !l.ShouldStop(at(65 * time.Second)) {
		t.Fatal("the rejected observation must not move the count (last success at 5 s)")
	}
}

// 問い合わせ（ShouldStop）は、状態を変えない。先の時刻で尋ねても、続きの観測ができる。
func TestShouldStopDoesNotChangeState(t *testing.T) {
	var l HeartbeatLiveness
	mustObserve(t, &l, true, 0)
	if !l.ShouldStop(at(time.Hour)) {
		t.Fatal("want stop an hour later")
	}
	mustObserve(t, &l, true, 2*time.Second)
	if l.ShouldStop(at(3 * time.Second)) {
		t.Fatal("a later query must not have changed the state")
	}
}

// 独立したインスタンスを、複数のゴルーチンで使っても競合しない（グローバルな状態を持たない。-race で確かめる）。
func TestConcurrentUseOfIndependentInstances(t *testing.T) {
	results := make(chan error, 6)
	for worker := 0; worker < 6; worker++ {
		go func() {
			var l HeartbeatLiveness
			for i := 0; i < 1_000; i++ {
				offset := time.Duration(i) * 2 * time.Second
				if err := l.Observe(i%3 != 0, at(offset)); err != nil {
					results <- err
					return
				}
				if l.ShouldStop(at(offset)) {
					results <- errors.New("stopped although responses keep arriving")
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
	var utc, local HeartbeatLiveness
	mustObserve(t, &utc, true, 5*time.Second)
	if err := local.Observe(true, at(5*time.Second).In(jst)); err != nil {
		t.Fatal(err)
	}
	errUTC := utc.Observe(true, at(time.Second))
	errJST := local.Observe(true, at(time.Second).In(jst))
	if !errors.Is(errUTC, ErrTimeRegression) || errUTC.Error() != errJST.Error() {
		t.Fatalf("UTC: %v\nJST: %v", errUTC, errJST)
	}
}
