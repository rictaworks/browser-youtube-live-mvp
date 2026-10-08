package session

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/flv"
)

// ブラウザから届く JSON の本文（start・report・end）の検査（ws-protocol.md の 5.3・5.6・5.7）。
// 本文の JSON を解釈できない・必須の項目が無い・値が不正なものは、検証エラーのメッセージと同じく破棄する（仮置き。4.1）。
// 未知のキーは無視する（前方互換。x_ で始まるキーも同じ）。エラーの文言は、本文の内容を含まない。

const (
	// maxControlBodyBytes は、JSON の本文として読む上限（バイト）。start・report・end は数百バイトから数 KB。
	maxControlBodyBytes = 64 * 1024

	// maxDescriptionBytes は、映像の復号器設定（AVCDecoderConfigurationRecord）の上限（バイト）。flv.Muxer の上限と同じ。
	maxDescriptionBytes = flv.MaxVideoConfigBytes
	// maxAudioDescriptionBytes は、音声の復号器設定（AudioSpecificConfig）の上限（バイト）。
	maxAudioDescriptionBytes = flv.MaxAudioConfigBytes

	// 状態報告の出来事の detail（符号と数値のみ。ws-protocol.md の 5.6）。
	maxDetailPairs       = 4
	maxDetailKeyBytes    = 32
	maxDetailStringBytes = 32
)

func invalidBody(reason string) error { return fmt.Errorf("%w: %s", errInvalidBody, reason) }

// decodeObject は、本文を JSON のオブジェクトとして読む（大きさの上限つき）。
func decodeObject(body []byte, out any) error {
	if len(body) == 0 || len(body) > maxControlBodyBytes {
		return invalidBody("length")
	}
	if err := json.Unmarshal(body, out); err != nil {
		return invalidBody("not the expected JSON object")
	}
	return nil
}

// ---- start ----

// videoConfig は、開始通知の映像の設定。
type videoConfig struct {
	Codec       string
	Width       int
	Height      int
	Framerate   int
	BitrateKbps int
	// Description は、復号器設定（AVCDecoderConfigurationRecord）。base64 から復号済み。
	Description []byte
}

// audioConfig は、開始通知の音声の設定。
type audioConfig struct {
	Codec        string
	SampleRateHz int
	Channels     int
	BitrateKbps  int
	// Description は、復号器設定（AudioSpecificConfig）。base64 から復号済み。
	Description []byte
}

// startConfig は、開始通知（start）の内容。
type startConfig struct {
	Profile contract.Profile
	Video   videoConfig
	Audio   audioConfig
}

type startWire struct {
	Profile string `json:"profile"`
	Video   struct {
		Codec          string `json:"codec"`
		Width          int    `json:"width"`
		Height         int    `json:"height"`
		Framerate      int    `json:"framerate"`
		BitrateKbps    int    `json:"bitrate_kbps"`
		DescriptionB64 string `json:"description_b64"`
	} `json:"video"`
	Audio struct {
		Codec          string `json:"codec"`
		SampleRate     int    `json:"sample_rate"`
		Channels       int    `json:"channels"`
		BitrateKbps    int    `json:"bitrate_kbps"`
		DescriptionB64 string `json:"description_b64"`
	} `json:"audio"`
}

// parseStart は、開始通知の本文を検査して読む。プロファイルは列挙の値、映像の解像度・フレームレートはプロファイルの値、
// 映像ビットレートはプロファイルの下限から上限まで、音声は契約の固定値、復号器設定は標準の base64（パディングあり）。
func parseStart(body []byte) (startConfig, error) {
	var wire startWire
	if err := decodeObject(body, &wire); err != nil {
		return startConfig{}, err
	}
	profile := contract.Profile(wire.Profile)
	limits, known := contract.ProfileLimitsOf(profile)
	if !known {
		return startConfig{}, invalidBody("unknown profile")
	}
	video := wire.Video
	if video.Codec != contract.VideoCodecMain && video.Codec != contract.VideoCodecConstrainedBaseline {
		return startConfig{}, invalidBody("unknown video codec")
	}
	if video.Width != limits.Width || video.Height != limits.Height || video.Framerate != limits.Framerate {
		return startConfig{}, invalidBody("video size or frame rate differs from the profile")
	}
	if video.BitrateKbps < limits.VideoBitrateMinKbps || video.BitrateKbps > limits.VideoBitrateMaxKbps {
		return startConfig{}, invalidBody("video bitrate is outside the profile range")
	}
	audio := wire.Audio
	if audio.Codec != contract.AudioCodec || audio.SampleRate != contract.AudioSampleRateHz ||
		audio.Channels != contract.AudioChannels || audio.BitrateKbps != contract.AudioBitrateKbps {
		return startConfig{}, invalidBody("audio settings differ from the contract")
	}
	videoDescription, err := decodeDescription(video.DescriptionB64, maxDescriptionBytes)
	if err != nil {
		return startConfig{}, err
	}
	audioDescription, err := decodeDescription(audio.DescriptionB64, maxAudioDescriptionBytes)
	if err != nil {
		return startConfig{}, err
	}
	return startConfig{
		Profile: profile,
		Video: videoConfig{
			Codec: video.Codec, Width: video.Width, Height: video.Height, Framerate: video.Framerate,
			BitrateKbps: video.BitrateKbps, Description: videoDescription,
		},
		Audio: audioConfig{
			Codec: audio.Codec, SampleRateHz: audio.SampleRate, Channels: audio.Channels,
			BitrateKbps: audio.BitrateKbps, Description: audioDescription,
		},
	}, nil
}

// decodeDescription は、復号器設定の base64（標準の文字集合・パディングあり・末尾のビットが 0）を復号する。空・上限超過は不可。
func decodeDescription(encoded string, maxBytes int) ([]byte, error) {
	if encoded == "" || base64.StdEncoding.DecodedLen(len(encoded)) > maxBytes+2 {
		return nil, invalidBody("decoder configuration is empty or too large")
	}
	decoded, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil || len(decoded) == 0 || len(decoded) > maxBytes {
		return nil, invalidBody("decoder configuration is not valid base64")
	}
	return decoded, nil
}

// ---- report ----

type reportWire struct {
	BacklogMs          *int64            `json:"backlog_ms"`
	DroppedVideoFrames *int64            `json:"dropped_video_frames"`
	TargetKbps         *int              `json:"target_kbps"`
	State              string            `json:"state"`
	Events             []json.RawMessage `json:"events"`
}

type browserEventWire struct {
	Kind   string          `json:"kind"`
	Detail json.RawMessage `json:"detail"`
}

// parseReport は、状態報告の本文を検査して読む。出来事は maxEvents 件まで。出来事の detail は、符号と数値のみ
// （キーは小文字の英数字と _ で 32 文字まで、値は整数か、小文字の英数字と _ の 32 文字までの文字列、組は 4 つまで）。
func parseReport(body []byte, maxEvents int) (backend.BrowserReport, error) {
	var wire reportWire
	if err := decodeObject(body, &wire); err != nil {
		return backend.BrowserReport{}, err
	}
	if wire.BacklogMs == nil || *wire.BacklogMs < 0 {
		return backend.BrowserReport{}, invalidBody("backlog_ms")
	}
	if wire.DroppedVideoFrames == nil || *wire.DroppedVideoFrames < 0 {
		return backend.BrowserReport{}, invalidBody("dropped_video_frames")
	}
	if wire.TargetKbps == nil || *wire.TargetKbps < 1 {
		return backend.BrowserReport{}, invalidBody("target_kbps")
	}
	state := contract.StudioState(wire.State)
	if state != contract.StudioStateLive && state != contract.StudioStateDegraded {
		return backend.BrowserReport{}, invalidBody("state")
	}
	if len(wire.Events) > maxEvents {
		return backend.BrowserReport{}, invalidBody("too many events")
	}
	report := backend.BrowserReport{BacklogMs: *wire.BacklogMs, DroppedVideoFrames: *wire.DroppedVideoFrames, TargetKbps: *wire.TargetKbps, State: state}
	for _, raw := range wire.Events {
		event, err := parseBrowserEvent(raw)
		if err != nil {
			return backend.BrowserReport{}, err
		}
		report.Events = append(report.Events, event)
	}
	return report, nil
}

func parseBrowserEvent(raw json.RawMessage) (backend.BrowserEvent, error) {
	var wire browserEventWire
	if err := json.Unmarshal(raw, &wire); err != nil {
		return backend.BrowserEvent{}, invalidBody("event is not an object")
	}
	kind := contract.BrowserEventKind(wire.Kind)
	if !kind.Valid() {
		return backend.BrowserEvent{}, invalidBody("event kind")
	}
	detail, err := canonicalDetail(wire.Detail)
	if err != nil {
		return backend.BrowserEvent{}, err
	}
	return backend.BrowserEvent{Kind: kind, Detail: detail}, nil
}

// canonicalDetail は、detail を検査し、キーを整列した JSON にして返す（受け取った文字列を、そのまま転送しない）。
// detail が無い（省略）なら、空。null・配列・入れ子・真偽値・小数は不可。
func canonicalDetail(raw json.RawMessage) (json.RawMessage, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	var pairs map[string]json.RawMessage
	if err := json.Unmarshal(raw, &pairs); err != nil || pairs == nil {
		return nil, invalidBody("event detail is not an object")
	}
	if len(pairs) > maxDetailPairs {
		return nil, invalidBody("event detail has too many pairs")
	}
	if len(pairs) == 0 {
		return nil, nil
	}
	keys := make([]string, 0, len(pairs))
	for key := range pairs {
		if !isDetailKey(key) {
			return nil, invalidBody("event detail key")
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var out bytes.Buffer
	out.WriteByte('{')
	for i, key := range keys {
		value, err := canonicalDetailValue(pairs[key])
		if err != nil {
			return nil, err
		}
		if i > 0 {
			out.WriteByte(',')
		}
		out.WriteString(strconv.Quote(key)) // 検査済みの文字だけなので、エスケープは入らない
		out.WriteByte(':')
		out.WriteString(value)
	}
	out.WriteByte('}')
	return out.Bytes(), nil
}

// canonicalDetailValue は、detail の値（整数、または符号の文字列）を JSON の表記にする。
func canonicalDetailValue(raw json.RawMessage) (string, error) {
	if len(raw) == 0 {
		return "", invalidBody("event detail value")
	}
	if raw[0] == '"' {
		var text string
		if err := json.Unmarshal(raw, &text); err != nil || !isDetailString(text) {
			return "", invalidBody("event detail string")
		}
		return strconv.Quote(text), nil
	}
	number, err := strconv.ParseInt(string(raw), 10, 64)
	if err != nil {
		return "", invalidBody("event detail number")
	}
	return strconv.FormatInt(number, 10), nil
}

// isDetailKey は、^[a-z][a-z0-9_]{0,31}$ か。
func isDetailKey(key string) bool {
	if len(key) < 1 || len(key) > maxDetailKeyBytes || key[0] < 'a' || key[0] > 'z' {
		return false
	}
	for i := 1; i < len(key); i++ {
		if !isLowerAlnumOrUnderscore(key[i]) {
			return false
		}
	}
	return true
}

// isDetailString は、^[a-z0-9_]{1,32}$ か。
func isDetailString(text string) bool {
	if len(text) < 1 || len(text) > maxDetailStringBytes {
		return false
	}
	for i := 0; i < len(text); i++ {
		if !isLowerAlnumOrUnderscore(text[i]) {
			return false
		}
	}
	return true
}

func isLowerAlnumOrUnderscore(b byte) bool {
	return (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '_'
}

// ---- end ----

// parseEnd は、終了通知の本文から、終了理由を読む。ブラウザが伝えられる 3 つ（user_stop・user_cancel・insufficient_bandwidth）だけ。
func parseEnd(body []byte) (contract.EndReason, error) {
	var wire struct {
		Reason string `json:"reason"`
	}
	if err := decodeObject(body, &wire); err != nil {
		return "", err
	}
	reason := contract.EndReason(wire.Reason)
	switch reason {
	case contract.EndReasonUserStop, contract.EndReasonUserCancel, contract.EndReasonInsufficientBandwidth:
		return reason, nil
	}
	return "", invalidBody("end reason")
}

// isInvalidBody は、err が、本文の不備（破棄する）か。
func isInvalidBody(err error) bool { return errors.Is(err, errInvalidBody) }
