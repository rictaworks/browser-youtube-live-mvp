package backend

import "time"

// SystemWaiter は、実時間の待機（本番）。試験は、疑似の Waiter を注入して、待機を実時間で待たない。
type SystemWaiter struct{}

// After は、time.After と同じ。
func (SystemWaiter) After(d time.Duration) <-chan time.Time { return time.After(d) }
