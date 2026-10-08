package session

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps"
)

// 送信元の差し替え・準備・RTMPS の接続・送出の開始・中断と復帰。ループのゴルーチンだけが呼ぶ。

// ---- 送信元 ----

// swap は、送信元を新しい世代の接続へ差し替える（SwapSource のループ側）。
func (s *IngestSession) swap(c *Connection, result backend.VerifyResult) error {
	if s.phase == phaseClosed || s.closing.Load() {
		return ErrSessionClosed
	}
	if result.Epoch <= s.epoch {
		// 現在の世代以下の接続は、古い接続（アプリケーションは、より新しい世代を、すでに発行している）。この接続のほうを閉じる
		s.log.Warn("a connection with an older epoch was refused", slog.Int("epoch", result.Epoch), slog.Int("current_epoch", s.epoch))
		c.shutdownLink(contract.FatalCodeStaleEpoch)
		return nil
	}
	old := s.src
	s.epoch = result.Epoch
	s.epochValue.Store(int64(result.Epoch))
	if result.Profile != "" {
		s.profile = result.Profile
	}
	src := newSource(c, result.Epoch, result.State != contract.BroadcastStateReserved, s.t, s.opts.AckInterval)
	s.src = src
	s.noSourceSince = time.Time{}
	s.setProbing(false)
	if old != nil {
		s.log.Info("the sending connection was replaced by a newer epoch", slog.Int("epoch", result.Epoch))
		old.conn.shutdownLink(contract.FatalCodeStaleEpoch)
	}
	if s.phase == phaseStreaming {
		// 送出中に送信元が差し替わった。新しい接続が、キーフレームから再開するまで、中断として扱う
		s.beginInterruption(contract.InterruptCauseBrowserDisconnected, false)
	}
	c.markAttached(s)
	s.sendAccepted(src, result)
	if c.isClosed() {
		s.sourceLost(src) // 照合の応答を待つ間に、接続が切れた。世代は進んでいるので、差し替えたうえで、失う
	}
	s.reconcile()
	return nil
}

// sourceLost は、送信元（WebSocket）を失った。送出中なら、中断として扱う。RTMPS の接続は、中断の期限まで保持する。
func (s *IngestSession) sourceLost(src *source) {
	if s.src != src {
		return
	}
	s.src = nil
	s.noSourceSince = s.t
	s.setProbing(false)
	if s.phase == phaseStreaming {
		s.beginInterruption(contract.InterruptCauseBrowserDisconnected, false)
	}
}

// ---- 中断 ----

// beginInterruption は、送出中の配信を中断にする。送信元のゲートを閉じ、無通信の監視を止める。
// 送出の開始を伝えた配信なら、事象を 1 回だけ送る（interrupted。送出失敗なら publish_failed）。
func (s *IngestSession) beginInterruption(cause contract.InterruptCause, publishFailed bool) {
	if s.phase == phaseStreaming {
		s.setPhase(phaseInterrupted)
		s.interruptedAt = s.t
		s.interruptReported = false
		s.log.Warn("the broadcast was interrupted", slog.String("cause", string(cause)), slog.Bool("publish_failed", publishFailed))
	}
	s.watchdog.Disarm()
	if s.src != nil {
		s.src.gate = gateBlocked
	}
	if !s.published || s.interruptReported {
		return
	}
	s.interruptReported = true
	if publishFailed {
		s.emit(contract.RelayEventKindPublishFailed, cause)
		return
	}
	s.emit(contract.RelayEventKindInterrupted, cause)
}

// ---- 次にすることの判断 ----

// reconcile は、いまの事実（準備の結果・RTMPS の接続・ブラウザの状態）から、次にすることを進める。何度呼んでもよい。
// 1. 開始通知を受けていて、取り込み先が無ければ、準備を呼ぶ
// 2. 取り込み先があり、RTMPS の接続が無ければ、接続する（失敗の待機が済んでいれば）
// 3. 接続が、確認の窓を過ぎても保たれていれば、送出の開始（publish_started）を伝える
// 4. 送出の開始を伝えたあと、ブラウザが映像・音声を送ってよい状態にする（status(confirming)、または keyframe_request）
func (s *IngestSession) reconcile() {
	if s.phase == phaseClosed {
		return
	}
	if s.canProvision() && !s.provisionRetryAt.After(s.t) {
		s.startProvision()
	}
	if s.canDial() && !s.redialAt.After(s.t) {
		s.startDial()
	}
	if s.pub != nil && !s.published && s.publisherOpen() && !s.t.Before(s.pubSince.Add(s.opts.PublishConfirmWindow)) {
		s.published = true
		s.failReported = false
		s.emit(contract.RelayEventKindPublishStarted, "")
	}
	if src := s.src; src != nil && src.started && s.pub != nil && s.published && src.gate == gateBlocked {
		s.startMedia(src)
	}
}

// publisherOpen は、Publisher が、まだ終わっていないか。
func (s *IngestSession) publisherOpen() bool {
	select {
	case <-s.pub.Closed():
		return false
	default:
		return true
	}
}

// startMedia は、ブラウザが映像・音声を送ってよい状態にする。
// 初回（新規の配信）は status(confirming) を送り、送出に入る。復帰（再開の接続・中断のあとの再接続）は、キーフレームを要求し、
// キーフレームの到着をもって復帰とする。
func (s *IngestSession) startMedia(src *source) {
	if !s.confirmSent {
		s.confirmSent = true
		s.sendStatus(src, statusFields{State: contract.BroadcastStateConfirming})
		if s.src != src {
			return // 送信に失敗して、送信元を失った
		}
		if !src.resume {
			src.gate = gateFlowing
			s.setPhase(phaseStreaming)
			s.interruptReported = false
			s.failReported = false
			if err := s.watchdog.Arm(s.t); err != nil {
				s.log.Error("media watchdog could not be armed", slog.String("class", errorClass(err)))
			}
			return
		}
		// 再開の接続で、送出が初めて始まる場合は、status(confirming) のあと、復帰と同じに、キーフレームを要求する
		s.setPhase(phaseInterrupted)
		s.interruptedAt = s.t
	}
	src.gate = gateWaitKeyframe
	s.sendKeyframeRequest(src)
}

// ---- 準備 ----

func (s *IngestSession) startProvision() {
	s.provisioning = true
	epoch, profile := s.epoch, s.profile
	s.spawn("provision", func() {
		result, err := s.deps.Backend.Provision(s.ctx, s.id, epoch, profile)
		s.post(func() { s.onProvisionDone(epoch, result, err) })
	})
}

// onProvisionDone は、準備の結果を処理する。成功なら取り込み先と配信キーをメモリに置き、status(awaiting_media) を送る。
// 配信が終了する失敗は、status(ended) と fatal(broadcast_ended) のうえ切断する。一時的な失敗は、指数的な待機で再要求する
// （準備は冪等）。
func (s *IngestSession) onProvisionDone(epoch int, result backend.ProvisionResult, err error) {
	s.provisioning = false
	switch {
	case err == nil:
		s.acceptProvision(result)
	case errors.Is(err, context.Canceled):
		return
	case errors.Is(err, backend.ErrStaleEpoch):
		if epoch < s.epoch {
			// 自分が世代を進めたために古くなった。新しい世代で、やり直す（新しい接続の開始通知が、すでにあれば、いま）
			s.provisionRetryAt = time.Time{}
			s.reconcile()
			return
		}
		s.log.Warn("the application reports a newer epoch; stopping", slog.Int("epoch", epoch))
		s.closeWith(planStaleEpoch())
	case isPreparationFailure(err):
		s.log.Warn("preparation failed and the broadcast ended", slog.String("class", errorClass(err)))
		s.closeWith(planPrepareFailed(preparationEndReason(err)))
	default:
		s.provisionFailures++
		s.provisionRetryAt = s.t.Add(backoffFor(s.provisionFailures-1, s.opts.RedialInitial, s.opts.RedialMax))
		if failures := s.provisionFailures; failures&(failures-1) == 0 {
			s.log.Warn("preparation failed; retrying", slog.String("class", errorClass(err)), slog.Int("failures", failures))
		}
	}
}

func (s *IngestSession) acceptProvision(result backend.ProvisionResult) {
	s.ingestURL = result.Ingest.URL
	s.key = result.Ingest.StreamKey
	s.watchURL = result.WatchURL
	s.provisioned = true
	s.provisionFailures = 0
	s.provisionRetryAt = time.Time{}
	s.muxer.MarkProvisioned()
	switch result.State {
	case contract.BroadcastStateConfirming, contract.BroadcastStateLive, contract.BroadcastStateInterrupted:
		// 復帰での再要求は、現在の状態を返す。アプリケーションは、送出の開始を知っている
		s.published, s.confirmSent = true, true
	default:
		if !s.confirmSent && s.src != nil {
			s.sendStatus(s.src, statusFields{State: contract.BroadcastStateAwaitingMedia})
		}
	}
	s.reconcile()
}

// isPreparationFailure は、準備の失敗のうち、配信の終了を伴うもの。
func isPreparationFailure(err error) bool {
	return errors.Is(err, backend.ErrBroadcastEnded) || errors.Is(err, backend.ErrPriorUnsettled) || errors.Is(err, backend.ErrPrepareFailed) ||
		errors.Is(err, backend.ErrAuthorizationRevoked) || errors.Is(err, backend.ErrLiveNotEnabled)
}

// preparationEndReason は、準備の失敗の終了理由。アプリケーションが返した理由（details の end_reason）を使う。無ければ、
// 失敗の種類から決まるもの（契約 internal-api.md の 2 章の表。ライブ未有効は準備の失敗）。理由を創作しない（決まらなければ空）。
func preparationEndReason(err error) contract.EndReason {
	var apiErr *backend.APIError
	if errors.As(err, &apiErr) && apiErr.EndReason != "" {
		return apiErr.EndReason
	}
	switch {
	case errors.Is(err, backend.ErrPriorUnsettled):
		return contract.EndReasonPriorUnsettled
	case errors.Is(err, backend.ErrPrepareFailed), errors.Is(err, backend.ErrLiveNotEnabled):
		return contract.EndReasonPrepareFailed
	case errors.Is(err, backend.ErrAuthorizationRevoked):
		return contract.EndReasonAuthorizationRevoked
	}
	return ""
}

// ---- RTMPS の接続 ----

func (s *IngestSession) startDial() {
	s.dialing = true
	request := OpenRequest{URL: s.ingestURL, StreamKey: s.key, Logger: s.log}
	s.spawn("dial", func() {
		pub, err := s.deps.Publishers.Open(s.ctx, request)
		s.deliver(func() { s.onDialDone(pub, err) }, func() {
			if pub != nil {
				pub.Abort() // 取り込みセッションが終わったあとに、接続が成立した。残さない
			}
		})
	})
}

// onDialDone は、RTMPS の接続の結果を処理する。取り込み先が検証に通らないものは、再試行しても変わらないので、閉じる。
// それ以外の失敗は、指数的な待機で再試行する。連続の失敗の回数に上限を置く（応答しない受け口との接続は、ゴルーチンを残す）。
func (s *IngestSession) onDialDone(pub Publisher, err error) {
	s.dialing = false
	if err != nil {
		s.dialFailed(err)
		return
	}
	s.attachPublisher(pub)
	s.reconcile()
}

func (s *IngestSession) dialFailed(err error) {
	if errors.Is(err, context.Canceled) {
		return
	}
	class := errorClass(err)
	if errors.Is(err, ErrDestinationRejected) {
		s.log.Error("the ingest destination was rejected; it will not be retried", slog.String("class", class))
		s.emit(contract.RelayEventKindPublishFailed, "")
		s.closeWith(planPublishFailed())
		return
	}
	s.dialFailures++
	s.dialFailuresTotal++
	if s.dialFailures >= s.opts.MaxRedialAttempts || s.dialFailuresTotal >= s.opts.MaxDialFailures {
		s.log.Error("the rtmps dial kept failing; giving up",
			slog.String("class", class), slog.Int("failures", s.dialFailures), slog.Int("failures_total", s.dialFailuresTotal))
		s.closeWith(planPublishFailed())
		return
	}
	s.redialAt = s.t.Add(backoffFor(s.dialFailures-1, s.opts.RedialInitial, s.opts.RedialMax))
	s.log.Warn("the rtmps dial failed; retrying", slog.String("class", class), slog.Int("failures", s.dialFailures))
}

// attachPublisher は、成立した RTMPS の接続を、この取り込みセッションの送出先にする。
//
// 接続ごとの手順を、このゴルーチンで直列に行う（#19 のレビューの申し送り）:
// rebase.OnConnect → Muxer.OnReconnect → VideoConfig・AudioConfig → Ready の確認 → メタデータ → 映像設定（時刻 0）→ 音声設定
// （時刻 0）→ そのあとにフレーム。新しい Publisher には、必ず rebase.OnConnect を呼ぶ（呼ばないと、時刻 0 の設定との差で、
// 最初のフレームが即座に送出待ちの上限に達する）。Ready が保証するのは設定の生成の順序で、送る順序は、ここで守る。
func (s *IngestSession) attachPublisher(pub Publisher) {
	s.rebaser.OnConnect()
	s.muxer.OnReconnect()
	s.pub = pub
	s.pubSince = s.t
	s.lastOutMs = 0
	s.redialAt = time.Time{}

	videoTag, videoErr := s.muxer.VideoConfig(s.cfg.Video.Description)
	audioTag, audioErr := s.muxer.AudioConfig(s.cfg.Audio.Description)
	meta, metaErr := s.muxer.Metadata(flvProfile(s.cfg))
	readyErr := s.muxer.Ready()
	if err := errors.Join(videoErr, audioErr, metaErr, readyErr); err != nil {
		s.log.Error("the stream headers could not be prepared", slog.String("class", errorClass(err)))
		s.closeWith(planInternalError())
		return
	}
	if err := pub.WriteMeta(meta); err != nil {
		s.publisherFailed(pub, err)
		return
	}
	if err := pub.WriteVideo(0, videoTag); err != nil {
		s.publisherFailed(pub, err)
		return
	}
	if err := pub.WriteAudio(0, audioTag); err != nil {
		s.publisherFailed(pub, err)
	}
}

// writeConfigUpdate は、再接続した接続で映像設定・音声設定が変わっていたとき、新しい設定を、接続中の送出先へ書く。
// 時刻は、それまでの最後の出力の時刻（時刻が戻らないように）。
func (s *IngestSession) writeConfigUpdate(videoTag, audioTag []byte) {
	pub := s.pub
	if err := pub.WriteVideo(s.lastOutMs, videoTag); err != nil {
		s.mediaWriteFailed(pub, err)
		return
	}
	if err := pub.WriteAudio(s.lastOutMs, audioTag); err != nil {
		s.mediaWriteFailed(pub, err)
	}
}

func (s *IngestSession) onPublisherClosed(pub Publisher) {
	if s.pub != pub {
		return // こちらから切った（または、差し替え済みの）もの
	}
	err := pub.Err()
	if err == nil {
		err = rtmps.ErrDisconnected
	}
	s.publisherFailed(pub, err)
}

// publisherFailed は、RTMPS の送出の失敗（送出待ちの上限・切断・publish の直後の切断）を処理する。
// 送出の開始を伝えたあとなら、中断（原因つき）として事象を送り、期限内に再接続する。publish の直後の切断は、
// 配信キーの不正・使用中の可能性があるが、配信の終了の根拠にはせず、中断 → 期限内の再接続として扱う
// （回線の瞬断でも起きる。アプリケーションの応答に従って、再接続・終了が決まる）。
func (s *IngestSession) publisherFailed(pub Publisher, err error) {
	if s.pub != pub {
		return
	}
	// 接続して、確認の窓の間に切れたもの（publish の直後の切断。配信キーの不正・使用中など）は、「失敗」として数えて、待機を置く。
	// 窓を過ぎて保たれた接続の切断は、すぐに再接続する。受け口に、切断と接続を、続けざまに繰り返さない
	quick := s.t.Sub(s.pubSince) < s.opts.PublishConfirmWindow
	s.log.Warn("the rtmps connection was lost", slog.String("class", errorClass(err)), slog.Bool("within_the_confirm_window", quick))
	s.retirePublisher(pub)
	switch {
	case errors.Is(err, rtmps.ErrBufferOverflow):
		s.beginInterruption(contract.InterruptCauseBufferOverflow, true)
	case errors.Is(err, rtmps.ErrPublishRejected):
		s.beginInterruption(contract.InterruptCauseRTMPSDisconnected, true)
	default:
		s.beginInterruption(contract.InterruptCauseRTMPSDisconnected, false)
	}
	if !s.published && !s.failReported {
		// 送出の開始を伝える前の失敗。送出の開始（publish_started）は、まだ伝えていない
		s.failReported = true
		s.emit(contract.RelayEventKindPublishFailed, contract.InterruptCauseRTMPSDisconnected)
	}
	if !quick {
		s.dialFailures = 0 // 窓を過ぎても保たれた接続だった。安定していたので、連続の失敗の数を戻す
		s.redialAt = s.t   // 直ちに再接続を試みる
		s.reconcile()
		return
	}
	s.dialFailures++
	s.dialFailuresTotal++
	if s.dialFailures >= s.opts.MaxRedialAttempts || s.dialFailuresTotal >= s.opts.MaxDialFailures {
		s.log.Error("the rtmps connection kept closing right after it was made; giving up",
			slog.Int("failures", s.dialFailures), slog.Int("failures_total", s.dialFailuresTotal))
		s.closeWith(planPublishFailed())
		return
	}
	s.redialAt = s.t.Add(backoffFor(s.dialFailures-1, s.opts.RedialInitial, s.opts.RedialMax))
	s.reconcile()
}

// retirePublisher は、失敗した Publisher を外し、後始末（Abort）を別のゴルーチンで行う。送出量は、積算へ移す。
func (s *IngestSession) retirePublisher(pub Publisher) {
	s.sentBase += pub.SentBytes()
	s.pub = nil
	if s.src != nil {
		s.src.gate = gateBlocked
	}
	s.spawn("publisher-cleanup", pub.Abort)
}
