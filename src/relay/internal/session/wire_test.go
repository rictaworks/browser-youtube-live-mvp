package session

import (
	"encoding/binary"
	"encoding/json"
	"reflect"
	"testing"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/frame"
)

// 中継からブラウザへ送る制御メッセージ（ws-protocol.md の 5.8〜5.14）の本文。契約の例と一致すること。

// controlMessage は、中継が送ったフレームを読み戻したもの（ブラウザ側の受信の疑似）。
type controlMessage struct {
	Type        contract.FrameType
	Keyframe    bool
	TimestampUs uint64
	Body        []byte
}

// parseControl は、フレームのヘッダ（17 バイト）と本文を読む。中継 → ブラウザの種別は core/frame.Decode が受理しないので、手で読む。
func parseControl(t testing.TB, message []byte) controlMessage {
	t.Helper()
	if len(message) < contract.WSFrameHeaderBytes {
		t.Fatalf("message is %d bytes, shorter than the header", len(message))
	}
	if message[0] != 0x42 || message[1] != 0x4C || message[2] != contract.WSFrameVersion {
		t.Fatalf("bad magic or version: % x", message[:3])
	}
	length := binary.BigEndian.Uint32(message[13:17])
	if int(length) != len(message)-contract.WSFrameHeaderBytes {
		t.Fatalf("body length %d does not match the message (%d bytes)", length, len(message))
	}
	return controlMessage{
		Type:        contract.FrameType(message[3]),
		Keyframe:    message[4]&1 != 0,
		TimestampUs: binary.BigEndian.Uint64(message[5:13]),
		Body:        message[contract.WSFrameHeaderBytes:],
	}
}

func assertBodyJSON(t *testing.T, got controlMessage, want string) {
	t.Helper()
	var gotValue, wantValue any
	if err := json.Unmarshal(got.Body, &gotValue); err != nil {
		t.Fatalf("body is not JSON: %v: %q", err, got.Body)
	}
	if err := json.Unmarshal([]byte(want), &wantValue); err != nil {
		t.Fatalf("expected body is not JSON: %v", err)
	}
	if !reflect.DeepEqual(gotValue, wantValue) {
		t.Fatalf("body = %s\nwant   %s", got.Body, want)
	}
}

func TestEncodedControlMessagesMatchTheContractExamples(t *testing.T) {
	cases := []struct {
		name     string
		encode   func() ([]byte, error)
		wantType contract.FrameType
		wantBody string
	}{
		{
			"accepted（新規）",
			func() ([]byte, error) { return encodeAccepted(contract.BroadcastStateReserved, false, "", 3600) },
			contract.FrameTypeAccepted,
			`{"state":"reserved","resume":false,"profile":null,"limits":{"time_limit_seconds":3600}}`,
		},
		{
			"accepted（再開）",
			func() ([]byte, error) {
				return encodeAccepted(contract.BroadcastStateLive, true, contract.Profile480p, 1800)
			},
			contract.FrameTypeAccepted,
			`{"state":"live","resume":true,"profile":"480p","limits":{"time_limit_seconds":1800}}`,
		},
		{
			"probe_result",
			func() ([]byte, error) { return encodeProbeResult(5200) },
			contract.FrameTypeProbeResult,
			`{"throughput_kbps":5200}`,
		},
		{
			"ack",
			func() ([]byte, error) { return encodeAck(33333, 23220) },
			contract.FrameTypeAck,
			`{"video_us":33333,"audio_us":23220}`,
		},
		{
			"ack（2^53 を超える時刻）",
			func() ([]byte, error) { return encodeAck(9007199254740993, 18446744073709551615) },
			contract.FrameTypeAck,
			`{"video_us":9007199254740993,"audio_us":18446744073709551615}`,
		},
		{
			"throttle",
			func() ([]byte, error) { return encodeThrottle(3150) },
			contract.FrameTypeThrottle,
			`{"target_kbps":3150}`,
		},
		{
			"status（ライブ・予告）",
			func() ([]byte, error) {
				return encodeStatus(statusFields{State: contract.BroadcastStateLive, WatchURL: "https://www.youtube.com/watch?v=dummyVideoId", TimeLimitNoticeSeconds: 300})
			},
			contract.FrameTypeStatus,
			`{"state":"live","watch_url":"https://www.youtube.com/watch?v=dummyVideoId","warning":null,"time_limit_notice_seconds":300,"end_reason":null}`,
		},
		{
			"status（準備の完了）",
			func() ([]byte, error) {
				return encodeStatus(statusFields{State: contract.BroadcastStateAwaitingMedia, WatchURL: "https://www.youtube.com/watch?v=x"})
			},
			contract.FrameTypeStatus,
			`{"state":"awaiting_media","watch_url":"https://www.youtube.com/watch?v=x","warning":null,"time_limit_notice_seconds":null,"end_reason":null}`,
		},
		{
			"status（警告）",
			func() ([]byte, error) {
				return encodeStatus(statusFields{State: contract.BroadcastStateLive, WatchURL: "https://www.youtube.com/watch?v=x", Warning: "youtube_stream_unhealthy"})
			},
			contract.FrameTypeStatus,
			`{"state":"live","watch_url":"https://www.youtube.com/watch?v=x","warning":"youtube_stream_unhealthy","time_limit_notice_seconds":null,"end_reason":null}`,
		},
		{
			"status（終了）",
			func() ([]byte, error) {
				return encodeStatus(statusFields{State: contract.BroadcastStateEnded, EndReason: contract.EndReasonTimeLimit})
			},
			contract.FrameTypeStatus,
			`{"state":"ended","watch_url":null,"warning":null,"time_limit_notice_seconds":null,"end_reason":"time_limit"}`,
		},
		{
			"fatal",
			func() ([]byte, error) { return encodeFatal(contract.FatalCodeMessageTooLarge) },
			contract.FrameTypeFatal,
			`{"code":"message_too_large"}`,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			message, err := c.encode()
			if err != nil {
				t.Fatalf("encode: %v", err)
			}
			got := parseControl(t, message)
			if got.Type != c.wantType || got.TimestampUs != 0 || got.Keyframe {
				t.Fatalf("frame = %+v, want type %v with time 0 and no keyframe attribute", got, c.wantType)
			}
			assertBodyJSON(t, got, c.wantBody)
		})
	}
}

func TestKeyframeRequestHasAnEmptyBody(t *testing.T) {
	message, err := encodeKeyframeRequest()
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	got := parseControl(t, message)
	if got.Type != contract.FrameTypeKeyframeRequest || len(got.Body) != 0 {
		t.Fatalf("frame = %+v", got)
	}
}

// 中継が送るフレームは、core/frame の符号化（EncodeControl）と同じ形式（ブラウザの受信側が復号できる）。
func TestEncodedMessagesHaveTheHeaderOfEncodeControl(t *testing.T) {
	message, err := encodeProbeResult(1234)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	want, err := frame.EncodeControl(contract.FrameTypeProbeResult, []byte(`{"throughput_kbps":1234}`))
	if err != nil {
		t.Fatalf("EncodeControl: %v", err)
	}
	if string(message) != string(want) {
		t.Fatalf("message = % x\nwant      % x", message, want)
	}
}
