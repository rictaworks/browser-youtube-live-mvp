// Package liveness は、心拍の応答の喪失の判定（requirements.md 11.10・13.2・27）です。
//
// 中継は、アプリケーションへ 2 秒間隔で心拍を送ります。その応答が 60 秒得られなければ、中継は自ら送出を止めて、
// 取り込みセッションを閉じます（致命通知 heartbeat_lost。メディアの転送は、制御面の 60 秒以内の不達で止まりません）。
package liveness

import (
	"fmt"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// stopAfter は、心拍の応答が得られないまま、これだけ経ったら、送出を止める（relay.heartbeat_lost_stop_seconds）。
const stopAfter = contract.RelayHeartbeatLostStopSeconds * time.Second

// Error は、このパッケージのエラー（定数。errors.Is で判定できる）。
type Error string

func (e Error) Error() string { return string(e) }

// ErrTimeRegression は、直前の観測より前の時刻を渡した。
const ErrTimeRegression Error = "liveness: time went backward"

// HeartbeatLiveness は、心拍の応答の途絶の集計。ゼロ値が使える。ゴルーチンから並行に呼ばない。
//
// 数え始めは、最後に応答が得られた時刻。応答がまだ 1 度も得られていないときは、最初の観測（失敗）の時刻
// （心拍の応答が 60 秒得られないことを、心拍を始めたときから数える）。
type HeartbeatLiveness struct {
	anchored  bool
	anchor    time.Time
	latest    time.Time
	hasLatest bool
}

// Observe は、心拍の 1 回の結果を、時刻 now で記録する。ok は、応答が得られたか（応答の中身が「停止の指示」でも、応答は応答）。
// 成功すると、数え始めが now に戻る（復帰）。失敗は、数え始めを動かさない。
// now が直前の観測より前なら ErrTimeRegression（同じ時刻は可）。エラーのとき、状態は変わらない。
func (l *HeartbeatLiveness) Observe(ok bool, now time.Time) error {
	if l.hasLatest && now.Before(l.latest) {
		return fmt.Errorf("%w: now=%d latest=%d (unix nanoseconds)", ErrTimeRegression, now.UnixNano(), l.latest.UnixNano())
	}
	l.latest = now
	l.hasLatest = true
	if ok || !l.anchored {
		l.anchor = now
		l.anchored = true
	}
	return nil
}

// ShouldStop は、心拍の応答が、数え始めから 60 秒（以上）得られていなければ true（送出を止め、取り込みセッションを閉じる）。
// 59.9 秒は偽、60 秒ちょうどで真。観測が 1 つも無ければ偽。状態を変えない。
func (l *HeartbeatLiveness) ShouldStop(now time.Time) bool {
	return l.anchored && now.Sub(l.anchor) >= stopAfter
}
