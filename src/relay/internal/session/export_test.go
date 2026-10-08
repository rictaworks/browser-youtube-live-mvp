package session

// 試験だけが使う、取り込みセッション・台帳の内部への入口（本番のコードには置かない）。

// barrier は、受信の待ち行列にすでにある処理（と、時計の進みで期限の来た処理）が終わるのを待つ。
// 期限の評価は、待ち行列の項目を 1 つ処理するたびに行われるので、時計を進めたあとに barrier を呼べば、期限の処理も済む。
func (s *IngestSession) barrier() {
	done := make(chan struct{})
	select {
	case s.inbox <- item{sync: done}:
	case <-s.loopExited:
		return
	}
	select {
	case <-done:
	case <-s.loopExited:
	}
}

// workerCount は、動いている作業のゴルーチン（照合の応答・準備・接続・心拍・Publisher の見張り・後始末）の数。
func (s *IngestSession) workerCount() int { return int(s.workers.Load()) }

// pendingWorkers は、台帳が動かしている作業（照合の応答の処理）の数。
func (r *Registry) pendingWorkers() int { return int(r.inflight.Load()) }

// sessionsSnapshot は、台帳にある取り込みセッション（閉じる手順に入ったものを含む）。
func (r *Registry) sessionsSnapshot() []*IngestSession { return r.snapshot() }
