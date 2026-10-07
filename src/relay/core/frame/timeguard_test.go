package frame

// 時刻の整合（TimeGuard）の検査。
//
// 同じ種別（映像・音声）で時刻が逆行するフレームは破棄する。前方への飛びは、復帰時の空白として受け入れる。
// 種別ごとに独立。制御メッセージは時刻を持たない（0）ので、対象にしない。

import (
	"errors"
	"math"
	"strings"
	"testing"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

func mediaFrame(frameType contract.FrameType, timestampUs uint64) Frame {
	return Frame{Type: frameType, TimestampUs: timestampUs}
}

func TestTimeGuardAdmit(t *testing.T) {
	const (
		video = contract.FrameTypeVideo
		audio = contract.FrameTypeAudio
	)
	type step struct {
		kind        contract.FrameType
		timestampUs uint64
		wantAdmit   bool
	}
	cases := []struct {
		name  string
		steps []step
	}{
		{"最初のフレームは、どの値でも受け入れる（映像）", []step{{video, 9_000_000_000, true}}},
		{"最初のフレームは、どの値でも受け入れる（音声・0）", []step{{audio, 0, true}}},
		{"増加は受け入れる", []step{{video, 0, true}, {video, 33_333, true}, {video, 66_667, true}, {video, 100_000, true}}},
		{"同じ時刻は、逆行ではないので受け入れる", []step{{video, 100, true}, {video, 100, true}, {audio, 7, true}, {audio, 7, true}}},
		{"1 マイクロ秒の逆行を破棄する（映像）", []step{{video, 100, true}, {video, 99, false}}},
		{"1 マイクロ秒の逆行を破棄する（音声）", []step{{audio, 100, true}, {audio, 99, false}}},
		{"大きな逆行（先頭へ戻る）を破棄する", []step{{video, 60_000_000, true}, {video, 0, false}}},
		{"前方への飛びは、復帰時の空白として受け入れる（10 秒・30 秒）", []step{
			{video, 1_000_000, true}, {video, 11_000_000, true}, {video, 41_000_000, true}, {video, 41_033_333, true},
		}},
		{"破棄したフレームは、状態を変えない", []step{
			{video, 100, true}, {video, 50, false}, {video, 100, true}, {video, 99, false}, {video, 101, true}, {video, 100, false},
		}},
		{"映像と音声は独立（映像の逆行は、音声に影響しない）", []step{
			{video, 1_000, true}, {audio, 500, true}, {video, 999, false}, {audio, 501, true}, {audio, 499, false}, {video, 1_001, true},
		}},
		{"種別ごとに、最初のフレームは別に受け入れる（音声が映像より小さくてもよい）", []step{
			{video, 5_000_000, true}, {audio, 4_990_000, true}, {audio, 5_013_220, true}, {video, 5_033_333, true},
		}},
		{"2^53 を超える時刻を、整数のまま比較する", []step{
			{video, 1<<53 + 1, true}, {video, 1 << 53, false}, {video, 1<<53 + 1, true}, {video, 1<<53 + 2, true},
		}},
		{"最大値の後は、最大値だけを受け入れる", []step{
			{audio, math.MaxUint64, true}, {audio, math.MaxUint64, true}, {audio, math.MaxUint64 - 1, false},
		}},
		{"2^63 を超える時刻（符号付き 64 ビットを超える）も、符号なしとして比較する", []step{
			{video, 1 << 63, true}, {video, 1<<63 - 1, false}, {video, 1<<63 + 1, true},
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var guard TimeGuard
			for index, s := range c.steps {
				err := guard.Admit(mediaFrame(s.kind, s.timestampUs))
				if s.wantAdmit {
					if err != nil {
						t.Fatalf("step %d (type %#04x, %d): err = %v, want admitted", index, uint8(s.kind), s.timestampUs, err)
					}
					continue
				}
				if err == nil {
					t.Fatalf("step %d (type %#04x, %d): admitted, want a regression", index, uint8(s.kind), s.timestampUs)
				}
				assertCode(t, err, CodeTimeRegression)
			}
		})
	}
}

func TestTimeGuardIgnoresControlFrames(t *testing.T) {
	var guard TimeGuard
	if err := guard.Admit(mediaFrame(contract.FrameTypeVideo, 1_000)); err != nil {
		t.Fatal(err)
	}
	for _, frameType := range contract.FrameTypes() {
		if frameType == contract.FrameTypeVideo || frameType == contract.FrameTypeAudio {
			continue
		}
		// 制御メッセージ（時刻 0 など）は、対象外。映像・音声の状態に影響しない
		if err := guard.Admit(mediaFrame(frameType, 0)); err != nil {
			t.Errorf("type %#04x: err = %v, want admitted (not a media frame)", uint8(frameType), err)
		}
	}
	if err := guard.Admit(mediaFrame(contract.FrameTypeVideo, 999)); err == nil {
		t.Error("video 999 after 1000: admitted, want a regression (control frames must not reset the state)")
	}
	if err := guard.Admit(mediaFrame(contract.FrameTypeAudio, 0)); err != nil {
		t.Errorf("first audio 0: err = %v (control frames must not create an audio state)", err)
	}
}

func TestTimeGuardErrorDetail(t *testing.T) {
	var guard TimeGuard
	if err := guard.Admit(Frame{Type: contract.FrameTypeAudio, TimestampUs: 23_220, Body: []byte("dummy-body-should-not-appear")}); err != nil {
		t.Fatal(err)
	}
	err := guard.Admit(Frame{Type: contract.FrameTypeAudio, TimestampUs: 23_219, Body: []byte("dummy-body-should-not-appear")})
	if err == nil {
		t.Fatal("regression admitted")
	}

	var typed *Error
	if !errors.As(err, &typed) || typed.Code != CodeTimeRegression {
		t.Fatalf("error = %v, want a typed %s", err, CodeTimeRegression)
	}
	for _, want := range []string{"time_regression", "23219", "23220"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error text %q lacks %q (the discarded time and the last admitted time)", err.Error(), want)
		}
	}
	if strings.Contains(err.Error(), "dummy-body") {
		t.Errorf("error text exposes the body: %q", err.Error())
	}
}

func TestTimeGuardZeroValueIsReady(t *testing.T) {
	var guard TimeGuard
	if err := guard.Admit(mediaFrame(contract.FrameTypeVideo, 0)); err != nil {
		t.Fatalf("zero value: err = %v", err)
	}
	// 別のインスタンスは、状態を共有しない
	var other TimeGuard
	if err := other.Admit(mediaFrame(contract.FrameTypeVideo, 0)); err != nil {
		t.Fatalf("other instance: err = %v", err)
	}
}

// 映像・音声が交互に届く、実際の配信に近い列（映像 30 fps・音声 1,024 サンプル）を、すべて受け入れる。
func TestTimeGuardAdmitsARealisticInterleavedStream(t *testing.T) {
	var guard TimeGuard
	roundHalfUp := func(numerator, denominator uint64) uint64 { return (2*numerator + denominator) / (2 * denominator) }
	var videoFrame, audioSamples uint64
	for second := 0; second < 600; second++ {
		for i := 0; i < 30; i++ {
			videoTime := roundHalfUp(videoFrame*1_000_000, 30)
			if err := guard.Admit(mediaFrame(contract.FrameTypeVideo, videoTime)); err != nil {
				t.Fatalf("video frame %d: %v", videoFrame, err)
			}
			videoFrame++
		}
		for audioSamples < uint64(second+1)*44100 {
			audioTime := roundHalfUp(audioSamples*1_000_000, 44100)
			if err := guard.Admit(mediaFrame(contract.FrameTypeAudio, audioTime)); err != nil {
				t.Fatalf("audio at %d samples: %v", audioSamples, err)
			}
			audioSamples += 1024
		}
	}
}
