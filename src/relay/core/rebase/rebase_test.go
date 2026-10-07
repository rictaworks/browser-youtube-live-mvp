package rebase

// 時刻の再基準化（TimestampRebaser）の検査（requirements.md 11.10・15 章の「時刻の再基準化」）。
//
//   - RTMPS の接続ごとに、時刻を 0 起点へ再基準化する（最初のメディアフレームの時刻が起点。映像と音声で共通）
//   - 復帰時は、欠落区間を詰めて時刻を連続させる（最大でフレーム 1 枚分の通常の間隔を残す）。映像と音声に同一の補正量
//   - 出力は、FLV の 32 ビットのミリ秒。負にならず、単調非減少（種別ごと）。実時計を参照しない（時刻は引数）
//
// 表形式の例（手計算できる数値）と、固定のシードの乱数列によるプロパティ風の検査の両方で確かめる。

import (
	"errors"
	"math"
	"math/rand/v2"
	"testing"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

const (
	video = contract.FrameTypeVideo
	audio = contract.FrameTypeAudio
)

// step は、再基準化に対する 1 つの操作。frame のときは、入力の時刻と、期待する出力（ミリ秒・補正の有無）を持つ。
type step struct {
	op           string // "connect" | "resume" | "frame"
	kind         contract.FrameType
	us           uint64
	wantMs       uint32
	wantAdjusted bool
}

func connect() step                   { return step{op: "connect"} }
func resume() step                    { return step{op: "resume"} }
func v(us uint64, wantMs uint32) step { return step{op: "frame", kind: video, us: us, wantMs: wantMs} }
func a(us uint64, wantMs uint32) step { return step{op: "frame", kind: audio, us: us, wantMs: wantMs} }
func (s step) adjusted() step         { s.wantAdjusted = true; return s }

// play は、操作を順に実行し、各フレームの出力を期待と比べる。
func play(t *testing.T, steps []step) *TimestampRebaser {
	t.Helper()
	r := &TimestampRebaser{}
	for index, s := range steps {
		switch s.op {
		case "connect":
			r.OnConnect()
		case "resume":
			r.OnResume()
		case "frame":
			got, err := r.Rebase(s.kind, s.us)
			if err != nil {
				t.Fatalf("step %d (type %#04x, %d µs): err = %v", index, uint8(s.kind), s.us, err)
			}
			if got.TimeMs != s.wantMs || got.Adjusted != s.wantAdjusted {
				t.Fatalf("step %d (type %#04x, %d µs): got {%d ms, adjusted=%t}, want {%d ms, adjusted=%t}",
					index, uint8(s.kind), s.us, got.TimeMs, got.Adjusted, s.wantMs, s.wantAdjusted)
			}
		default:
			t.Fatalf("step %d: unknown op %q", index, s.op)
		}
	}
	return r
}

func TestNominalFrameInterval(t *testing.T) {
	// 映像 1 フレーム = 音声 1,470 サンプル（44,100 ÷ 30）= 33,333 マイクロ秒（切り捨て）
	if NominalFrameIntervalUs != 33_333 {
		t.Fatalf("NominalFrameIntervalUs = %d, want 33333", NominalFrameIntervalUs)
	}
	for _, profile := range contract.ProfileValues() {
		limits, ok := contract.ProfileLimitsOf(profile)
		if !ok {
			t.Fatalf("no limits for profile %q", profile)
		}
		if NominalFrameIntervalUs != 1_000_000/limits.Framerate {
			t.Errorf("NominalFrameIntervalUs = %d does not match one frame at %d fps (profile %s)", NominalFrameIntervalUs, limits.Framerate, profile)
		}
	}
}

func TestRebase(t *testing.T) {
	cases := []struct {
		name  string
		steps []step
	}{
		{"新しい接続は 0 から始まる（最初のフレームの時刻が起点。以後は、起点からの経過をミリ秒で）", []step{
			connect(),
			v(5_000_000, 0), a(5_000_000, 0), v(5_033_333, 33), a(5_023_220, 23), v(5_066_667, 66), a(6_000_000, 1000),
		}},
		{"起点は映像・音声で共通（音声が先に届いても、同じ起点）", []step{
			connect(),
			a(1_000_000, 0), v(1_000_000, 0), v(1_033_333, 33), a(1_023_220, 23),
		}},
		{"ミリ秒への変換は切り捨て（差分を積み上げず、毎回、累積から算出する）", []step{
			connect(),
			v(0, 0), v(999, 0), v(1_000, 1), v(1_999, 1), v(2_000, 2), v(33_333, 33), v(66_667, 66), v(1_000_000, 1000),
		}},
		{"接続ごとに 0 起点へ再基準化する（OnConnect で、起点も補正も作り直す）", []step{
			connect(),
			v(5_000_000, 0), v(6_000_000, 1000),
			connect(),
			v(9_000_000, 0), a(9_023_220, 23), v(9_033_333, 33),
		}},
		{"復帰（空白 10 秒）：欠落を詰め、1 フレーム分（33 ms）の間隔を残して連続させる。映像と音声に同一の補正量", []step{
			connect(),
			v(0, 0), a(0, 0), v(1_000_000, 1000), a(1_010_000, 1010), // 音声が 10 ms 先
			resume(),
			// 復帰前の最後は 1,010,000（出力 1010）。空白は 10 秒。出力は 1010 + 33 = 1043 から続く
			v(11_010_000, 1043), a(11_020_000, 1053), v(11_043_333, 1076), a(11_043_220, 1076),
		}},
		{"復帰（空白 30 秒）", []step{
			connect(),
			v(0, 0), v(2_000_000, 2000), a(2_000_000, 2000),
			resume(),
			v(32_000_000, 2033), a(32_000_000, 2033), v(32_033_333, 2066), a(32_023_220, 2056),
		}},
		{"空白が 1 フレーム分以下なら、詰めない（そのまま）", []step{
			connect(),
			v(0, 0), v(1_000_000, 1000),
			resume(),
			v(1_020_000, 1020), a(1_040_000, 1040),
		}},
		{"空白がちょうど 1 フレーム分（33,333 µs）なら、詰めない", []step{
			connect(),
			v(0, 0), v(1_000_000, 1000),
			resume(),
			v(1_033_333, 1033),
		}},
		{"空白が 1 フレーム分を超えたら、超えた分だけを詰める（40 ms → 33 ms を残す）", []step{
			connect(),
			v(0, 0), v(1_000_000, 1000),
			resume(),
			v(1_040_000, 1033), v(1_073_333, 1066),
		}},
		{"復帰後の最初のフレームが、復帰前の最後より前の時刻（クロックの巻き戻り）でも、出力は戻らず、続きから進む", []step{
			connect(),
			v(600_000_000, 0), v(601_000_000, 1000),
			resume(),
			v(0, 1000), a(23_220, 1023), v(33_333, 1033),
		}},
		{"復帰の前に、フレームが 1 つも無ければ、復帰は影響しない（最初のフレームが起点）", []step{
			connect(),
			resume(),
			v(7_000_000, 0), v(7_033_333, 33),
		}},
		{"復帰の前にフレームが無ければ、復帰は影響しない（起点のあとの 100 ms の間隔も、そのまま）", []step{
			connect(),
			resume(),
			v(7_000_000, 0), v(7_100_000, 100), v(7_200_000, 200),
		}},
		{"クロックの巻き戻りの復帰のあとは、新しい時間軸で、次の復帰の空白を測る", []step{
			connect(),
			v(600_000_000, 0), v(601_000_000, 1000),
			resume(),
			v(0, 1000), v(33_333, 1033),
			resume(),
			v(10_033_333, 1066), v(10_066_666, 1099),
		}},
		{"OnResume を続けて 2 回呼んでも、1 回と同じ", []step{
			connect(),
			v(0, 0), v(1_000_000, 1000),
			resume(), resume(),
			v(11_000_000, 1033), v(11_033_333, 1066),
		}},
		{"復帰は、フレームが届くまで保留される（OnResume のあとの最初のフレームだけが、補正を決める）", []step{
			connect(),
			v(0, 0), v(1_000_000, 1000),
			resume(),
			v(21_000_000, 1033), v(21_033_333, 1066), v(21_066_667, 1100),
		}},
		{"復帰が 2 回あっても、それぞれの空白を詰める", []step{
			connect(),
			v(0, 0),
			resume(),
			v(10_000_000, 33), v(10_033_333, 66),
			resume(),
			v(50_000_000, 99), v(50_033_333, 133),
		}},
		{"復帰の直後（次のフレームの前）に、もう一度復帰しても、出力は連続する（復帰後の最初の出力が、最大の出力になる）", []step{
			connect(),
			v(0, 0),
			resume(),
			v(10_000_000, 33),
			resume(),
			v(20_000_000, 66), v(20_033_333, 99),
		}},
		{"OnConnect は、保留中の復帰も消す（新しい接続は、復帰の補正ではなく、新しい起点）", []step{
			connect(),
			v(0, 0), v(1_000_000, 1000),
			resume(),
			connect(),
			v(50_000_000, 0), v(50_033_333, 33),
		}},
		{"起点より前の時刻のフレームは、負にならないよう 0 に揃える（補正したと分かる）", []step{
			connect(),
			v(1_000_000, 0), a(990_000, 0).adjusted(), a(1_000_000, 0), a(1_023_220, 23),
		}},
		{"復帰後の最初のフレームより前の別種別は、その種別の直前の出力を下回らない（補正したと分かる）", []step{
			connect(),
			v(0, 0), v(990_000, 990), a(1_000_000, 1000),
			resume(),
			v(5_000_000, 1033), a(4_960_000, 1000).adjusted(), a(5_000_000, 1033),
		}},
		{"2^62 のような大きな起点でも、起点からの経過で算出する", []step{
			connect(),
			v(1<<62, 0), v(1<<62+33_333, 33), a(1<<62+23_220, 23),
		}},
		{"起点が int64 の最大でも、桁あふれしない", []step{
			connect(),
			v(math.MaxInt64, 0),
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { play(t, c.steps) })
	}
}

func TestRebaseErrors(t *testing.T) {
	t.Run("OnConnect の前（ゼロ値）は、未接続のエラー", func(t *testing.T) {
		var r TimestampRebaser
		if _, err := r.Rebase(video, 0); !errors.Is(err, ErrNotConnected) {
			t.Fatalf("err = %v, want ErrNotConnected", err)
		}
		r.OnResume() // 未接続での OnResume は、何も起こさない
		if _, err := r.Rebase(audio, 0); !errors.Is(err, ErrNotConnected) {
			t.Fatalf("err = %v, want ErrNotConnected", err)
		}
		r.OnConnect()
		if _, err := r.Rebase(audio, 5); err != nil {
			t.Fatalf("after OnConnect: err = %v", err)
		}
	})

	t.Run("映像・音声以外の種別は、受け付けない", func(t *testing.T) {
		r := &TimestampRebaser{}
		r.OnConnect()
		for _, frameType := range contract.FrameTypes() {
			if frameType == video || frameType == audio {
				continue
			}
			if _, err := r.Rebase(frameType, 0); !errors.Is(err, ErrUnsupportedKind) {
				t.Errorf("type %#04x: err = %v, want ErrUnsupportedKind", uint8(frameType), err)
			}
		}
		if _, err := r.Rebase(contract.FrameType(0x00), 0); !errors.Is(err, ErrUnsupportedKind) {
			t.Errorf("type 0x00: err = %v, want ErrUnsupportedKind", err)
		}
		// 受け付けなかった呼び出しは、起点を決めない
		got, err := r.Rebase(video, 9_000_000)
		if err != nil || got.TimeMs != 0 {
			t.Fatalf("first accepted frame = (%+v, %v), want 0 ms", got, err)
		}
	})

	t.Run("int64 に収まらない時刻は、エラー（状態は変わらない）", func(t *testing.T) {
		for _, bad := range []uint64{1 << 63, 1<<63 + 1, math.MaxUint64} {
			r := &TimestampRebaser{}
			r.OnConnect()
			if _, err := r.Rebase(video, bad); !errors.Is(err, ErrTimeOutOfRange) {
				t.Fatalf("time %d: err = %v, want ErrTimeOutOfRange", bad, err)
			}
			got, err := r.Rebase(video, 1_000_000)
			if err != nil || got.TimeMs != 0 {
				t.Fatalf("after the error: (%+v, %v), want the first frame to be the origin (0 ms)", got, err)
			}
		}
	})

	t.Run("32 ビットのミリ秒に収まらない出力は、エラー（状態は変わらない）。収まる最大は通る", func(t *testing.T) {
		const maxMsUs = uint64(math.MaxUint32) * 1000
		r := &TimestampRebaser{}
		r.OnConnect()
		if _, err := r.Rebase(video, 0); err != nil {
			t.Fatal(err)
		}
		got, err := r.Rebase(video, maxMsUs+999)
		if err != nil || got.TimeMs != math.MaxUint32 {
			t.Fatalf("max = (%+v, %v), want %d ms", got, err, uint32(math.MaxUint32))
		}
		if _, err := r.Rebase(video, maxMsUs+1_000); !errors.Is(err, ErrTimestampOverflow) {
			t.Fatalf("err = %v, want ErrTimestampOverflow", err)
		}
		// 失敗した呼び出しは、状態を変えない（もう一度、最大を呼んでも、補正なしで同じ値）
		got, err = r.Rebase(video, maxMsUs+999)
		if err != nil || got.TimeMs != math.MaxUint32 || got.Adjusted {
			t.Fatalf("after the error: (%+v, %v), want %d ms unadjusted", got, err, uint32(math.MaxUint32))
		}
	})

	t.Run("復帰で起点が負になった後に、大きな時刻が来ても、桁あふれせずエラー", func(t *testing.T) {
		r := play(t, []step{
			connect(),
			v(1_000_000, 0), v(2_000_000, 1000),
			resume(),
			v(0, 1000), // クロックの巻き戻り。以後の基準は負になる
		})
		if _, err := r.Rebase(video, math.MaxInt64); !errors.Is(err, ErrTimeOutOfRange) {
			t.Fatalf("err = %v, want ErrTimeOutOfRange (no wraparound)", err)
		}
		got, err := r.Rebase(video, 33_333)
		if err != nil || got.TimeMs != 1033 {
			t.Fatalf("after the error: (%+v, %v), want 1033 ms", got, err)
		}
	})
}

// 同じ操作の列は、同じ出力を返す（実時計・乱数・グローバルな状態に依存しない）。インスタンスは互いに独立。
func TestRebaseIsDeterministicAndInstancesAreIndependent(t *testing.T) {
	steps := []step{
		connect(), v(0, 0), a(0, 0), v(1_000_000, 1000), resume(), v(11_000_000, 1033), a(11_010_000, 1043),
	}
	play(t, steps)
	play(t, steps)

	// 独立したインスタンスを、複数のゴルーチンで使っても競合しない（グローバルな状態を持たない。-race で確かめる）
	results := make(chan error, 6)
	for worker := 0; worker < 6; worker++ {
		go func() {
			r := &TimestampRebaser{}
			r.OnConnect()
			var last uint32
			for i := uint64(0); i < 2000; i++ {
				got, err := r.Rebase(video, i*33_333)
				if err != nil {
					results <- err
					return
				}
				if got.TimeMs < last {
					results <- errors.New("output went backward")
					return
				}
				last = got.TimeMs
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

// ---------------------------------------------------------------------------
// プロパティ風の検査（固定のシードの乱数列）
// ---------------------------------------------------------------------------

// roundDiv は、numerator ÷ denominator を四捨五入する整数演算（契約の時刻の算出式。(2n + d) ÷ 2d の切り捨て）。
func roundDiv(numerator, denominator uint64) uint64 {
	return (2*numerator + denominator) / (2 * denominator)
}

// browserClock は、ブラウザのメディアクロック（映像はフレーム番号、音声は累積サンプル数から、毎回算出する）。
type browserClock struct {
	videoFrame   uint64
	audioSamples uint64
}

func (c *browserClock) videoUs() uint64 { return roundDiv(c.videoFrame*1_000_000, 30) }
func (c *browserClock) audioUs() uint64 { return roundDiv(c.audioSamples*1_000_000, 44100) }

// next は、時刻の順（同じ時刻なら映像が先）に、次のフレームを返し、クロックを進める。
func (c *browserClock) next() (contract.FrameType, uint64) {
	videoTime, audioTime := c.videoUs(), c.audioUs()
	if videoTime <= audioTime {
		c.videoFrame++
		return video, videoTime
	}
	c.audioSamples += 1024
	return audio, audioTime
}

// jump は、空白の間（ブラウザが符号化結果を捨てている間）、クロックだけが進む様子。
func (c *browserClock) jump(gapUs uint64) {
	c.videoFrame += gapUs * 30 / 1_000_000
	c.audioSamples += gapUs * 44100 / 1_000_000
}

// epoch は、同じ補正（起点）が続く区間。接続の直後と、復帰の直後に、新しい区間が始まる。
type epoch struct {
	firstInUs  uint64
	firstOutMs uint32
	lastIn     map[contract.FrameType]uint64
	lastOut    map[contract.FrameType]uint32
}

// runScenario は、1 つの乱数列で、接続・復帰・フレームを流し、すべての不変条件を検査する。出力の列を返す（決定性の検査用）。
func runScenario(t *testing.T, seed uint64) []uint32 {
	t.Helper()
	rng := rand.New(rand.NewPCG(seed, 18))
	clock := &browserClock{}
	r := &TimestampRebaser{}
	r.OnConnect()

	var (
		outputs       []uint32
		current       *epoch
		pendingResume bool
		lastOutMs     [2]uint32 // [映像, 音声] の直前の出力
		seen          [2]bool
		anyOutMs      uint32
		anySeen       bool
		maxIn         uint64
		beforeResume  uint32 // 復帰の直前までの、最大の出力
	)
	index := func(kind contract.FrameType) int {
		if kind == video {
			return 0
		}
		return 1
	}
	startEpoch := func() { current = nil }

	for i := 0; i < 4000; i++ {
		switch roll := rng.IntN(400); {
		case roll == 0 && anySeen: // 復帰（ブラウザの接続が切れて戻った）。空白は 0〜60 秒
			gap := uint64(rng.IntN(60_000_000))
			clock.jump(gap)
			r.OnResume()
			pendingResume = true
			beforeResume = anyOutMs
			startEpoch()
			continue
		case roll == 1: // RTMPS の再接続。新しい起点
			clock.jump(uint64(rng.IntN(5_000_000)))
			r.OnConnect()
			pendingResume = false
			seen = [2]bool{}
			anySeen = false
			anyOutMs = 0
			maxIn = 0
			startEpoch()
			continue
		}

		kind, us := clock.next()
		got, err := r.Rebase(kind, us)
		if err != nil {
			t.Fatalf("seed %d, event %d: Rebase(%#04x, %d) err = %v", seed, i, uint8(kind), us, err)
		}
		outputs = append(outputs, got.TimeMs)
		k := index(kind)

		if got.Adjusted {
			t.Fatalf("seed %d, event %d: a time-ordered input must not need adjusting (type %#04x, %d µs → %d ms)", seed, i, uint8(kind), us, got.TimeMs)
		}
		if seen[k] && got.TimeMs < lastOutMs[k] {
			t.Fatalf("seed %d, event %d: output of the same kind went backward: %d -> %d ms", seed, i, lastOutMs[k], got.TimeMs)
		}
		if anySeen && got.TimeMs < anyOutMs {
			t.Fatalf("seed %d, event %d: output went backward (time-ordered input): %d -> %d ms", seed, i, anyOutMs, got.TimeMs)
		}

		switch {
		case current == nil && !anySeen && !pendingResume:
			// 接続の直後の最初のフレーム：起点（0）
			if got.TimeMs != 0 {
				t.Fatalf("seed %d, event %d: first frame of a connection = %d ms, want 0", seed, i, got.TimeMs)
			}
			current = &epoch{firstInUs: us, firstOutMs: got.TimeMs, lastIn: map[contract.FrameType]uint64{}, lastOut: map[contract.FrameType]uint32{}}
		case current == nil && pendingResume:
			// 復帰の直後の最初のフレーム：復帰前の最大の出力から、1 フレーム分（33,333 µs）以内の間隔で続く
			delta := int64(got.TimeMs) - int64(beforeResume)
			if delta < 0 || delta > 34 {
				t.Fatalf("seed %d, event %d: first output after the resume is %d ms after the last output before it, want 0..34 (one frame interval at most)", seed, i, delta)
			}
			if us >= maxIn {
				gap := us - maxIn
				if gap <= NominalFrameIntervalUs && (delta < int64(gap/1000)-1 || delta > int64(gap/1000)+1) {
					t.Fatalf("seed %d, event %d: a gap of %d µs (<= one frame) must not be compressed, but the output advanced %d ms", seed, i, gap, delta)
				}
			}
			pendingResume = false
			current = &epoch{firstInUs: us, firstOutMs: got.TimeMs, lastIn: map[contract.FrameType]uint64{}, lastOut: map[contract.FrameType]uint32{}}
		default:
			// 同じ区間の中：起点からの経過を、そのままミリ秒に直した値（差分を積み上げず、ずれない）。切り捨ての 1 ms 以内
			elapsedMs := (us - current.firstInUs) / 1000
			drift := int64(got.TimeMs) - int64(current.firstOutMs) - int64(elapsedMs)
			if drift < 0 || drift > 1 {
				t.Fatalf("seed %d, event %d: drift %d ms from the epoch origin (input +%d µs, output %d -> %d ms)", seed, i, drift, us-current.firstInUs, current.firstOutMs, got.TimeMs)
			}
		}

		// 映像と音声の相対差が、同じ区間では、入力どおりに保たれる（復帰の前後で、同じ補正量が両方に掛かっている）
		for otherKind, otherIn := range current.lastIn {
			if otherKind == kind {
				continue
			}
			inputDelta := (int64(us) - int64(otherIn)) / 1000
			outputDelta := int64(got.TimeMs) - int64(current.lastOut[otherKind])
			if diff := outputDelta - inputDelta; diff < -1 || diff > 1 {
				t.Fatalf("seed %d, event %d: audio/video offset changed within an epoch: input %d ms, output %d ms", seed, i, inputDelta, outputDelta)
			}
		}
		current.lastIn[kind] = us
		current.lastOut[kind] = got.TimeMs

		lastOutMs[k] = got.TimeMs
		seen[k] = true
		anyOutMs = got.TimeMs
		anySeen = true
		if us > maxIn {
			maxIn = us
		}
	}
	return outputs
}

func TestRebaseProperties(t *testing.T) {
	seeds := 200
	if testing.Short() {
		seeds = 20
	}
	for seed := 0; seed < seeds; seed++ {
		first := runScenario(t, uint64(seed))
		second := runScenario(t, uint64(seed))
		if len(first) != len(second) {
			t.Fatalf("seed %d: different lengths %d and %d", seed, len(first), len(second))
		}
		for i := range first {
			if first[i] != second[i] {
				t.Fatalf("seed %d: output %d differs between two runs (%d and %d): not deterministic", seed, i, first[i], second[i])
			}
		}
	}
}

// 10 時間の配信（復帰なし）で、出力が、起点からの経過の切り捨てと、毎回完全に一致する（丸め誤差を積み上げない。11.6）。
func TestNoDriftOverTenHours(t *testing.T) {
	const origin = 123_456_789
	r := &TimestampRebaser{}
	r.OnConnect()

	const tenHoursUs = uint64(10) * 3600 * 1_000_000
	clock := &browserClock{}
	var frames int
	for {
		kind, us := clock.next()
		if us >= tenHoursUs {
			break
		}
		got, err := r.Rebase(kind, origin+us)
		if err != nil {
			t.Fatalf("frame %d: %v", frames, err)
		}
		if want := uint32(us / 1000); got.TimeMs != want || got.Adjusted {
			t.Fatalf("frame %d (type %#04x, +%d µs): got {%d ms, adjusted=%t}, want %d ms exactly", frames, uint8(kind), us, got.TimeMs, got.Adjusted, want)
		}
		frames++
	}
	if frames < 2_000_000 {
		t.Fatalf("only %d frames were checked; the stream is shorter than expected", frames)
	}
}
