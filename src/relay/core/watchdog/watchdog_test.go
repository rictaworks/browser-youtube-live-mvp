package watchdog

// メディアの無通信の検出（MediaWatchdog）の検査（requirements.md 13.2・ws-protocol.md 9 章）。
//
//   - 送出中に、映像または音声のフレームが 5 秒届かなければ真（中断。原因 media_stalled）
//   - 送出の開始前・復帰待ちの間は判定しない（Arm の前・Disarm の後）
//   - 5 秒ちょうどで真（4.999 秒は偽）

import (
	"errors"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

const (
	video = contract.FrameTypeVideo
	audio = contract.FrameTypeAudio
)

func epoch() time.Time { return time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC) }

func at(offset time.Duration) time.Time { return epoch().Add(offset) }

func mustFrame(t *testing.T, w *MediaWatchdog, kind contract.FrameType, offset time.Duration) {
	t.Helper()
	if err := w.OnFrame(kind, at(offset)); err != nil {
		t.Fatalf("OnFrame(%#04x, +%v) = %v", uint8(kind), offset, err)
	}
}

func TestNotArmedNeverStalls(t *testing.T) {
	var w MediaWatchdog
	for _, offset := range []time.Duration{0, 5 * time.Second, time.Hour} {
		if w.Stalled(at(offset)) {
			t.Errorf("Stalled(+%v) = true before Arm", offset)
		}
	}
	// 送出の開始前に届いたフレームは、状態を作らない（Arm のとき、改めて数え始める）
	mustFrame(t, &w, video, 0)
	mustFrame(t, &w, audio, 0)
	if w.Stalled(at(time.Hour)) {
		t.Error("frames before Arm must not arm the watchdog")
	}
}

func TestStalledWhenNoFrameArrivesAfterArming(t *testing.T) {
	cases := []struct {
		offset time.Duration
		want   bool
	}{
		{0, false},
		{4*time.Second + 999*time.Millisecond, false},
		{5*time.Second - time.Nanosecond, false},
		{5 * time.Second, true}, // 映像も音声も、5 秒届かない
		{6 * time.Second, true},
		{time.Hour, true},
	}
	for _, c := range cases {
		var w MediaWatchdog
		w.mustArm(t, 10*time.Second)
		if got := w.Stalled(at(10*time.Second + c.offset)); got != c.want {
			t.Errorf("Stalled(arm + %v) = %t, want %t", c.offset, got, c.want)
		}
	}
}

func TestEachKindIsWatchedSeparately(t *testing.T) {
	t.Run("映像だけが届き続けても、音声が 5 秒届かなければ真", func(t *testing.T) {
		var w MediaWatchdog
		w.mustArm(t, 0)
		for ms := 0; ms <= 6000; ms += 33 {
			mustFrame(t, &w, video, time.Duration(ms)*time.Millisecond)
			if ms < 5000 && w.Stalled(at(time.Duration(ms)*time.Millisecond)) {
				t.Fatalf("stalled too early at +%d ms", ms)
			}
		}
		if !w.Stalled(at(6 * time.Second)) {
			t.Fatal("audio never arrived for 6 s: want stalled")
		}
	})

	t.Run("音声だけが届き続けても、映像が 5 秒届かなければ真", func(t *testing.T) {
		var w MediaWatchdog
		w.mustArm(t, 0)
		for ms := 0; ms <= 5000; ms += 23 {
			mustFrame(t, &w, audio, time.Duration(ms)*time.Millisecond)
		}
		if !w.Stalled(at(5000 * time.Millisecond)) {
			t.Fatal("video never arrived for 5 s: want stalled")
		}
	})

	t.Run("両方が届いていれば、偽。最後のフレームから、ちょうど 5 秒で、その種別が真", func(t *testing.T) {
		var w MediaWatchdog
		w.mustArm(t, 0)
		mustFrame(t, &w, video, 4*time.Second)
		mustFrame(t, &w, audio, 4500*time.Millisecond)
		cases := []struct {
			offset time.Duration
			want   bool
		}{
			{5 * time.Second, false},                     // 映像の最後から 1 秒・音声から 0.5 秒
			{9*time.Second - time.Nanosecond, false},     // 映像の最後から 5 秒に足りない
			{9 * time.Second, true},                      // 映像の最後（4 秒）からちょうど 5 秒
			{9*time.Second + 500*time.Millisecond, true}, // 音声も 5 秒
			{3 * time.Second, false},                     // 最後のフレームより前の時刻で尋ねても、偽（経過が負）
		}
		for _, c := range cases {
			if got := w.Stalled(at(c.offset)); got != c.want {
				t.Errorf("Stalled(+%v) = %t, want %t", c.offset, got, c.want)
			}
		}
	})

	t.Run("フレームが届くたびに、その種別の 5 秒が数え直される", func(t *testing.T) {
		var w MediaWatchdog
		w.mustArm(t, 0)
		for second := 1; second <= 20; second++ { // 毎秒、両方が届く
			mustFrame(t, &w, video, time.Duration(second)*time.Second)
			mustFrame(t, &w, audio, time.Duration(second)*time.Second)
			if w.Stalled(at(time.Duration(second)*time.Second + 4*time.Second + 999*time.Millisecond)) {
				t.Fatalf("stalled 4.999 s after the frames at %d s", second)
			}
		}
		if !w.Stalled(at(25 * time.Second)) {
			t.Fatal("5 s after the last frames: want stalled")
		}
	})

	t.Run("停止の後にフレームが届けば、その種別は回復する。両方がそろって、偽に戻る", func(t *testing.T) {
		var w MediaWatchdog
		w.mustArm(t, 0)
		mustFrame(t, &w, video, time.Second)
		mustFrame(t, &w, audio, time.Second)
		if !w.Stalled(at(6 * time.Second)) {
			t.Fatal("want stalled at +6s")
		}
		mustFrame(t, &w, video, 6*time.Second)
		if !w.Stalled(at(6 * time.Second)) {
			t.Fatal("audio is still silent: want stalled")
		}
		mustFrame(t, &w, audio, 6*time.Second)
		if w.Stalled(at(6 * time.Second)) {
			t.Fatal("both kinds arrived: want not stalled")
		}
	})
}

func TestArmAndDisarm(t *testing.T) {
	t.Run("Disarm のあとは判定しない（復帰待ち）", func(t *testing.T) {
		var w MediaWatchdog
		w.mustArm(t, 0)
		if !w.Stalled(at(10 * time.Second)) {
			t.Fatal("want stalled before Disarm")
		}
		w.Disarm()
		if w.Stalled(at(time.Hour)) {
			t.Fatal("Stalled after Disarm = true, want false (waiting for the resume)")
		}
		// 復帰待ちの間に届いたフレームは、無視する
		mustFrame(t, &w, video, 20*time.Second)
		if w.Stalled(at(time.Hour)) {
			t.Fatal("frames while disarmed must not arm the watchdog")
		}
	})

	t.Run("もう一度 Arm すると、両方の種別が、その時刻から 5 秒の猶予を持つ", func(t *testing.T) {
		var w MediaWatchdog
		w.mustArm(t, 0)
		w.Disarm()
		w.mustArm(t, 100*time.Second)
		if w.Stalled(at(104*time.Second + 999*time.Millisecond)) {
			t.Fatal("stalled 4.999 s after the second Arm")
		}
		if !w.Stalled(at(105 * time.Second)) {
			t.Fatal("not stalled 5 s after the second Arm")
		}
	})

	t.Run("Arm のやり直し（Disarm なし）も、数え直す", func(t *testing.T) {
		var w MediaWatchdog
		w.mustArm(t, 0)
		mustFrame(t, &w, video, time.Second)
		w.mustArm(t, 50*time.Second)
		if w.Stalled(at(54 * time.Second)) {
			t.Fatal("re-arming must restart both counts")
		}
	})
}

func TestOnFrameErrors(t *testing.T) {
	t.Run("映像・音声以外の種別は、エラー", func(t *testing.T) {
		var w MediaWatchdog
		w.mustArm(t, 0)
		for _, frameType := range contract.FrameTypes() {
			if frameType == video || frameType == audio {
				continue
			}
			if err := w.OnFrame(frameType, at(time.Second)); !errors.Is(err, ErrNotMedia) {
				t.Errorf("type %#04x: err = %v, want ErrNotMedia", uint8(frameType), err)
			}
		}
		// 状態は変わらない（制御メッセージは、無通信の判定に影響しない）
		if !w.Stalled(at(5 * time.Second)) {
			t.Fatal("control frames must not count as media")
		}
	})

	t.Run("時刻が、直前の観測より前なら、エラー（同じ時刻は可）", func(t *testing.T) {
		var w MediaWatchdog
		w.mustArm(t, 10*time.Second)
		mustFrame(t, &w, video, 12*time.Second)
		mustFrame(t, &w, audio, 12*time.Second)
		if err := w.OnFrame(audio, at(12*time.Second-time.Nanosecond)); !errors.Is(err, ErrTimeRegression) {
			t.Fatalf("err = %v, want ErrTimeRegression", err)
		}
		if err := w.Arm(at(11 * time.Second)); !errors.Is(err, ErrTimeRegression) {
			t.Fatalf("Arm earlier than the last observation: err = %v, want ErrTimeRegression", err)
		}
	})
}

// 独立したインスタンスを、複数のゴルーチンで使っても競合しない（グローバルな状態を持たない。-race で確かめる）。
func TestConcurrentUseOfIndependentInstances(t *testing.T) {
	results := make(chan error, 6)
	for worker := 0; worker < 6; worker++ {
		go func() {
			var w MediaWatchdog
			if err := w.Arm(at(0)); err != nil {
				results <- err
				return
			}
			for i := 1; i <= 500; i++ {
				offset := time.Duration(i) * 10 * time.Millisecond
				if err := w.OnFrame(video, at(offset)); err != nil {
					results <- err
					return
				}
				if err := w.OnFrame(audio, at(offset)); err != nil {
					results <- err
					return
				}
				if w.Stalled(at(offset)) {
					results <- errors.New("stalled while frames were arriving")
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

// mustArm は、テストの記述を短くするための補助（Arm の失敗でテストを止める）。
func (w *MediaWatchdog) mustArm(t *testing.T, offset time.Duration) {
	t.Helper()
	if err := w.Arm(at(offset)); err != nil {
		t.Fatalf("Arm(+%v) = %v", offset, err)
	}
}

// エラーの文面が、時刻の表示（ローカルのタイムゾーンの読み込み）に依存しない（同じ入力に、同じ出力。Domain Core は環境を読まない）。
func TestRegressionErrorTextDoesNotDependOnTheLocation(t *testing.T) {
	jst := time.FixedZone("JST", 9*60*60)
	var utc, local MediaWatchdog
	utc.mustArm(t, 0)
	if err := local.Arm(at(0).In(jst)); err != nil {
		t.Fatal(err)
	}
	mustFrame(t, &utc, video, 5*time.Second)
	if err := local.OnFrame(video, at(5*time.Second).In(jst)); err != nil {
		t.Fatal(err)
	}
	errUTC := utc.OnFrame(video, at(time.Second))
	errJST := local.OnFrame(video, at(time.Second).In(jst))
	if !errors.Is(errUTC, ErrTimeRegression) || errUTC.Error() != errJST.Error() {
		t.Fatalf("UTC: %v\nJST: %v", errUTC, errJST)
	}
}
