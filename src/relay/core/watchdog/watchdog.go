// Package watchdog は、メディアの無通信の検出（requirements.md 13.2・ws-protocol.md の 9 章）です。
//
// 送出中に、映像または音声のフレームが 5 秒届かなければ、中断と判定します（事象 interrupted・原因 media_stalled）。
// 送出の開始前と、復帰待ちの間は、判定しません。
package watchdog

import (
	"fmt"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// stallAfter は、フレームが届かないまま、これだけ経ったら、無通信とする（relay.media_stall_seconds）。
const stallAfter = contract.RelayMediaStallSeconds * time.Second

// Error は、このパッケージのエラー（定数。errors.Is で判定できる）。
type Error string

func (e Error) Error() string { return string(e) }

const (
	// ErrNotMedia は、映像・音声以外の種別を渡した（制御メッセージは、無通信の判定に使わない）。
	ErrNotMedia Error = "watchdog: not a media frame (only video and audio are watched)"
	// ErrTimeRegression は、直前の観測より前の時刻を渡した。
	ErrTimeRegression Error = "watchdog: time went backward"
)

// MediaWatchdog は、映像・音声それぞれの、最後のフレームの時刻を保持する。ゼロ値は、監視していない状態（Arm が要る）。
// ゴルーチンから並行に呼ばない。
type MediaWatchdog struct {
	armed     bool
	lastVideo time.Time
	lastAudio time.Time
	latest    time.Time
	hasLatest bool
}

// Arm は、監視を始める（送出の開始、または復帰の完了のとき）。映像・音声のどちらも、now から 5 秒の猶予を持つ
// （まだ 1 枚も届いていなくてよい）。すでに監視中なら、数え直す。
// now が直前の観測より前なら ErrTimeRegression（状態は変わらない）。
func (w *MediaWatchdog) Arm(now time.Time) error {
	if w.hasLatest && now.Before(w.latest) {
		return fmt.Errorf("%w: now=%d latest=%d (unix nanoseconds)", ErrTimeRegression, now.UnixNano(), w.latest.UnixNano())
	}
	w.armed = true
	w.lastVideo = now
	w.lastAudio = now
	w.latest = now
	w.hasLatest = true
	return nil
}

// Disarm は、監視をやめる（復帰待ちに入るとき）。次の Arm まで、Stalled は偽を返し、OnFrame は何もしない。
func (w *MediaWatchdog) Disarm() {
	w.armed = false
}

// OnFrame は、映像か音声のフレームが届いたことを、時刻 now で記録する。kind が映像・音声でなければ ErrNotMedia。
// 監視していない間（Arm の前・Disarm の後）に届いたフレームは、無視する（エラーにしない）。
// now が直前の観測より前なら ErrTimeRegression（同じ時刻は可）。エラーのとき、状態は変わらない。
func (w *MediaWatchdog) OnFrame(kind contract.FrameType, now time.Time) error {
	if kind != contract.FrameTypeVideo && kind != contract.FrameTypeAudio {
		return fmt.Errorf("%w: type 0x%02x", ErrNotMedia, uint8(kind))
	}
	if !w.armed {
		return nil
	}
	if now.Before(w.latest) {
		return fmt.Errorf("%w: now=%d latest=%d (unix nanoseconds)", ErrTimeRegression, now.UnixNano(), w.latest.UnixNano())
	}
	if kind == contract.FrameTypeVideo {
		w.lastVideo = now
	} else {
		w.lastAudio = now
	}
	w.latest = now
	return nil
}

// Stalled は、監視中に、映像または音声のどちらかが、5 秒（以上）届いていなければ true（中断）。
// 5 秒ちょうどで真、4.999 秒は偽。監視していなければ偽。状態を変えない。
func (w *MediaWatchdog) Stalled(now time.Time) bool {
	if !w.armed {
		return false
	}
	return now.Sub(w.lastVideo) >= stallAfter || now.Sub(w.lastAudio) >= stallAfter
}
