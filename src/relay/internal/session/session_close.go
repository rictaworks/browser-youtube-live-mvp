package session

import (
	"fmt"
	"log/slog"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// closePlan は、取り込みセッションの閉じ方（理由ごと）。
type closePlan struct {
	// reason は、記録に出す語彙。
	reason string
	// status は、閉じる前にブラウザへ送る status（終了）。nil なら送らない。
	status *statusFields
	// fatal は、ブラウザへ送る致命通知。空なら送らない（利用者の終了通知への応答は無い）。
	fatal contract.FatalCode
	// abort は、バッファを破棄して直ちに切る（Abort）。偽なら、送出待ちを送り切ってから切る（Close）。
	// 送出世代の交代・同一アカウントの別セッションの排他・心拍の喪失・受信量の超過・失敗は Abort。利用者の停止と時間上限は Close。
	abort bool
	// events は、session_ended の前に送る事象。
	events []contract.RelayEventKind
	// ban は、当該配信への再接続を受け付けない。
	ban bool
}

func planUserEnd() closePlan { return closePlan{reason: "user_end"} }

func planStop() closePlan {
	return closePlan{reason: "stop_command", fatal: contract.FatalCodeBroadcastEnded}
}

func planStaleEpoch() closePlan {
	return closePlan{reason: "stale_epoch", fatal: contract.FatalCodeStaleEpoch, abort: true}
}

func planHeartbeatLost() closePlan {
	return closePlan{reason: "heartbeat_lost", fatal: contract.FatalCodeHeartbeatLost, abort: true}
}

func planBitrateExceeded() closePlan {
	return closePlan{
		reason: "bitrate_exceeded", fatal: contract.FatalCodeBitrateExceeded, abort: true,
		events: []contract.RelayEventKind{contract.RelayEventKindRelayDisconnected}, ban: true,
	}
}

// planPrepareFailed は、準備の失敗で配信が終了した。終了理由が決まれば、status(ended) を先に送る。
func planPrepareFailed(reason contract.EndReason) closePlan {
	plan := closePlan{reason: "prepare_failed", fatal: contract.FatalCodeBroadcastEnded}
	if reason != "" {
		plan.status = &statusFields{State: contract.BroadcastStateEnded, EndReason: reason}
	}
	return plan
}

func planPublishFailed() closePlan {
	return closePlan{reason: "publish_failed", fatal: contract.FatalCodePublishFailed, abort: true}
}

func planEpisodeExpired() closePlan {
	return closePlan{reason: "interruption_expired", fatal: contract.FatalCodePublishFailed, abort: true}
}

func planInternalError() closePlan {
	return closePlan{reason: "internal_error", fatal: contract.FatalCodeInternalError, abort: true}
}

func planSuperseded() closePlan {
	return closePlan{reason: "superseded", fatal: contract.FatalCodeBroadcastEnded, abort: true}
}

func planShutdown() closePlan {
	return closePlan{reason: "shutdown", fatal: contract.FatalCodeInternalError}
}

func planForced() closePlan {
	return closePlan{reason: "forced", fatal: contract.FatalCodeInternalError, abort: true}
}

// requestClose は、Close の要求（台帳・停止の手順から）を、閉じ方にして実行する。
func (s *IngestSession) requestClose(reason CloseReason) {
	switch reason {
	case CloseReasonSuperseded:
		s.closeWith(planSuperseded())
	case CloseReasonForced:
		s.closeWith(planForced())
	default:
		s.closeWith(planShutdown())
	}
}

// closeWith は、取り込みセッションを終わりに向かわせる。ブラウザへ、終了の status と致命通知を送って接続を閉じ、事象を送る。
// 配信キー・バッファ・RTMPS の後始末は、ループを抜けたあとの finish が行う（時間がかかり得るので、ここでは待たない）。
func (s *IngestSession) closeWith(plan closePlan) {
	if s.phase == phaseClosed {
		return
	}
	s.plan = plan
	src := s.src
	s.src = nil
	s.setPhase(phaseClosed)
	s.log.Info("closing the ingest session", slog.String("reason", plan.reason), slog.Bool("abort", plan.abort))
	if plan.ban {
		// 禁止は、閉じる手順に入った時点で成立させる。RTMPS の切断が終わらない間（完了まで時間がかかり得る）に来た再接続を、
		// 受け付けないため。終わったあと、台帳から外すときにも記録する（登録が、あとになった場合のため）
		if registry := s.registryRef.Load(); registry != nil {
			registry.ban(s.id)
		}
	}
	if src != nil {
		if plan.status != nil {
			s.sendRaw(src, s.encoded(encodeStatus(s.withWatchURL(*plan.status))))
		}
		if plan.fatal != "" {
			s.sendRaw(src, s.encoded(encodeFatal(plan.fatal)))
		}
		src.conn.closeLink(CloseNormal)
	}
	for _, kind := range plan.events {
		s.emit(kind, "")
	}
}

func (s *IngestSession) withWatchURL(fields statusFields) statusFields {
	if fields.WatchURL == "" {
		fields.WatchURL = s.watchURL
	}
	return fields
}

// finish は、ループを抜けたあとの後始末。RTMPS の接続を切り（Close は送り切る。Abort は破棄する）、作業のゴルーチンの終了を待ち、
// 配信キーとバッファを破棄して、事象 session_ended を送り、台帳から外す。メディアをファイルへ保存しない。
// 途中で panic が出ても、台帳から外し、Done を閉じる（待っている側を、止めない）。
func (s *IngestSession) finish() {
	defer close(s.done)
	defer s.removeFromRegistry()
	defer func() {
		if recovered := recover(); recovered != nil {
			s.log.Error("finishing the ingest session panicked", slog.String("panic_type", fmt.Sprintf("%T", recovered)))
		}
	}()
	close(s.loopExited)
	if s.wakeTimer != nil {
		s.wakeTimer.Stop()
	}
	s.cancel()
	s.guarded(s.releasePublisher)
	s.wg.Wait()
	s.dropSecrets()
	s.emit(contract.RelayEventKindSessionEnded, "")
}

func (s *IngestSession) removeFromRegistry() {
	if registry := s.registryRef.Load(); registry != nil {
		registry.remove(s, s.plan.ban)
	}
}

// releasePublisher は、RTMPS の接続を切る。Close は、最悪で 17 秒ほどかかる（送り切れないとき）ので、別のゴルーチンで行い、
// 強制（Close の要求が CloseReasonForced・CloseReasonSuperseded）が来たら、Abort に切り替える。
// Close の戻り値のエラーは、終了の妨げにしない（記録するだけ）。
func (s *IngestSession) releasePublisher() {
	pub := s.pub
	s.pub = nil
	if pub == nil {
		return
	}
	if s.plan.abort {
		pub.Abort()
		return
	}
	closed := make(chan struct{})
	go func() {
		defer close(closed)
		defer func() {
			if recovered := recover(); recovered != nil {
				s.log.Error("closing the rtmps connection panicked")
			}
		}()
		if err := pub.Close(); err != nil {
			s.log.Warn("closing the rtmps connection did not finish cleanly", slog.String("class", errorClass(err)))
		}
	}()
	select {
	case <-closed:
	case <-s.abortReq:
		pub.Abort()
		<-closed
	}
}

// dropSecrets は、配信キー・取り込み先・バッファを破棄する（Go は文字列を消去できないので、参照を外す）。
func (s *IngestSession) dropSecrets() {
	s.key = ""
	s.ingestURL = ""
	s.watchURL = ""
	s.cfg = nil
	s.report = nil
	s.browserEvents = nil
	s.hb.pending = nil
	s.pub = nil
	s.src = nil
}
