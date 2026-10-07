// Package flv は、符号化済みの映像・音声を、FLV のタグの本体へ詰め替えます（requirements.md 11.1・11.10）。
//
// 容器の詰め替えだけを行い、符号化データ（H.264 の NAL・AAC のフレーム）には一切触れません。入力のバイト列を、
// そのままコピーして、FLV の VideoData・AudioData の見出しを前に付けるだけです（再エンコードしない。
// 映像の構成時間 composition time は 0）。出力は、RTMP の映像メッセージ・音声メッセージ・データメッセージの本体と、
// 同じ形式です（RTMPS で送るときに、そのまま使えます）。
//
//   - 映像設定（AVCDecoderConfigurationRecord）・音声設定（AudioSpecificConfig）と、準備の結果（取り込み先と配信キーを得たこと）が
//     そろうまで、映像・音声のフレームを作りません。復号器設定は、最初のメディアフレームより前に作ります。
//     RTMPS を接続し直したあとは、設定を作り直すまで、フレームを作りません（OnReconnect）。違反は ErrNotReady です。
//   - 復号器設定は、最小限だけ検査します（AVCDecoderConfigurationRecord の版と長さ・AudioSpecificConfig の長さ）。
//     H.264 の NAL の中身は検査しません。不正は、明示的なエラーです。
//   - 時刻は扱いません（時刻の再基準化は、core の仕事です。RTMP のメッセージの時刻は、呼び出し側が rtmps.Publisher へ渡します）。
package flv

import (
	"bytes"
	"fmt"
	"math"
	"strings"
	"sync"

	"github.com/yutopp/go-amf0"
	"github.com/yutopp/go-flv/tag"
)

// Error は、このパッケージのエラー（定数。errors.Is で判定できる）。
type Error string

func (e Error) Error() string { return string(e) }

const (
	// ErrInvalidVideoConfig は、映像設定（AVCDecoderConfigurationRecord）が不正（長さ・版）。
	ErrInvalidVideoConfig Error = "flv: invalid AVCDecoderConfigurationRecord"
	// ErrInvalidAudioConfig は、音声設定（AudioSpecificConfig）が不正（長さ）。
	ErrInvalidAudioConfig Error = "flv: invalid AudioSpecificConfig"
	// ErrInvalidProfile は、メタデータ（onMetaData）のもとになる値が不正（正の整数でない・チャンネル数が 1 でも 2 でもない）。
	ErrInvalidProfile Error = "flv: invalid profile"
	// ErrEmptyPayload は、符号化データが空。
	ErrEmptyPayload Error = "flv: empty payload"
	// ErrNotReady は、映像設定・音声設定・準備の結果がそろっていない（または、再接続のあと、設定を作り直していない）のに、
	// フレームを作ろうとした。
	ErrNotReady Error = "flv: not ready to publish"
)

const (
	// VideoCodecID は、onMetaData の videocodecid（H.264 = 7。FLV の仕様）。
	VideoCodecID = int(tag.CodecIDAVC)
	// AudioCodecID は、onMetaData の audiocodecid（AAC = 10。FLV の仕様）。
	AudioCodecID = int(tag.SoundFormatAAC)

	// MaxVideoConfigBytes は、映像設定の長さの上限（バイト）。SPS・PPS が数十バイトなので、十分に大きく、異常な入力を止める。
	MaxVideoConfigBytes = 4096
	// MaxAudioConfigBytes は、音声設定の長さの上限（バイト）。AAC-LC は 2 バイト。拡張（SBR・PS）を含んでも数バイト。
	MaxAudioConfigBytes = 64

	// minVideoConfigBytes は、映像設定の長さの下限。AVCDecoderConfigurationRecord の固定部 6 バイト（版・プロファイル・互換性・
	// レベル・NAL の長さの大きさ・SPS の数）と、PPS の数（1 バイト）。
	minVideoConfigBytes = 7
	// minAudioConfigBytes は、音声設定の長さの下限（AudioSpecificConfig の、オブジェクト種別・周波数・チャンネル構成の 2 バイト）。
	minAudioConfigBytes = 2
	// avcConfigurationVersion は、AVCDecoderConfigurationRecord の configurationVersion（常に 1）。
	avcConfigurationVersion = 1

	// stereoChannels・monoChannels は、onMetaData の stereo を決めるチャンネル数。
	stereoChannels = 2
	monoChannels   = 1

	// videoHeaderBytes・audioHeaderBytes は、VideoData・AudioData の見出しの長さ（出力の領域を、1 回で確保するため）。
	videoHeaderBytes = 5
	audioHeaderBytes = 2

	// maxProfileValue は、Profile の各値の上限（float64 で正確に表せる範囲。異常な入力を止める）。
	maxProfileValue = math.MaxInt32
)

// onMetaData のキー（FLV の仕様。多くの配信サービス・プレーヤーが読む名前）。
const (
	metaKeyName            = "onMetaData"
	metaKeyWidth           = "width"
	metaKeyHeight          = "height"
	metaKeyFramerate       = "framerate"
	metaKeyVideoDataRate   = "videodatarate"
	metaKeyAudioDataRate   = "audiodatarate"
	metaKeyAudioSampleRate = "audiosamplerate"
	metaKeyStereo          = "stereo"
	metaKeyVideoCodecID    = "videocodecid"
	metaKeyAudioCodecID    = "audiocodecid"
)

// Profile は、onMetaData のもとになる値（開始通知 start の、映像・音声の設定。ws-protocol.md の 5.3）。
type Profile struct {
	// Width・Height は、映像の幅・高さ（画素）。
	Width, Height int
	// Framerate は、映像のフレームレート（fps）。
	Framerate int
	// VideoBitrateKbps は、映像のビットレート（kbps。開始値）。
	VideoBitrateKbps int
	// AudioBitrateKbps は、音声のビットレート（kbps）。
	AudioBitrateKbps int
	// AudioSampleRateHz は、音声のサンプリング周波数（Hz）。
	AudioSampleRateHz int
	// AudioChannels は、音声のチャンネル数（1 または 2。2 のとき onMetaData の stereo が true）。
	AudioChannels int
}

// validate は、Profile の各値を検査する（正の整数。チャンネル数は 1 または 2）。
func (p Profile) validate() error {
	positive := []struct {
		name  string
		value int
	}{
		{"width", p.Width},
		{"height", p.Height},
		{"framerate", p.Framerate},
		{"video bitrate", p.VideoBitrateKbps},
		{"audio bitrate", p.AudioBitrateKbps},
		{"audio sample rate", p.AudioSampleRateHz},
	}
	for _, field := range positive {
		if field.value < 1 || field.value > maxProfileValue {
			return fmt.Errorf("%w: %s %d (want 1..%d)", ErrInvalidProfile, field.name, field.value, maxProfileValue)
		}
	}
	if p.AudioChannels != monoChannels && p.AudioChannels != stereoChannels {
		return fmt.Errorf("%w: audio channels %d (want %d or %d)", ErrInvalidProfile, p.AudioChannels, monoChannels, stereoChannels)
	}
	return nil
}

// Muxer は、1 つの取り込みセッション（配信キーを持つ 1 つの配信）の、FLV 多重化の状態。
//
// 状態は、「映像設定を作った」「音声設定を作った」「準備の結果を得た」の 3 つ（Ready）。3 つがそろうまで、Video・Audio は
// ErrNotReady を返す。映像設定・音声設定は、RTMPS の接続ごとに作る（OnReconnect で消える）。準備の結果は、取り込み先と配信キーを
// 保持している間は、接続し直しても保たれる。ゴルーチンから並行に呼べる（映像・音声を別のゴルーチンから呼んでよい）。
//
// 出力のバイト列は、呼び出しのたびに新しく確保し、呼び出し側の所有になる（入力とメモリを共有しない。入力も書き換えない）。
// ゼロ値は使えない（NewMuxer で作る）。
type Muxer struct {
	mu          sync.Mutex
	videoConfig bool // この接続で、映像設定を作った
	audioConfig bool // この接続で、音声設定を作った
	provisioned bool // 準備の結果（取り込み先と配信キー）を得た
}

// NewMuxer は、何も設定していない Muxer を返す。
func NewMuxer() *Muxer {
	return &Muxer{}
}

// MarkProvisioned は、準備の結果（YouTube 資源の準備が済み、取り込み先と配信キーを得たこと）を記録する。
// Ready の条件の 1 つ。取り込み先と配信キーそのものは、ここへ渡さない（このパッケージは、配信キーを扱わない）。
func (m *Muxer) MarkProvisioned() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.provisioned = true
}

// OnReconnect は、RTMPS を接続し直すときに呼ぶ。新しい接続は、復号器設定から始めるため、映像設定・音声設定を「作っていない」
// 状態へ戻す（準備の結果は、そのまま）。続けて、VideoConfig・AudioConfig を呼び直し、その出力を、フレームより前に送る。
func (m *Muxer) OnReconnect() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.videoConfig = false
	m.audioConfig = false
}

// Ready は、フレームを作ってよい状態なら nil を返す。足りないものがあれば、それを示す ErrNotReady を返す
// （機密を含まない）。publish を開始してよいかの判定にも使う（映像設定・音声設定と準備の結果がそろうまで、開始しない）。
func (m *Muxer) Ready() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	var missing []string
	if !m.videoConfig {
		missing = append(missing, "video config")
	}
	if !m.audioConfig {
		missing = append(missing, "audio config")
	}
	if !m.provisioned {
		missing = append(missing, "provisioned")
	}
	if len(missing) == 0 {
		return nil
	}
	return fmt.Errorf("%w (missing: %s)", ErrNotReady, strings.Join(missing, ", "))
}

// VideoConfig は、映像設定（AVCDecoderConfigurationRecord）を、FLV の VideoData（シーケンスヘッダ）の本体へ詰め替える。
// 検査は、長さ（最小 7・最大 MaxVideoConfigBytes）と、版（configurationVersion が 1）だけ。NAL の中身は見ない。
// 不正なら ErrInvalidVideoConfig（状態は変わらない）。成功したら、この接続で、映像設定を作ったことになる。
func (m *Muxer) VideoConfig(avcDecoderConfigurationRecord []byte) ([]byte, error) {
	record := avcDecoderConfigurationRecord
	if len(record) < minVideoConfigBytes || len(record) > MaxVideoConfigBytes {
		return nil, fmt.Errorf("%w: length %d (want %d..%d)", ErrInvalidVideoConfig, len(record), minVideoConfigBytes, MaxVideoConfigBytes)
	}
	if record[0] != avcConfigurationVersion {
		return nil, fmt.Errorf("%w: configurationVersion %d (want %d)", ErrInvalidVideoConfig, record[0], avcConfigurationVersion)
	}
	body, err := encodeVideo(tag.FrameTypeKeyFrame, tag.AVCPacketTypeSequenceHeader, record)
	if err != nil {
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.videoConfig = true
	return body, nil
}

// AudioConfig は、音声設定（AudioSpecificConfig）を、FLV の AudioData（シーケンスヘッダ）の本体へ詰め替える。
// 検査は、長さ（最小 2・最大 MaxAudioConfigBytes）だけ。不正なら ErrInvalidAudioConfig（状態は変わらない）。
// 成功したら、この接続で、音声設定を作ったことになる。
func (m *Muxer) AudioConfig(audioSpecificConfig []byte) ([]byte, error) {
	config := audioSpecificConfig
	if len(config) < minAudioConfigBytes || len(config) > MaxAudioConfigBytes {
		return nil, fmt.Errorf("%w: length %d (want %d..%d)", ErrInvalidAudioConfig, len(config), minAudioConfigBytes, MaxAudioConfigBytes)
	}
	body, err := encodeAudio(tag.AACPacketTypeSequenceHeader, config)
	if err != nil {
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.audioConfig = true
	return body, nil
}

// Metadata は、onMetaData（幅・高さ・フレームレート・映像のビットレート・音声のビットレート・音声のサンプリング周波数・
// ステレオか・映像と音声のコーデック ID）を、FLV の ScriptData の本体へ詰め替える。値は、開始通知 start の設定から。
// 不正な値は ErrInvalidProfile。Ready の条件には数えない。
//
// 戻り値は、「onMetaData」の名前と ECMA 配列だけ（FLV のスクリプトタグの本体と同じ形式）。RTMP のデータメッセージにするときの
// 「@setDataFrame」の前置きは、rtmps.Publisher の WriteMeta が付ける。キーの並びは、実行のたびに変わり得る（意味は同じ）。
func (m *Muxer) Metadata(profile Profile) ([]byte, error) {
	if err := profile.validate(); err != nil {
		return nil, err
	}
	meta := amf0.ECMAArray{
		metaKeyWidth:           float64(profile.Width),
		metaKeyHeight:          float64(profile.Height),
		metaKeyFramerate:       float64(profile.Framerate),
		metaKeyVideoDataRate:   float64(profile.VideoBitrateKbps),
		metaKeyAudioDataRate:   float64(profile.AudioBitrateKbps),
		metaKeyAudioSampleRate: float64(profile.AudioSampleRateHz),
		metaKeyStereo:          profile.AudioChannels == stereoChannels,
		metaKeyVideoCodecID:    float64(VideoCodecID),
		metaKeyAudioCodecID:    float64(AudioCodecID),
	}
	var buf bytes.Buffer
	script := &tag.ScriptData{Objects: map[string]amf0.ECMAArray{metaKeyName: meta}}
	if err := tag.EncodeScriptData(&buf, script); err != nil {
		return nil, fmt.Errorf("flv: encode script data: %w", err)
	}
	return buf.Bytes(), nil
}

// Video は、映像フレーム（AVCC 形式の NAL 列。各 NAL の前に 4 バイトの長さ）を、FLV の VideoData（NALU）の本体へ詰め替える。
// keyframe が true ならキーフレーム、false なら差分フレーム。符号化データは、そのままコピーする（構成時間は 0）。
// Ready でなければ ErrNotReady、空なら ErrEmptyPayload。
func (m *Muxer) Video(keyframe bool, avccNALUs []byte) ([]byte, error) {
	if err := m.Ready(); err != nil {
		return nil, err
	}
	if len(avccNALUs) == 0 {
		return nil, fmt.Errorf("%w: video frame", ErrEmptyPayload)
	}
	frameType := tag.FrameTypeInterFrame
	if keyframe {
		frameType = tag.FrameTypeKeyFrame
	}
	return encodeVideo(frameType, tag.AVCPacketTypeNALU, avccNALUs)
}

// Audio は、音声フレーム（ADTS ヘッダの無い、AAC の生フレーム）を、FLV の AudioData（Raw）の本体へ詰め替える。
// 符号化データは、そのままコピーする。Ready でなければ ErrNotReady、空なら ErrEmptyPayload。
func (m *Muxer) Audio(rawAAC []byte) ([]byte, error) {
	if err := m.Ready(); err != nil {
		return nil, err
	}
	if len(rawAAC) == 0 {
		return nil, fmt.Errorf("%w: audio frame", ErrEmptyPayload)
	}
	return encodeAudio(tag.AACPacketTypeRaw, rawAAC)
}

// encodeVideo は、FLV の VideoData（見出し 5 バイト + payload）を、新しいバイト列として作る。
func encodeVideo(frameType tag.FrameType, packetType tag.AVCPacketType, payload []byte) ([]byte, error) {
	var buf bytes.Buffer
	buf.Grow(videoHeaderBytes + len(payload))
	data := &tag.VideoData{
		FrameType:       frameType,
		CodecID:         tag.CodecIDAVC,
		AVCPacketType:   packetType,
		CompositionTime: 0,
		Data:            bytes.NewReader(payload),
	}
	if err := tag.EncodeVideoData(&buf, data); err != nil {
		return nil, fmt.Errorf("flv: encode video data: %w", err)
	}
	return buf.Bytes(), nil
}

// encodeAudio は、FLV の AudioData（見出し 2 バイト + payload）を、新しいバイト列として作る。
// AAC の見出しの、周波数・サイズ・チャンネルの印は、FLV の仕様どおり、常に 44 kHz・16 bit・ステレオ（実際の値は、音声設定にある）。
func encodeAudio(packetType tag.AACPacketType, payload []byte) ([]byte, error) {
	var buf bytes.Buffer
	buf.Grow(audioHeaderBytes + len(payload))
	data := &tag.AudioData{
		SoundFormat:   tag.SoundFormatAAC,
		SoundRate:     tag.SoundRate44kHz,
		SoundSize:     tag.SoundSize16Bit,
		SoundType:     tag.SoundTypeStereo,
		AACPacketType: packetType,
		Data:          bytes.NewReader(payload),
	}
	if err := tag.EncodeAudioData(&buf, data); err != nil {
		return nil, fmt.Errorf("flv: encode audio data: %w", err)
	}
	return buf.Bytes(), nil
}
