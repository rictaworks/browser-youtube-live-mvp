package wsapi

import "time"

// 試験だけが使う、link の内部への入口（本番のコードには置かない）。

// lastActivity は、相手から最後に何かが届いた時刻（時計の値）。
func (l *link) lastActivity() time.Time {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.lastRecv
}
