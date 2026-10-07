// Package buffer は、送出待ちバッファの方針（requirements.md 11.10、ws-protocol.md の 5.12・9 章）です。
//
// 送出待ちのバッファは 3 秒分を上限とします。1.5 秒分を超えた時点で、ブラウザへ抑制指示（throttle）を送ります。上限（3 秒分）に
// 達したら、送出失敗（事象 publish_failed・原因 buffer_overflow）として中断へ移り、バッファを破棄して RTMPS を再接続します
// （その実行は、呼び出し側の取り込みセッションの仕事です）。
package buffer

import (
	"fmt"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

const (
	// throttleAboveMs は、送出待ちがこれを超えたら、抑制指示（relay.egress_throttle_ms）。
	throttleAboveMs = contract.RelayEgressThrottleMs
	// overflowAtMs は、送出待ちがこれに達したら、送出失敗（relay.egress_buffer_limit_ms）。
	overflowAtMs = contract.RelayEgressBufferLimitMs

	// throttleKeepPercent は、抑制指示の目標ビットレートの、現在の目標に対する割合（%）。仕様に数値の定めが無いための解釈で、
	// ブラウザの適応制御の「30% 引き下げ」（12 章。adaptive.conditions.backlog_high_twice.decrease_percent）と同じ割合にする。
	throttleKeepPercent = 100 - contract.AdaptiveConditionsBacklogHighTwiceDecreasePercent
	// throttleMinInterval は、抑制指示を送る間隔の下限（1 秒に 1 回まで）。仕様に数値の定めが無いための解釈で、
	// 「目標ビットレートの変更は 1 秒あたり 1 回を上限とする」（12 章。adaptive.target_change_min_interval_ms）に合わせる。
	throttleMinInterval = contract.AdaptiveTargetChangeMinIntervalMs * time.Millisecond

	percent = 100
)

// Error は、このパッケージのエラー（定数。errors.Is で判定できる）。
type Error string

func (e Error) Error() string { return string(e) }

const (
	// ErrNegativePending は、負の滞留（ミリ秒）を渡した。
	ErrNegativePending Error = "buffer: negative pending time"
	// ErrInvalidBitrate は、現在の目標・下限が、正の整数（kbps）でない。
	ErrInvalidBitrate Error = "buffer: bitrate must be a positive integer"
	// ErrTimeRegression は、直前の呼び出しより前の時刻を渡した。
	ErrTimeRegression Error = "buffer: time went backward"
)

// Decision は、送出待ちの量に対する判定。
type Decision struct {
	// Throttle は、1.5 秒分を超えている（抑制指示を送る）。上限に達しているときも真。
	Throttle bool
	// Overflow は、3 秒分（上限）に達した（送出失敗。バッファを破棄して RTMPS を再接続する）。
	Overflow bool
}

// Policy は、送出待ちバッファの方針。ゼロ値が使える。ゴルーチンから並行に呼ばない。
// 抑制指示を送る間隔（1 秒に 1 回まで）の状態だけを持つ。
type Policy struct {
	sent      bool
	lastSent  time.Time
	latest    time.Time
	hasLatest bool
}

// Evaluate は、送出待ちの量（ミリ秒分）を判定する。1.5 秒分（1,500 ms）を超えたら Throttle、3 秒分（3,000 ms）に達したら Overflow
// （1,500 ちょうどは超えていない。3,000 ちょうどは達している）。pendingMs が負なら ErrNegativePending。状態を変えない。
func (p *Policy) Evaluate(pendingMs int) (Decision, error) {
	if pendingMs < 0 {
		return Decision{}, fmt.Errorf("%w: %d ms", ErrNegativePending, pendingMs)
	}
	return Decision{Throttle: pendingMs > throttleAboveMs, Overflow: pendingMs >= overflowAtMs}, nil
}

// ThrottleTarget は、抑制指示の目標ビットレート（kbps）を返す。現在の目標の 70%（切り捨て）で、下限（プロファイルの映像ビットレートの
// 下限）を下回らない。現在の目標・下限が正の整数でなければ ErrInvalidBitrate（結果は常に正）。
// 現在の目標が下限以下のときは、下限（ブラウザは、min(現在の目標, 指示) で受けるので、目標は上がらない）。
func ThrottleTarget(current, floor int) (int, error) {
	if current <= 0 || floor <= 0 {
		return 0, fmt.Errorf("%w: current=%d floor=%d", ErrInvalidBitrate, current, floor)
	}
	// current × 70 ÷ 100 の切り捨てと同じ値を、桁あふれせずに求める（current = 100q + r なら、70q + 70r ÷ 100 の切り捨て）
	reduced := current/percent*throttleKeepPercent + current%percent*throttleKeepPercent/percent
	if reduced < floor {
		return floor, nil
	}
	return reduced, nil
}

// NextThrottle は、抑制指示を、いま送ってよいかを判定し、送ってよければ、その目標ビットレート（ThrottleTarget）を返す。
// 1 秒に 1 回まで：最後に送ってから 1 秒（以上）経っていなければ、(0, false, nil)。ちょうど 1 秒で、また送れる。
// 送らなかった呼び出しは、「最後に送った時刻」を進めない。
// 目標・下限が不正なら ErrInvalidBitrate、now が直前の呼び出しより前なら ErrTimeRegression（同じ時刻は可）。
// エラーのとき、状態は変わらない。
func (p *Policy) NextThrottle(now time.Time, current, floor int) (int, bool, error) {
	target, err := ThrottleTarget(current, floor)
	if err != nil {
		return 0, false, err
	}
	if p.hasLatest && now.Before(p.latest) {
		return 0, false, fmt.Errorf("%w: now=%d latest=%d (unix nanoseconds)", ErrTimeRegression, now.UnixNano(), p.latest.UnixNano())
	}
	p.latest = now
	p.hasLatest = true
	if p.sent && now.Sub(p.lastSent) < throttleMinInterval {
		return 0, false, nil
	}
	p.sent = true
	p.lastSent = now
	return target, true, nil
}
