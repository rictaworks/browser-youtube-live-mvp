package session

import (
	"encoding/json"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/frame"
)

// 中継からブラウザへ送る制御メッセージ（ws-protocol.md の 5.8〜5.14）の符号化。時刻 0・属性 0 のフレームにする。
// 本文は、符号（列挙の値）と数値だけで、画面に出す文言を含まない。

type acceptedBody struct {
	State   contract.BroadcastState `json:"state"`
	Resume  bool                    `json:"resume"`
	Profile *contract.Profile       `json:"profile"`
	Limits  limitsBody              `json:"limits"`
}

type limitsBody struct {
	TimeLimitSeconds int `json:"time_limit_seconds"`
}

type probeResultBody struct {
	ThroughputKbps int `json:"throughput_kbps"`
}

type ackBody struct {
	VideoUs uint64 `json:"video_us"`
	AudioUs uint64 `json:"audio_us"`
}

type throttleBody struct {
	TargetKbps int `json:"target_kbps"`
}

type statusBody struct {
	State                  contract.BroadcastState `json:"state"`
	WatchURL               *string                 `json:"watch_url"`
	Warning                *string                 `json:"warning"`
	TimeLimitNoticeSeconds *int                    `json:"time_limit_notice_seconds"`
	EndReason              *contract.EndReason     `json:"end_reason"`
}

type fatalBody struct {
	Code contract.FatalCode `json:"code"`
}

// statusFields は、status の内容。空の文字列・0 は、null になる。
type statusFields struct {
	State                  contract.BroadcastState
	WatchURL               string
	Warning                string
	TimeLimitNoticeSeconds int
	EndReason              contract.EndReason
}

func encodeBody(kind contract.FrameType, body any) ([]byte, error) {
	encoded, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	return frame.EncodeControl(kind, encoded)
}

// encodeAccepted は、接続受理。profile が空なら null。
func encodeAccepted(state contract.BroadcastState, resume bool, profile contract.Profile, timeLimitSeconds int) ([]byte, error) {
	body := acceptedBody{State: state, Resume: resume, Limits: limitsBody{TimeLimitSeconds: timeLimitSeconds}}
	if profile != "" {
		body.Profile = &profile
	}
	return encodeBody(contract.FrameTypeAccepted, body)
}

func encodeProbeResult(throughputKbps int) ([]byte, error) {
	return encodeBody(contract.FrameTypeProbeResult, probeResultBody{ThroughputKbps: throughputKbps})
}

func encodeAck(videoUs, audioUs uint64) ([]byte, error) {
	return encodeBody(contract.FrameTypeAck, ackBody{VideoUs: videoUs, AudioUs: audioUs})
}

func encodeThrottle(targetKbps int) ([]byte, error) {
	return encodeBody(contract.FrameTypeThrottle, throttleBody{TargetKbps: targetKbps})
}

// encodeKeyframeRequest は、キーフレーム要求（本文は空）。
func encodeKeyframeRequest() ([]byte, error) {
	return frame.EncodeControl(contract.FrameTypeKeyframeRequest, nil)
}

// encodeStatus は、状態の通知（毎回、状態の全体のスナップショット）。
func encodeStatus(fields statusFields) ([]byte, error) {
	body := statusBody{State: fields.State}
	if fields.WatchURL != "" {
		body.WatchURL = &fields.WatchURL
	}
	if fields.Warning != "" {
		body.Warning = &fields.Warning
	}
	if fields.TimeLimitNoticeSeconds > 0 {
		body.TimeLimitNoticeSeconds = &fields.TimeLimitNoticeSeconds
	}
	if fields.EndReason != "" {
		body.EndReason = &fields.EndReason
	}
	return encodeBody(contract.FrameTypeStatus, body)
}

func encodeFatal(code contract.FatalCode) ([]byte, error) {
	return encodeBody(contract.FrameTypeFatal, fatalBody{Code: code})
}
