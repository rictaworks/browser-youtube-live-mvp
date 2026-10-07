package flv

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"

	"github.com/yutopp/go-flv/tag"
)

// 試験の入力。実際の H.264・AAC の符号化データを模したバイト列（契約 ws-protocol.md 5.3 の例の復号器設定と同じ形）。
// 中継は、これを 1 バイトも変えずに、コンテナへ詰め替えるだけであることを検証する。
// グローバル変数を持たないため、関数で毎回新しいスライスを返す（試験の間で共有して書き換わることも無い）。

// sampleVideoConfig は、AVCDecoderConfigurationRecord（版 1・Main・Level 3.1・SPS 1 つ・PPS 1 つ）。
func sampleVideoConfig() []byte {
	return []byte{
		0x01, 0x4D, 0x40, 0x1F, 0xFF, 0xE1, 0x00, 0x0F, 0x67, 0x4D, 0x40, 0x1F, 0x96, 0x54, 0x05, 0x01,
		0xED, 0x80, 0xA0, 0x40, 0x3C, 0x22, 0x11, 0x01, 0x00, 0x04, 0x68, 0xEE, 0x3C, 0x80,
	}
}

// sampleAudioConfig は、AudioSpecificConfig（AAC-LC・44.1 kHz・2 ch）。
func sampleAudioConfig() []byte { return []byte{0x12, 0x10} }

// sampleNALUs は、AVCC 形式（各 NAL の前に 4 バイトのビッグエンディアンの長さ）の NAL 列。
func sampleNALUs() []byte {
	return []byte{0x00, 0x00, 0x00, 0x05, 0x65, 0x88, 0x84, 0x00, 0x20, 0x00, 0x00, 0x00, 0x03, 0x06, 0x05, 0xFF}
}

// sampleRawAAC は、ADTS ヘッダの無い、AAC の生フレーム。
func sampleRawAAC() []byte { return []byte{0x21, 0x10, 0x04, 0x60, 0x8C, 0x1C, 0x00, 0xFF, 0x7F} }

func sampleProfile() Profile {
	return Profile{
		Width:             1280,
		Height:            720,
		Framerate:         30,
		VideoBitrateKbps:  4500,
		AudioBitrateKbps:  128,
		AudioSampleRateHz: 44100,
		AudioChannels:     2,
	}
}

// readyMuxer は、映像設定・音声設定・準備の結果がそろい、フレームを受け付ける Muxer。
func readyMuxer(t *testing.T) *Muxer {
	t.Helper()
	m := NewMuxer()
	if _, err := m.VideoConfig(sampleVideoConfig()); err != nil {
		t.Fatalf("VideoConfig: %v", err)
	}
	if _, err := m.AudioConfig(sampleAudioConfig()); err != nil {
		t.Fatalf("AudioConfig: %v", err)
	}
	m.MarkProvisioned()
	return m
}

func concat(parts ...[]byte) []byte {
	var out []byte
	for _, part := range parts {
		out = append(out, part...)
	}
	return out
}

// 本文のバイト列を、go-flv のデコーダで読み戻す。

func decodeVideo(t *testing.T, body []byte) (tag.VideoData, []byte) {
	t.Helper()
	var got tag.VideoData
	if err := tag.DecodeVideoData(bytes.NewReader(body), &got); err != nil {
		t.Fatalf("DecodeVideoData: %v", err)
	}
	payload, err := io.ReadAll(got.Data)
	if err != nil {
		t.Fatalf("read the video payload: %v", err)
	}
	return got, payload
}

func decodeAudio(t *testing.T, body []byte) (tag.AudioData, []byte) {
	t.Helper()
	var got tag.AudioData
	if err := tag.DecodeAudioData(bytes.NewReader(body), &got); err != nil {
		t.Fatalf("DecodeAudioData: %v", err)
	}
	payload, err := io.ReadAll(got.Data)
	if err != nil {
		t.Fatalf("read the audio payload: %v", err)
	}
	return got, payload
}

func TestCodecIDs(t *testing.T) {
	// onMetaData のコーデック ID は、H.264 = 7・AAC = 10（FLV の仕様）
	if VideoCodecID != 7 {
		t.Errorf("VideoCodecID = %d, want 7", VideoCodecID)
	}
	if AudioCodecID != 10 {
		t.Errorf("AudioCodecID = %d, want 10", AudioCodecID)
	}
}

func TestVideoConfigBody(t *testing.T) {
	record := sampleVideoConfig()
	body, err := NewMuxer().VideoConfig(record)
	if err != nil {
		t.Fatalf("VideoConfig: %v", err)
	}
	// 0x17 = キーフレーム（1）・AVC（7）、0x00 = シーケンスヘッダ、構成時間 0（3 バイト）
	want := concat([]byte{0x17, 0x00, 0x00, 0x00, 0x00}, record)
	if !bytes.Equal(body, want) {
		t.Fatalf("body = % x\nwant % x", body, want)
	}

	got, payload := decodeVideo(t, body)
	if got.FrameType != tag.FrameTypeKeyFrame || got.CodecID != tag.CodecIDAVC || got.AVCPacketType != tag.AVCPacketTypeSequenceHeader || got.CompositionTime != 0 {
		t.Errorf("decoded header = %+v, want key frame / AVC / sequence header / composition time 0", got)
	}
	if !bytes.Equal(payload, record) {
		t.Errorf("payload = % x, want % x", payload, record)
	}
}

func TestVideoFrameBody(t *testing.T) {
	cases := []struct {
		name      string
		keyframe  bool
		header    []byte
		frameType tag.FrameType
	}{
		{name: "キーフレーム", keyframe: true, header: []byte{0x17, 0x01, 0x00, 0x00, 0x00}, frameType: tag.FrameTypeKeyFrame},
		{name: "差分フレーム", keyframe: false, header: []byte{0x27, 0x01, 0x00, 0x00, 0x00}, frameType: tag.FrameTypeInterFrame},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			nalus := sampleNALUs()
			body, err := readyMuxer(t).Video(c.keyframe, nalus)
			if err != nil {
				t.Fatalf("Video: %v", err)
			}
			if want := concat(c.header, nalus); !bytes.Equal(body, want) {
				t.Fatalf("body = % x\nwant % x", body, want)
			}
			got, payload := decodeVideo(t, body)
			if got.FrameType != c.frameType || got.CodecID != tag.CodecIDAVC || got.AVCPacketType != tag.AVCPacketTypeNALU || got.CompositionTime != 0 {
				t.Errorf("decoded header = %+v, want %v / AVC / NALU / composition time 0", got, c.frameType)
			}
			// 符号化データは、そのままコピーする（出力に連続して含まれ、末尾に一致する）
			if !bytes.Equal(payload, nalus) || !bytes.Contains(body, nalus) || !bytes.HasSuffix(body, nalus) {
				t.Errorf("the NAL units were altered: payload = % x, want % x", payload, nalus)
			}
		})
	}
}

func TestAudioConfigBody(t *testing.T) {
	config := sampleAudioConfig()
	body, err := NewMuxer().AudioConfig(config)
	if err != nil {
		t.Fatalf("AudioConfig: %v", err)
	}
	// 0xAF = AAC（10）・44 kHz（3）・16 bit（1）・ステレオ（1）、0x00 = シーケンスヘッダ
	if want := concat([]byte{0xAF, 0x00}, config); !bytes.Equal(body, want) {
		t.Fatalf("body = % x\nwant % x", body, want)
	}
	got, payload := decodeAudio(t, body)
	if got.SoundFormat != tag.SoundFormatAAC || got.SoundRate != tag.SoundRate44kHz || got.SoundSize != tag.SoundSize16Bit || got.SoundType != tag.SoundTypeStereo || got.AACPacketType != tag.AACPacketTypeSequenceHeader {
		t.Errorf("decoded header = %+v, want AAC / 44 kHz / 16 bit / stereo / sequence header", got)
	}
	if !bytes.Equal(payload, config) {
		t.Errorf("payload = % x, want % x", payload, config)
	}
}

func TestAudioFrameBody(t *testing.T) {
	raw := sampleRawAAC()
	body, err := readyMuxer(t).Audio(raw)
	if err != nil {
		t.Fatalf("Audio: %v", err)
	}
	if want := concat([]byte{0xAF, 0x01}, raw); !bytes.Equal(body, want) {
		t.Fatalf("body = % x\nwant % x", body, want)
	}
	got, payload := decodeAudio(t, body)
	if got.SoundFormat != tag.SoundFormatAAC || got.AACPacketType != tag.AACPacketTypeRaw {
		t.Errorf("decoded header = %+v, want AAC / raw", got)
	}
	if !bytes.Equal(payload, raw) || !bytes.HasSuffix(body, raw) {
		t.Errorf("the AAC frame was altered: payload = % x, want % x", payload, raw)
	}
}

// 出力は、呼び出し側の入力と、メモリを共有しない（入力を書き換えても出力は変わらず、出力を書き換えても入力は変わらない）。
func TestOutputDoesNotShareMemoryWithInput(t *testing.T) {
	m := readyMuxer(t)
	input := sampleNALUs()
	original := sampleNALUs()
	body, err := m.Video(true, input)
	if err != nil {
		t.Fatalf("Video: %v", err)
	}
	snapshot := append([]byte(nil), body...)

	for i := range input {
		input[i] ^= 0xFF // 呼び出しのあとに、入力を書き換える
	}
	if !bytes.Equal(body, snapshot) {
		t.Errorf("the output changed when the input was modified afterwards")
	}
	for i := range body {
		body[i] ^= 0xFF // 出力を書き換える
	}
	for i := range input {
		input[i] ^= 0xFF
	}
	if !bytes.Equal(input, original) {
		t.Errorf("the input was modified through the output")
	}
}

// 入力のバイト列そのものを書き換えない（設定・フレーム）。
func TestInputsAreNotModified(t *testing.T) {
	m := NewMuxer()
	videoConfig, audioConfig := sampleVideoConfig(), sampleAudioConfig()
	if _, err := m.VideoConfig(videoConfig); err != nil {
		t.Fatal(err)
	}
	if _, err := m.AudioConfig(audioConfig); err != nil {
		t.Fatal(err)
	}
	m.MarkProvisioned()
	nalus, raw := sampleNALUs(), sampleRawAAC()
	if _, err := m.Video(true, nalus); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Audio(raw); err != nil {
		t.Fatal(err)
	}
	for name, pair := range map[string][2][]byte{
		"video config": {videoConfig, sampleVideoConfig()},
		"audio config": {audioConfig, sampleAudioConfig()},
		"NAL units":    {nalus, sampleNALUs()},
		"AAC frame":    {raw, sampleRawAAC()},
	} {
		if !bytes.Equal(pair[0], pair[1]) {
			t.Errorf("%s was modified: % x", name, pair[0])
		}
	}
}

func TestMetadataBody(t *testing.T) {
	cases := []struct {
		name       string
		profile    Profile
		wantStereo bool
	}{
		{name: "720p の標準（ステレオ）", profile: sampleProfile(), wantStereo: true},
		{
			name:       "480p の軽量（開始ビットレートの引き下げ）",
			profile:    Profile{Width: 854, Height: 480, Framerate: 30, VideoBitrateKbps: 1100, AudioBitrateKbps: 128, AudioSampleRateHz: 44100, AudioChannels: 2},
			wantStereo: true,
		},
		{
			name:       "モノラル",
			profile:    Profile{Width: 854, Height: 480, Framerate: 30, VideoBitrateKbps: 800, AudioBitrateKbps: 64, AudioSampleRateHz: 48000, AudioChannels: 1},
			wantStereo: false,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			body, err := NewMuxer().Metadata(c.profile)
			if err != nil {
				t.Fatalf("Metadata: %v", err)
			}
			var script tag.ScriptData
			if err := tag.DecodeScriptData(bytes.NewReader(body), &script); err != nil {
				t.Fatalf("DecodeScriptData: %v", err)
			}
			if len(script.Objects) != 1 {
				t.Fatalf("script objects = %v, want exactly onMetaData", script.Objects)
			}
			meta, ok := script.Objects["onMetaData"]
			if !ok {
				t.Fatalf("no onMetaData in %v", script.Objects)
			}
			want := map[string]any{
				"width":           float64(c.profile.Width),
				"height":          float64(c.profile.Height),
				"framerate":       float64(c.profile.Framerate),
				"videodatarate":   float64(c.profile.VideoBitrateKbps),
				"audiodatarate":   float64(c.profile.AudioBitrateKbps),
				"audiosamplerate": float64(c.profile.AudioSampleRateHz),
				"stereo":          c.wantStereo,
				"videocodecid":    float64(7),
				"audiocodecid":    float64(10),
			}
			if len(meta) != len(want) {
				t.Errorf("onMetaData has %d keys (%v), want exactly %d", len(meta), meta, len(want))
			}
			for key, wantValue := range want {
				if got, present := meta[key]; !present || got != wantValue {
					t.Errorf("onMetaData[%q] = %v (present %v), want %v", key, got, present, wantValue)
				}
			}
		})
	}
}

func TestVideoConfigValidation(t *testing.T) {
	valid := sampleVideoConfig()
	withVersion := func(version byte) []byte {
		record := sampleVideoConfig()
		record[0] = version
		return record
	}
	cases := []struct {
		name    string
		record  []byte
		wantErr bool
	}{
		{name: "正しい（サンプル）", record: valid},
		{name: "最小の長さ（7 バイト）の版 1", record: []byte{0x01, 0x42, 0xC0, 0x1F, 0xFF, 0xE0, 0x00}},
		{name: "nil", record: nil, wantErr: true},
		{name: "空", record: []byte{}, wantErr: true},
		{name: "1 バイト", record: []byte{0x01}, wantErr: true},
		{name: "6 バイト（最小の長さに 1 足りない）", record: []byte{0x01, 0x42, 0xC0, 0x1F, 0xFF, 0xE0}, wantErr: true},
		{name: "版 0", record: withVersion(0), wantErr: true},
		{name: "版 2", record: withVersion(2), wantErr: true},
		{name: "版 255", record: withVersion(255), wantErr: true},
		{name: "長すぎる（上限の 1 バイト超）", record: append([]byte{0x01, 0x42, 0xC0, 0x1F, 0xFF, 0xE0, 0x00}, make([]byte, MaxVideoConfigBytes-6)...), wantErr: true},
		{name: "上限ちょうど", record: append([]byte{0x01, 0x42, 0xC0, 0x1F, 0xFF, 0xE0, 0x00}, make([]byte, MaxVideoConfigBytes-7)...)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			body, err := NewMuxer().VideoConfig(c.record)
			if c.wantErr {
				if !errors.Is(err, ErrInvalidVideoConfig) {
					t.Fatalf("error = %v, want ErrInvalidVideoConfig", err)
				}
				if body != nil {
					t.Errorf("body = % x, want nil on error", body)
				}
				return
			}
			if err != nil {
				t.Fatalf("VideoConfig: %v", err)
			}
			if !bytes.HasSuffix(body, c.record) {
				t.Errorf("the record was not copied through")
			}
		})
	}
}

func TestAudioConfigValidation(t *testing.T) {
	cases := []struct {
		name    string
		config  []byte
		wantErr bool
	}{
		{name: "正しい（AAC-LC・44.1 kHz・2 ch）", config: []byte{0x12, 0x10}},
		{name: "最小の長さ（2 バイト）", config: []byte{0x11, 0x90}},
		{name: "拡張を含む長い設定（5 バイト）", config: []byte{0x2B, 0x11, 0x88, 0x00, 0x00}},
		{name: "nil", config: nil, wantErr: true},
		{name: "空", config: []byte{}, wantErr: true},
		{name: "1 バイト（最小の長さに 1 足りない）", config: []byte{0x12}, wantErr: true},
		{name: "長すぎる（上限の 1 バイト超）", config: make([]byte, MaxAudioConfigBytes+1), wantErr: true},
		{name: "上限ちょうど", config: make([]byte, MaxAudioConfigBytes)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			body, err := NewMuxer().AudioConfig(c.config)
			if c.wantErr {
				if !errors.Is(err, ErrInvalidAudioConfig) {
					t.Fatalf("error = %v, want ErrInvalidAudioConfig", err)
				}
				if body != nil {
					t.Errorf("body = % x, want nil on error", body)
				}
				return
			}
			if err != nil {
				t.Fatalf("AudioConfig: %v", err)
			}
			if !bytes.HasSuffix(body, c.config) {
				t.Errorf("the config was not copied through")
			}
		})
	}
}

func TestMetadataValidation(t *testing.T) {
	change := func(apply func(*Profile)) Profile {
		p := sampleProfile()
		apply(&p)
		return p
	}
	cases := []struct {
		name    string
		profile Profile
		wantErr bool
	}{
		{name: "正しい", profile: sampleProfile()},
		{name: "幅 0", profile: change(func(p *Profile) { p.Width = 0 }), wantErr: true},
		{name: "幅が負", profile: change(func(p *Profile) { p.Width = -1 }), wantErr: true},
		{name: "高さ 0", profile: change(func(p *Profile) { p.Height = 0 }), wantErr: true},
		{name: "フレームレート 0", profile: change(func(p *Profile) { p.Framerate = 0 }), wantErr: true},
		{name: "映像ビットレート 0", profile: change(func(p *Profile) { p.VideoBitrateKbps = 0 }), wantErr: true},
		{name: "音声ビットレート 0", profile: change(func(p *Profile) { p.AudioBitrateKbps = 0 }), wantErr: true},
		{name: "サンプリング周波数 0", profile: change(func(p *Profile) { p.AudioSampleRateHz = 0 }), wantErr: true},
		{name: "チャンネル数 0", profile: change(func(p *Profile) { p.AudioChannels = 0 }), wantErr: true},
		{name: "チャンネル数 3", profile: change(func(p *Profile) { p.AudioChannels = 3 }), wantErr: true},
		{name: "値が大きすぎる（int32 を超える）", profile: change(func(p *Profile) { p.VideoBitrateKbps = 1 << 31 }), wantErr: true},
		{name: "零値の Profile", profile: Profile{}, wantErr: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			body, err := NewMuxer().Metadata(c.profile)
			if c.wantErr {
				if !errors.Is(err, ErrInvalidProfile) {
					t.Fatalf("error = %v, want ErrInvalidProfile", err)
				}
				if body != nil {
					t.Errorf("body = % x, want nil on error", body)
				}
				return
			}
			if err != nil {
				t.Fatalf("Metadata: %v", err)
			}
		})
	}
}

func TestEmptyFramesAreRejected(t *testing.T) {
	m := readyMuxer(t)
	for name, call := range map[string]func() ([]byte, error){
		"Video nil":   func() ([]byte, error) { return m.Video(true, nil) },
		"Video empty": func() ([]byte, error) { return m.Video(false, []byte{}) },
		"Audio nil":   func() ([]byte, error) { return m.Audio(nil) },
		"Audio empty": func() ([]byte, error) { return m.Audio([]byte{}) },
	} {
		body, err := call()
		if !errors.Is(err, ErrEmptyPayload) {
			t.Errorf("%s: error = %v, want ErrEmptyPayload", name, err)
		}
		if body != nil {
			t.Errorf("%s: body = % x, want nil on error", name, body)
		}
	}
}

// 呼び出し順の制約（受け入れ条件）：映像設定・音声設定・準備の結果がそろうまで、フレームを作らない。
// 復号器設定は、最初のメディアフレームより前に作る。再接続のあとは、設定を作り直すまで、フレームを作らない。
func TestMuxerCallOrder(t *testing.T) {
	provision := func(m *Muxer) error { m.MarkProvisioned(); return nil }
	videoConfig := func(m *Muxer) error { _, err := m.VideoConfig(sampleVideoConfig()); return err }
	audioConfig := func(m *Muxer) error { _, err := m.AudioConfig(sampleAudioConfig()); return err }
	metadata := func(m *Muxer) error { _, err := m.Metadata(sampleProfile()); return err }
	reconnect := func(m *Muxer) error { m.OnReconnect(); return nil }
	badVideoConfig := func(m *Muxer) error { _, err := m.VideoConfig([]byte{0x00}); return err }
	badAudioConfig := func(m *Muxer) error { _, err := m.AudioConfig([]byte{0x00}); return err }

	cases := []struct {
		name         string
		steps        []func(*Muxer) error // 失敗しない手順（badXxx は、失敗するのが正しい）
		failingSteps int                  // steps のうち、失敗してよい手順の数（先頭から数えず、badXxx の個数）
		wantReady    bool
	}{
		{name: "何もしていない", wantReady: false},
		{name: "準備の結果だけ", steps: []func(*Muxer) error{provision}, wantReady: false},
		{name: "映像設定だけ", steps: []func(*Muxer) error{videoConfig}, wantReady: false},
		{name: "音声設定だけ", steps: []func(*Muxer) error{audioConfig}, wantReady: false},
		{name: "映像設定と音声設定（準備の結果なし）", steps: []func(*Muxer) error{videoConfig, audioConfig}, wantReady: false},
		{name: "映像設定と準備の結果（音声設定なし）", steps: []func(*Muxer) error{videoConfig, provision}, wantReady: false},
		{name: "音声設定と準備の結果（映像設定なし）", steps: []func(*Muxer) error{audioConfig, provision}, wantReady: false},
		{name: "3 つそろう", steps: []func(*Muxer) error{videoConfig, audioConfig, provision}, wantReady: true},
		{name: "3 つそろう（順不同：準備の結果が先）", steps: []func(*Muxer) error{provision, audioConfig, videoConfig}, wantReady: true},
		{name: "メタデータは、条件に数えない", steps: []func(*Muxer) error{metadata}, wantReady: false},
		{name: "メタデータがあっても、3 つがそろえば可", steps: []func(*Muxer) error{metadata, videoConfig, audioConfig, provision}, wantReady: true},
		{name: "不正な映像設定は、設定したことにならない", steps: []func(*Muxer) error{badVideoConfig, audioConfig, provision}, failingSteps: 1, wantReady: false},
		{name: "不正な音声設定は、設定したことにならない", steps: []func(*Muxer) error{videoConfig, badAudioConfig, provision}, failingSteps: 1, wantReady: false},
		{name: "不正な設定のあと、正しい設定で可", steps: []func(*Muxer) error{badVideoConfig, videoConfig, audioConfig, provision}, failingSteps: 1, wantReady: true},
		{name: "再接続のあとは、設定を作り直すまで不可", steps: []func(*Muxer) error{videoConfig, audioConfig, provision, reconnect}, wantReady: false},
		{name: "再接続のあと、映像設定だけでは不可", steps: []func(*Muxer) error{videoConfig, audioConfig, provision, reconnect, videoConfig}, wantReady: false},
		{name: "再接続のあと、音声設定だけでは不可", steps: []func(*Muxer) error{videoConfig, audioConfig, provision, reconnect, audioConfig}, wantReady: false},
		{name: "再接続のあと、設定を再送すれば可（準備の結果は保たれる）", steps: []func(*Muxer) error{videoConfig, audioConfig, provision, reconnect, videoConfig, audioConfig}, wantReady: true},
		{name: "再接続は何度でも", steps: []func(*Muxer) error{videoConfig, audioConfig, provision, reconnect, videoConfig, audioConfig, reconnect}, wantReady: false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := NewMuxer()
			failures := 0
			for i, step := range c.steps {
				if err := step(m); err != nil {
					failures++
					if !errors.Is(err, ErrInvalidVideoConfig) && !errors.Is(err, ErrInvalidAudioConfig) {
						t.Fatalf("step %d failed with an unexpected error: %v", i, err)
					}
				}
			}
			if failures != c.failingSteps {
				t.Fatalf("failing steps = %d, want %d", failures, c.failingSteps)
			}

			readyErr := m.Ready()
			_, videoErr := m.Video(true, sampleNALUs())
			_, audioErr := m.Audio(sampleRawAAC())
			if c.wantReady {
				if readyErr != nil || videoErr != nil || audioErr != nil {
					t.Fatalf("Ready = %v, Video = %v, Audio = %v; want all nil", readyErr, videoErr, audioErr)
				}
				return
			}
			for name, err := range map[string]error{"Ready": readyErr, "Video": videoErr, "Audio": audioErr} {
				if !errors.Is(err, ErrNotReady) {
					t.Errorf("%s error = %v, want ErrNotReady", name, err)
				}
			}
		})
	}
}

// 準備ができていないときのエラーは、足りないものを示す（機密を含まない）。
func TestNotReadyErrorNamesWhatIsMissing(t *testing.T) {
	err := NewMuxer().Ready()
	if !errors.Is(err, ErrNotReady) {
		t.Fatalf("error = %v, want ErrNotReady", err)
	}
	for _, missing := range []string{"video config", "audio config", "provisioned"} {
		if !strings.Contains(err.Error(), missing) {
			t.Errorf("error %q does not mention %q", err.Error(), missing)
		}
	}

	m := NewMuxer()
	if _, err := m.VideoConfig(sampleVideoConfig()); err != nil {
		t.Fatal(err)
	}
	m.MarkProvisioned()
	err = m.Ready()
	if !errors.Is(err, ErrNotReady) || !strings.Contains(err.Error(), "audio config") {
		t.Fatalf("error = %v, want ErrNotReady mentioning the audio config", err)
	}
	if strings.Contains(err.Error(), "video config") || strings.Contains(err.Error(), "provisioned") {
		t.Errorf("error %q mentions something that is already in place", err.Error())
	}
}

// 失敗した呼び出しは、状態を変えない。
func TestFailedCallsKeepTheStateUnchanged(t *testing.T) {
	m := readyMuxer(t)
	if _, err := m.VideoConfig([]byte{0x00}); !errors.Is(err, ErrInvalidVideoConfig) {
		t.Fatalf("error = %v, want ErrInvalidVideoConfig", err)
	}
	if _, err := m.AudioConfig([]byte{0x00}); !errors.Is(err, ErrInvalidAudioConfig) {
		t.Fatalf("error = %v, want ErrInvalidAudioConfig", err)
	}
	if err := m.Ready(); err != nil {
		t.Errorf("Ready after rejected configs = %v, want nil (the accepted configs stay in place)", err)
	}
	if _, err := m.Video(true, sampleNALUs()); err != nil {
		t.Errorf("Video after rejected configs: %v", err)
	}
}

// 映像と音声を、別のゴルーチンから並行に呼べる（-race で確かめる）。
func TestMuxerIsSafeForConcurrentUse(t *testing.T) {
	m := readyMuxer(t)
	const goroutines, calls = 8, 200
	var wg sync.WaitGroup
	errs := make(chan error, goroutines*calls)
	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for i := 0; i < calls; i++ {
				var err error
				switch id % 4 {
				case 0:
					_, err = m.Video(i%30 == 0, sampleNALUs())
				case 1:
					_, err = m.Audio(sampleRawAAC())
				case 2:
					_, err = m.Metadata(sampleProfile())
				default:
					_ = m.Ready()
				}
				if err != nil {
					errs <- err
				}
			}
		}(g)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Errorf("concurrent call failed: %v", err)
	}
}

// 任意の長さ・内容の符号化データを、そのままコピーする（固定のシードで、長さと内容を変える）。
func TestPayloadsAreCopiedThroughUnchanged(t *testing.T) {
	m := readyMuxer(t)
	state := uint32(1)
	next := func() byte { // 線形合同法（再現できる疑似乱数。実時計・乱数のライブラリを使わない）
		state = state*1664525 + 1013904223
		return byte(state >> 24)
	}
	for _, length := range []int{1, 2, 3, 4, 5, 127, 128, 129, 255, 256, 1000, 65535, 65536, 100000} {
		payload := make([]byte, length)
		for i := range payload {
			payload[i] = next()
		}
		keyframe := length%2 == 0

		videoBody, err := m.Video(keyframe, payload)
		if err != nil {
			t.Fatalf("Video(len %d): %v", length, err)
		}
		if len(videoBody) != length+5 || !bytes.Equal(videoBody[5:], payload) {
			t.Fatalf("Video(len %d): the payload was altered or the header is not 5 bytes", length)
		}
		audioBody, err := m.Audio(payload)
		if err != nil {
			t.Fatalf("Audio(len %d): %v", length, err)
		}
		if len(audioBody) != length+2 || !bytes.Equal(audioBody[2:], payload) {
			t.Fatalf("Audio(len %d): the payload was altered or the header is not 2 bytes", length)
		}
	}
}

func FuzzMuxerRoundTrip(f *testing.F) {
	f.Add([]byte{0x00, 0x00, 0x00, 0x01, 0x65}, true)
	f.Add([]byte{0xFF}, false)
	f.Fuzz(func(t *testing.T, payload []byte, keyframe bool) {
		m := NewMuxer()
		if _, err := m.VideoConfig(sampleVideoConfig()); err != nil {
			t.Fatal(err)
		}
		if _, err := m.AudioConfig(sampleAudioConfig()); err != nil {
			t.Fatal(err)
		}
		m.MarkProvisioned()

		videoBody, err := m.Video(keyframe, payload)
		if len(payload) == 0 {
			if !errors.Is(err, ErrEmptyPayload) {
				t.Fatalf("empty video payload: error = %v, want ErrEmptyPayload", err)
			}
			return
		}
		if err != nil {
			t.Fatalf("Video: %v", err)
		}
		got, decoded := decodeVideo(t, videoBody)
		wantType := tag.FrameTypeInterFrame
		if keyframe {
			wantType = tag.FrameTypeKeyFrame
		}
		if got.FrameType != wantType || got.AVCPacketType != tag.AVCPacketTypeNALU || !bytes.Equal(decoded, payload) {
			t.Fatalf("round trip mismatch: header %+v, payload equal %v", got, bytes.Equal(decoded, payload))
		}

		audioBody, err := m.Audio(payload)
		if err != nil {
			t.Fatalf("Audio: %v", err)
		}
		audio, rawDecoded := decodeAudio(t, audioBody)
		if audio.AACPacketType != tag.AACPacketTypeRaw || !bytes.Equal(rawDecoded, payload) {
			t.Fatalf("audio round trip mismatch")
		}
	})
}
