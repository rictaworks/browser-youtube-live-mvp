package session

import "time"

// SystemClock は、実時間の時計（本番）。試験は、疑似の Clock を注入する。
type SystemClock struct{}

// Now は、time.Now と同じ。
func (SystemClock) Now() time.Time { return time.Now() }

// AfterFunc は、time.AfterFunc と同じ。
func (SystemClock) AfterFunc(d time.Duration, f func()) Timer { return time.AfterFunc(d, f) }
