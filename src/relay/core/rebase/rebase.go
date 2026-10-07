// Package rebase は、時刻の再基準化（requirements.md 11.10・15 章の「時刻の再基準化」）です。
//
// ブラウザが付けたメディア時刻（音声の累積サンプル数を基準とするマイクロ秒）を、RTMPS（FLV）へ送るときの時刻
// （32 ビットのミリ秒）へ直します。
//
//   - RTMPS の接続ごとに、時刻を 0 起点へ再基準化します（OnConnect の後の最初のメディアフレームの時刻が起点。映像と音声で共通）。
//     以後は、(時刻 − 起点 − 補正量) ÷ 1000 の切り捨てです（差分を積み上げず、毎回、累積値から算出します。丸め誤差を持ち込みません）。
//   - 中断からの復帰（OnResume）では、復帰後の最初のフレームで、欠落区間を詰めて時刻を連続させます。映像と音声には、同一の補正量を
//     適用します（同期を保ちます）。詳細は TimestampRebaser。
//   - 出力は、負にならず、種別ごとに単調非減少です。実時計を読みません（時刻は引数）。
package rebase

import (
	"fmt"
	"math"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// NominalFrameIntervalUs は、映像 1 フレームの通常の間隔（マイクロ秒）。音声 1,470 サンプル（44,100 ÷ 30）に当たり、
// 33,333（切り捨て）。復帰のとき、欠落区間を詰めても、最大でこの 1 フレーム分の間隔を残す。
const NominalFrameIntervalUs = contract.AudioSamplesPerVideoFrame * 1000000 / contract.AudioSampleRateHz

// mediaKinds は、時刻を持つ種別の数（映像・音声）。
const mediaKinds = 2

// microsecondsPerMillisecond は、FLV の時刻（ミリ秒）への換算。
const microsecondsPerMillisecond = 1000

// Error は、このパッケージのエラー（定数。errors.Is で判定できる）。
type Error string

func (e Error) Error() string { return string(e) }

const (
	// ErrNotConnected は、OnConnect の前に Rebase を呼んだ。
	ErrNotConnected Error = "rebase: not connected (call OnConnect first)"
	// ErrUnsupportedKind は、映像・音声以外の種別を渡した。
	ErrUnsupportedKind Error = "rebase: unsupported kind (only video and audio frames carry media time)"
	// ErrTimeOutOfRange は、メディア時刻が int64 に収まらない（2^63 以上）、または出力の計算が桁あふれする。
	ErrTimeOutOfRange Error = "rebase: media time out of range"
	// ErrTimestampOverflow は、出力が、FLV の 32 ビットのミリ秒に収まらない。
	ErrTimestampOverflow Error = "rebase: output exceeds the 32-bit millisecond FLV timestamp"
)

// Output は、再基準化の結果。
type Output struct {
	// TimeMs は、FLV タグ（RTMP メッセージ）へ付ける時刻（ミリ秒）。
	TimeMs uint32
	// Adjusted は、入力の時刻が、出力を負にする（起点より前）か、同じ種別の直前の出力より前になるため、出力を引き上げた（0、または
	// 直前の出力に揃えた）とき true。時刻の順に並んだ入力では起きない。起きたら、上流の並びを疑う手がかりになる。
	Adjusted bool
}

// kindIndex は、映像・音声の種別を、状態の添字にする。映像・音声でなければ、false。
func kindIndex(kind contract.FrameType) (int, bool) {
	switch kind {
	case contract.FrameTypeVideo:
		return 0, true
	case contract.FrameTypeAudio:
		return 1, true
	}
	return 0, false
}

// subtract は、a − b を、桁あふれを検出して計算する。
func subtract(a, b int64) (int64, bool) {
	c := a - b
	if (b > 0 && c > a) || (b < 0 && c < a) {
		return 0, false
	}
	return c, true
}

// TimestampRebaser は、1 つの取り込みセッション（1 つの RTMPS 接続の送出）の時刻の再基準化。ゼロ値は未接続（OnConnect が要る）。
// ゴルーチンから並行に呼ばない。
//
// 内部は、「出力 = 入力 − 基準」（基準は、起点 + 補正量。マイクロ秒）という 1 つの値で、映像と音声に共通。
//
//   - OnConnect の後の最初のフレーム：基準 = そのフレームの時刻（出力 0）。
//   - OnResume の後の最初のフレーム（時刻 F）：復帰前の最大の入力時刻 L との間隔 g = F − L から、残す間隔
//     a = min(max(g, 0), NominalFrameIntervalUs) を決め、出力が「復帰前の最大の出力 + a」になるよう、基準を取り直す。
//     つまり、空白が 1 フレーム分を超えたら、超えた分を詰める（補正量に加算する）。1 フレーム分以下なら、そのまま（補正しない）。
//     復帰後の最初のフレームが復帰前の最後より前の時刻（ブラウザのクロックの巻き戻り）でも、出力は戻らず、復帰前の最大の出力から続く。
//   - その後のフレーム：同じ基準を使う。
//
// 時刻（入力）は、int64 に収まる値（2^63 未満）に限る。出力は、32 ビットのミリ秒（49.7 日）に収まる値に限る。
// エラーを返した呼び出しは、状態を変えない。
type TimestampRebaser struct {
	connected     bool
	anchored      bool // この接続の最初のメディアフレームで、起点が決まった
	resumePending bool // 復帰の後の最初のフレームを、待っている
	baseUs        int64
	maxInUs       int64 // 起点（または直前の復帰）以降の、最大の入力時刻
	maxOutUs      int64 // 同じ区間の、最大の出力（マイクロ秒。ミリ秒へ切り捨てる前）
	lastOutUs     [mediaKinds]int64
	seenKind      [mediaKinds]bool
}

// OnConnect は、RTMPS の接続が成立したときに呼ぶ。起点・補正・直近の時刻・保留中の復帰を、すべて消し、
// 次の最初のメディアフレームの時刻を、新しい起点（出力 0）にする。
func (r *TimestampRebaser) OnConnect() {
	*r = TimestampRebaser{connected: true}
}

// OnResume は、中断からの復帰（ブラウザの再接続。RTMPS の接続は保持されている）のときに呼ぶ。
// 次のメディアフレームで、欠落区間を詰める。起点が決まる前（フレームが 1 つも無い）なら、何も起こさない。
// 続けて呼んでも、1 回と同じ。
func (r *TimestampRebaser) OnResume() {
	if r.anchored {
		r.resumePending = true
	}
}

// Rebase は、1 つのメディアフレーム（kind は video か audio）のメディア時刻（マイクロ秒）を、FLV の時刻へ直す。
func (r *TimestampRebaser) Rebase(kind contract.FrameType, mediaTimeUs uint64) (Output, error) {
	index, media := kindIndex(kind)
	if !media {
		return Output{}, fmt.Errorf("%w: type 0x%02x", ErrUnsupportedKind, uint8(kind))
	}
	if !r.connected {
		return Output{}, ErrNotConnected
	}
	if mediaTimeUs > math.MaxInt64 {
		return Output{}, fmt.Errorf("%w: %d us does not fit in int64", ErrTimeOutOfRange, mediaTimeUs)
	}
	t := int64(mediaTimeUs)

	base := r.baseUs
	switch {
	case !r.anchored:
		base = t
	case r.resumePending:
		advance := t - r.maxInUs
		if advance < 0 {
			advance = 0
		}
		if advance > NominalFrameIntervalUs {
			advance = NominalFrameIntervalUs
		}
		base = t - (r.maxOutUs + advance)
	}

	out, fits := subtract(t, base)
	if !fits {
		return Output{}, fmt.Errorf("%w: time %d us with base %d us", ErrTimeOutOfRange, t, base)
	}
	adjusted := false
	if out < 0 {
		out = 0
		adjusted = true
	}
	if r.seenKind[index] && out < r.lastOutUs[index] {
		out = r.lastOutUs[index]
		adjusted = true
	}
	ms := out / microsecondsPerMillisecond
	if ms > math.MaxUint32 {
		return Output{}, fmt.Errorf("%w: %d ms", ErrTimestampOverflow, ms)
	}

	// ここまで成功したときだけ、状態を更新する
	r.baseUs = base
	switch {
	case !r.anchored:
		r.anchored = true
		r.maxInUs = t
		r.maxOutUs = out
	case r.resumePending:
		r.resumePending = false
		r.maxInUs = t
		r.maxOutUs = out
	default:
		if t > r.maxInUs {
			r.maxInUs = t
		}
		if out > r.maxOutUs {
			r.maxOutUs = out
		}
	}
	r.lastOutUs[index] = out
	r.seenKind[index] = true
	return Output{TimeMs: uint32(ms), Adjusted: adjusted}, nil
}
