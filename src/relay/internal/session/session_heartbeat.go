package session

import (
	"context"
	"errors"
	"log/slog"
	"math"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
)

// 心拍（requirements.md 11.9・13.2。契約 internal-api.md の heartbeat）。
// 2 秒間隔で、送出の統計とブラウザ側の出来事を送り、応答で指示（継続・停止）と状態の通知を受ける。
// 応答が 60 秒得られなければ、中継が自ら送出を止めて、取り込みセッションを閉じる（processDue の HeartbeatLiveness）。
// アプリケーションが不達の間も、60 秒以内は、メディアの転送を止めない。

// heartbeatState は、心拍の状態（ループのゴルーチンだけが扱う）。
type heartbeatState struct {
	seq      int                       // 最後に作った心拍の連番（最初の心拍が 1）
	pending  *backend.HeartbeatRequest // 応答を得られていない心拍。同じ連番・同じ内容で再送する
	inFlight bool                      // 呼び出しの最中（重ねて送らない）
	next     time.Time                 // 次の拍の時刻
	lastOK   time.Time                 // 最後に応答を得た時刻（60 秒の数え始め）
	failures int                       // 連続の失敗の数（記録を間引くため）
	sentMark uint64                    // 最後に作った心拍の時点の、送出量の積算（バイト）
	rateAt   time.Time                 // 最後に作った心拍の時刻（送出ビットレートの算出）
}

func newHeartbeatState(now time.Time, interval time.Duration) heartbeatState {
	return heartbeatState{next: now.Add(interval), lastOK: now, rateAt: now}
}

// tickHeartbeat は、拍の時刻が来たら、心拍を送る。前の心拍の応答待ちの間は、重ねて送らない。
func (s *IngestSession) tickHeartbeat(now time.Time) {
	if now.Before(s.hb.next) {
		return
	}
	s.hb.next = now.Add(s.opts.HeartbeatInterval)
	if s.epoch < 1 {
		// 送出世代が決まる前（照合の結果を得る前。台帳が、他のセッションを閉じ終えるのを待つ間など）は、送らない。
		// 世代 0 の心拍は、アプリケーションに古い世代と受け取られ、stale_epoch の停止の指示で、取り込みセッションを止めかねない。
		// 連番も使わない（世代が決まったあとの最初の心拍が、連番 1）。拍の時刻だけが進む
		return
	}
	if s.hb.inFlight {
		return
	}
	if s.hb.pending == nil {
		s.hb.pending = s.buildHeartbeat(now)
	}
	request := *s.hb.pending
	request.Epoch = s.epoch // 再送のときも、いまの世代で送る（世代が進んでいれば、古い世代の再送で止まらない）
	epoch := s.epoch
	s.hb.inFlight = true
	s.spawn("heartbeat", func() {
		response, err := s.deps.Backend.Heartbeat(s.ctx, s.id, request)
		s.post(func() { s.onHeartbeatDone(epoch, response, err) })
	})
}

// totalSent は、RTMPS へ送った量の積算（バイト）。接続し直した Publisher の分も足す。
func (s *IngestSession) totalSent() uint64 {
	total := s.sentBase
	if s.pub != nil {
		total += s.pub.SentBytes()
	}
	return total
}

// buildHeartbeat は、新しい心拍を作る。直近のブラウザの状態報告と、前回の心拍以降に届いた出来事すべて（欠落なく）を載せる。
func (s *IngestSession) buildHeartbeat(now time.Time) *backend.HeartbeatRequest {
	total := s.totalSent()
	var delta uint64
	if total > s.hb.sentMark {
		delta = total - s.hb.sentMark
	}
	s.hb.seq++
	request := &backend.HeartbeatRequest{
		Seq:            s.hb.seq,
		Publishing:     s.pub != nil && s.phase == phaseStreaming,
		OutKbps:        kbps(delta, now.Sub(s.hb.rateAt)),
		SentBytesDelta: delta,
	}
	s.hb.sentMark, s.hb.rateAt = total, now
	if s.report != nil {
		report := *s.report
		report.Events = s.browserEvents
		s.browserEvents = nil
		request.Browser = &report
	}
	return request
}

// kbps は、elapsed の間に bytes バイトを送ったときの、ビットレート（kbps。1 kbps = 1,000 bit/s。切り捨て）。
func kbps(bytes uint64, elapsed time.Duration) int {
	ms := elapsed.Milliseconds()
	if ms <= 0 {
		return 0
	}
	value := bytes * 8 / uint64(ms)
	if value > math.MaxInt32 {
		return math.MaxInt32
	}
	return int(value)
}

// onHeartbeatDone は、心拍の結果を処理する。応答が得られたら（中身が停止の指示でも）、60 秒の数え始めを戻す。
// 得られなければ、同じ心拍を、次の拍で再送する。
func (s *IngestSession) onHeartbeatDone(epoch int, response backend.HeartbeatResponse, err error) {
	s.hb.inFlight = false
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}
		if observeErr := s.liveness.Observe(false, s.t); observeErr != nil {
			s.log.Error("heartbeat observation failed", slog.String("class", errorClass(observeErr)))
		}
		s.hb.failures++
		if failures := s.hb.failures; failures&(failures-1) == 0 {
			s.log.Warn("the heartbeat was not answered", slog.String("class", errorClass(err)), slog.Int("failures", failures))
		}
		return
	}
	s.hb.failures = 0
	s.hb.lastOK = s.t
	if observeErr := s.liveness.Observe(true, s.t); observeErr != nil {
		s.log.Error("heartbeat observation failed", slog.String("class", errorClass(observeErr)))
	}
	if response.Command == backend.CommandStop && response.Reason == backend.ReasonStaleEpoch && epoch < s.epoch {
		// 自分が世代を進める前に送った心拍への応答。無視して、いまの世代で、同じ心拍を再送する
		return
	}
	s.hb.pending = nil
	s.applyHeartbeat(response)
}

// applyHeartbeat は、心拍の応答の指示と通知を処理する。
//   - 通知（notices）は、順に status としてブラウザへ転送する
//   - 停止（stop）は、送出を止め、取り込みセッションを閉じる。終了理由があれば、ブラウザへ status(ended) と
//     fatal(broadcast_ended) を送る（通知に終了の status が無ければ、中継が終了理由から作る）
//   - 送出世代が古い（stale_epoch）なら、その接続への送出を止め、fatal(stale_epoch) のうえ閉じる
func (s *IngestSession) applyHeartbeat(response backend.HeartbeatResponse) {
	if response.Command == backend.CommandStop && response.Reason == backend.ReasonStaleEpoch {
		s.log.Warn("the application reports a newer epoch; stopping")
		s.closeWith(planStaleEpoch())
		return
	}
	endedForwarded := false
	for _, notice := range response.Notices {
		if notice.State == contract.BroadcastStateEnded {
			endedForwarded = true
		}
		if src := s.src; src != nil {
			s.sendStatus(src, s.statusOf(notice))
		}
	}
	if response.Command != backend.CommandStop {
		return
	}
	if src := s.src; src != nil && response.EndReason != "" && !endedForwarded {
		s.sendStatus(src, statusFields{State: contract.BroadcastStateEnded, EndReason: response.EndReason})
	}
	s.log.Info("the application told the relay to stop", slog.String("end_reason", string(response.EndReason)))
	s.closeWith(planStop())
}
