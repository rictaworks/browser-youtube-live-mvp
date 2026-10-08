package session

import (
	"errors"
	"log/slog"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/frame"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/policer"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/probe"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/flv"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps"
)

// gate は、接続ごとの、映像・音声を受けてよい段階（ws-protocol.md の 5.4）。
type gate int

const (
	// gateBlocked は、まだ送ってよい区間ではない。開始時は status(confirming) まで、復帰時は keyframe_request まで。
	// それ以前に届いた映像・音声は破棄する。
	gateBlocked gate = iota
	// gateWaitKeyframe は、キーフレームを要求した。キーフレームが来るまで、映像・音声を捨てる。到着をもって復帰とする。
	gateWaitKeyframe
	// gateFlowing は、映像・音声を送出する。
	gateFlowing
)

// source は、取り込みセッションの送信元（最新の送出世代の WebSocket の接続 1 本）と、接続ごとの状態。
// 接続ごとに新しく作る。TimeGuard は、ページの再読み込みでメディアクロックが 0 から数え直しになる場合に、時刻の逆行として
// 破棄しないため（#18 のレビューの方針）。ack も、接続ごとに数える。
type source struct {
	conn   *Connection
	epoch  int
	resume bool // accepted で resume=true を伝えた（状態が reserved 以外）

	guard   frame.TimeGuard
	policer policer.IngressPolicer
	probe   probe.ProbeMeter

	probeStarted bool
	probeDone    bool
	probeAt      time.Time

	started bool // この接続で、開始通知（start）を受けた
	gate    gate

	nextTick time.Time // 次の受領応答（と、無通信の確認）の時刻

	ackVideo, ackAudio   uint64 // 受領済みの最新のメディア時刻（この接続で受けたもの）
	seenVideo, seenAudio bool   // この接続で、映像・音声の最初のメディアを受けた（両方そろうまで、ack を送らない）
}

func newSource(c *Connection, epoch int, resume bool, now time.Time, ackInterval time.Duration) *source {
	return &source{conn: c, epoch: epoch, resume: resume, nextTick: now.Add(ackInterval)}
}

// noteAccepted は、受け入れた映像・音声の時刻を、受領済みの最新として記録する（同種別の時刻は、TimeGuard により減らない）。
func (src *source) noteAccepted(f frame.Frame) {
	if f.Type == contract.FrameTypeVideo {
		src.ackVideo, src.seenVideo = f.TimestampUs, true
		return
	}
	src.ackAudio, src.seenAudio = f.TimestampUs, true
}

// frameMessage は、接続が検証して復号した 1 メッセージと、受け取った全体の大きさ（ヘッダを含むバイト数）。
type frameMessage struct {
	frame frame.Frame
	wire  int
}

// onFrame は、接続から届いたメッセージを処理する。世代が進んで差し替えられた古い接続のものは、捨てる。
func (s *IngestSession) onFrame(c *Connection, m frameMessage) {
	src := s.src
	if src == nil || src.conn != c {
		return
	}
	if s.recordIngress(src, m.wire) {
		return
	}
	switch m.frame.Type {
	case contract.FrameTypeProbe:
		s.onProbe(src, m.wire)
	case contract.FrameTypeStart:
		s.onStart(src, m.frame.Body)
	case contract.FrameTypeVideo, contract.FrameTypeAudio:
		s.onMedia(src, m.frame)
	case contract.FrameTypeReport:
		s.onReport(m.frame.Body)
	case contract.FrameTypeEnd:
		s.onEnd(m.frame.Body)
	default:
		s.discard("unexpected_type")
	}
}

// recordIngress は、受信量を数え、10 秒平均がプロファイルの映像ビットレートの上限の 1.5 倍を超えたら、
// 致命通知（bitrate_exceeded）のうえ切断して、配信を終了する（事象 relay_disconnected。以後、当該配信への再接続を受け付けない）。
// 超えて閉じたら true。
func (s *IngestSession) recordIngress(src *source, wire int) bool {
	if err := src.policer.Record(s.t, wire); err != nil {
		s.log.Error("ingress could not be counted", slog.String("class", errorClass(err)))
		return false
	}
	exceeds, err := src.policer.Exceeds(s.t, s.profile)
	if err != nil {
		s.log.Error("ingress limit could not be evaluated", slog.String("class", errorClass(err)))
		return false
	}
	if exceeds {
		s.log.Warn("ingress bitrate exceeded the limit; disconnecting", slog.Int("bitrate_kbps", src.policer.BitrateKbps(s.t)))
		s.closeWith(planBitrateExceeded())
	}
	return exceeds
}

// ---- 回線計測 ----

// onProbe は、計測データを数える。最初の計測データから 3 秒後に、実効スループットを 1 回だけ返す（checkProbe）。
func (s *IngestSession) onProbe(src *source, wire int) {
	if src.probeDone || s.phase != phaseIdle {
		s.discard("probe_not_expected")
		return
	}
	if err := src.probe.Add(s.t, wire); err != nil {
		s.log.Error("probe data could not be counted", slog.String("class", errorClass(err)))
		return
	}
	if !src.probeStarted {
		src.probeStarted = true
		src.probeAt = s.t
		s.setProbing(true)
	}
}

// checkProbe は、最初の計測データから 3 秒が経ったら、計測の結果を返す。受領量が異常に多ければ、受信量の超過と同じに扱う。
func (s *IngestSession) checkProbe(now time.Time) {
	src := s.src
	if src == nil || !src.probeStarted || src.probeDone || !src.probe.Due(now) {
		return
	}
	src.probeDone = true
	kbps, err := src.probe.ThroughputKbps()
	if errors.Is(err, probe.ErrAbnormal) {
		s.log.Warn("probe volume was abnormal; disconnecting")
		s.closeWith(planBitrateExceeded())
		return
	}
	if err != nil {
		s.log.Error("probe result could not be computed", slog.String("class", errorClass(err)))
		return
	}
	s.send(src, s.encoded(encodeProbeResult(kbps)))
}

// ---- 開始通知 ----

// onStart は、開始通知（プロファイルと映像設定・音声設定）を受ける。復帰では、設定の再送。
// 不備のある本文・確定済みのプロファイルと違うプロファイル・復号器設定として使えないものは、破棄する。
func (s *IngestSession) onStart(src *source, body []byte) {
	config, err := parseStart(body)
	if err != nil {
		s.discard("start_invalid")
		return
	}
	if s.profile != "" && config.Profile != s.profile {
		s.discard("start_profile_changed")
		return
	}
	// 復号器設定として使えるか（FLV のタグにできるか）を、準備や接続の前に確かめる
	videoTag, err := s.muxer.VideoConfig(config.Video.Description)
	if err != nil {
		s.discard("start_video_config")
		return
	}
	audioTag, err := s.muxer.AudioConfig(config.Audio.Description)
	if err != nil {
		s.discard("start_audio_config")
		return
	}
	previous := s.cfg
	s.cfg = &config
	s.profile = config.Profile
	src.started = true
	if s.phase == phaseIdle {
		s.setPhase(phasePreparing)
	}
	// 接続中の送出先へ、設定が変わった（再読み込みで、エンコーダが作り直された）場合は、新しい設定を、キーフレームの前に書く
	if s.pub != nil && previous != nil && configChanged(previous, &config) {
		s.writeConfigUpdate(videoTag, audioTag)
	}
	s.reconcile()
}

func configChanged(before, after *startConfig) bool {
	return string(before.Video.Description) != string(after.Video.Description) || string(before.Audio.Description) != string(after.Audio.Description)
}

// flvProfile は、開始通知の設定から、onMetaData のもとになる値を作る。
func flvProfile(config *startConfig) flv.Profile {
	return flv.Profile{
		Width:             config.Video.Width,
		Height:            config.Video.Height,
		Framerate:         config.Video.Framerate,
		VideoBitrateKbps:  config.Video.BitrateKbps,
		AudioBitrateKbps:  config.Audio.BitrateKbps,
		AudioSampleRateHz: config.Audio.SampleRateHz,
		AudioChannels:     config.Audio.Channels,
	}
}

// ---- 映像・音声 ----

// onMedia は、映像・音声のフレームを処理する。
//
// 開始時は status(confirming)、復帰時は keyframe_request を送るまで（gateBlocked）、届いた映像・音声を破棄する。復帰では、
// キーフレームが来るまで（gateWaitKeyframe）、映像・音声を捨て、キーフレームの到着をもって復帰とする。
// 受理したフレームは、TimeGuard（同種別の時刻の逆行を破棄）→ 受領済みの時刻 → MediaWatchdog → TimestampRebaser → FlvMuxer →
// Publisher の順に通す。符号化データには触れない（再エンコードしない）。音声は、再基準化と多重化だけで、破棄しない。
func (s *IngestSession) onMedia(src *source, f frame.Frame) {
	switch src.gate {
	case gateBlocked:
		s.discard("media_not_allowed_yet")
		return
	case gateWaitKeyframe:
		if f.Type != contract.FrameTypeVideo || !f.Keyframe {
			s.discard("media_before_keyframe")
			return
		}
	}
	if len(f.Body) == 0 {
		s.discard("media_empty")
		return
	}
	if f.TimestampUs > maxMediaTimeUs {
		s.discard("media_time_out_of_range")
		return
	}
	if err := src.guard.Admit(f); err != nil {
		s.discard("media_time_regression")
		return
	}
	src.noteAccepted(f)
	if src.gate == gateWaitKeyframe {
		s.completeResume(src)
	}
	if err := s.watchdog.OnFrame(f.Type, s.t); err != nil {
		s.log.Error("media watchdog rejected an observation", slog.String("class", errorClass(err)))
	}
	s.forward(f)
}

// forward は、受理した 1 フレームを、FLV のタグにして、Publisher へ積む。
func (s *IngestSession) forward(f frame.Frame) {
	pub := s.pub
	if pub == nil {
		s.discard("media_no_publisher")
		return
	}
	out, err := s.rebaser.Rebase(f.Type, f.TimestampUs)
	if err != nil {
		s.log.Error("media time could not be rebased", slog.String("class", errorClass(err)))
		s.discard("media_rebase")
		return
	}
	var tag []byte
	if f.Type == contract.FrameTypeVideo {
		tag, err = s.muxer.Video(f.Keyframe, f.Body)
	} else {
		tag, err = s.muxer.Audio(f.Body)
	}
	if err != nil {
		s.log.Error("media could not be packed into an FLV tag", slog.String("class", errorClass(err)))
		s.discard("media_mux")
		return
	}
	if out.TimeMs > s.lastOutMs {
		s.lastOutMs = out.TimeMs
	}
	if f.Type == contract.FrameTypeVideo {
		err = pub.WriteVideo(out.TimeMs, tag)
	} else {
		err = pub.WriteAudio(out.TimeMs, tag)
	}
	if err != nil {
		s.mediaWriteFailed(pub, err)
		return
	}
	s.afterWrite(pub)
}

// mediaWriteFailed は、Publisher への書き込みの失敗を処理する。送出待ちの上限・切断は、送出の失敗として中断へ移る。
func (s *IngestSession) mediaWriteFailed(pub Publisher, err error) {
	switch {
	case errors.Is(err, rtmps.ErrInvalidMessage):
		s.discard("media_invalid_message")
	case errors.Is(err, rtmps.ErrBufferOverflow), errors.Is(err, rtmps.ErrClosed):
		cause := pub.Err()
		if cause == nil {
			cause = err
		}
		s.publisherFailed(pub, cause)
	default:
		s.publisherFailed(pub, err)
	}
}

// afterWrite は、書き込んだあとの送出待ちを評価する。1.5 秒分を超えたら抑制指示（1 秒に 1 回まで）、3 秒分に達したら送出失敗。
func (s *IngestSession) afterWrite(pub Publisher) {
	decision, err := s.policy.Evaluate(max(pub.PendingMs(), 0))
	if err != nil {
		s.log.Error("pending media could not be evaluated", slog.String("class", errorClass(err)))
		return
	}
	if decision.Overflow {
		s.publisherFailed(pub, rtmps.ErrBufferOverflow)
		return
	}
	if !decision.Throttle || s.src == nil {
		return
	}
	limits, known := contract.ProfileLimitsOf(s.profile)
	if !known {
		return
	}
	target, send, err := s.policy.NextThrottle(s.t, s.targetKbps(), limits.VideoBitrateMinKbps)
	if err != nil {
		s.log.Error("throttle target could not be computed", slog.String("class", errorClass(err)))
		return
	}
	if send {
		s.send(s.src, s.encoded(encodeThrottle(target)))
	}
}

// targetKbps は、ブラウザの現在の目標ビットレート（直近の状態報告）。まだ報告が無ければ、開始通知の開始値。
func (s *IngestSession) targetKbps() int {
	if s.report != nil && s.report.TargetKbps > 0 {
		return s.report.TargetKbps
	}
	if s.cfg != nil {
		return s.cfg.Video.BitrateKbps
	}
	return 0
}

// completeResume は、復帰の完了（キーフレームの到着）。欠落区間を詰めて時刻を連続させ（映像と音声に同一の補正量）、送出を再開し、
// 事象 resumed を送る。
func (s *IngestSession) completeResume(src *source) {
	s.rebaser.OnResume()
	src.gate = gateFlowing
	s.setPhase(phaseStreaming)
	s.interruptReported = false
	s.failReported = false
	s.noSourceSince = time.Time{}
	if err := s.watchdog.Arm(s.t); err != nil {
		s.log.Error("media watchdog could not be armed", slog.String("class", errorClass(err)))
	}
	s.log.Info("the broadcast resumed on a keyframe")
	s.emit(contract.RelayEventKindResumed, "")
}

// checkWatchdog は、映像または音声のフレームが 5 秒届かなければ、中断にする。
func (s *IngestSession) checkWatchdog(now time.Time) {
	if s.phase == phaseStreaming && s.watchdog.Stalled(now) {
		s.log.Warn("no media frame for the stall limit; interrupting")
		s.beginInterruption(contract.InterruptCauseMediaStalled, false)
		s.reconcile()
	}
}

// tickAck は、受領応答（映像・音声それぞれの受領済みの最新メディア時刻）を、0.5 秒間隔で返す。この接続で、映像・音声の
// 最初のメディアを受けるまで（両方そろうまで）は送らない（0 を送らない）。
func (s *IngestSession) tickAck(now time.Time) {
	src := s.src
	if src == nil || now.Before(src.nextTick) {
		return
	}
	src.nextTick = now.Add(s.opts.AckInterval)
	if src.seenVideo && src.seenAudio {
		s.send(src, s.encoded(encodeAck(src.ackVideo, src.ackAudio)))
	}
}

// ---- 状態報告 ----

// onReport は、状態報告を受ける。直近の値は心拍に載せるために保持し、ブラウザ側の出来事は、欠落なくキューへ積む
// （心拍が成功するまで保持する。上限を超えたら、古いものから捨てる）。不備のある報告は、出来事も含めて、すべて破棄する。
func (s *IngestSession) onReport(body []byte) {
	report, err := parseReport(body, s.opts.MaxEventsPerReport)
	if err != nil {
		s.discard("report_invalid")
		return
	}
	s.browserEvents = append(s.browserEvents, report.Events...)
	if over := len(s.browserEvents) - s.opts.MaxBrowserEvents; over > 0 {
		s.browserEvents = append([]backend.BrowserEvent(nil), s.browserEvents[over:]...)
		s.discard("browser_events_overflow")
	}
	report.Events = nil
	s.report = &report
}

// ---- 終了通知 ----

// onEnd は、終了通知を受ける。送出待ちを送り切って RTMPS を切断し、事象 session_ended を送り、配信キーとバッファを破棄する。
func (s *IngestSession) onEnd(body []byte) {
	reason, err := parseEnd(body)
	if err != nil {
		s.discard("end_invalid")
		return
	}
	s.log.Info("the browser ended the broadcast", slog.String("reason", string(reason)))
	s.closeWith(planUserEnd())
}
