package session

import (
	"encoding/base64"
	"fmt"
	"strings"
	"testing"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// ブラウザから届く JSON の本文（start・report・end。ws-protocol.md の 5.3・5.6・5.7）の検査。
// 不備のある本文は、検証エラーと同じく破棄する（ws-protocol.md の 4.1）。

const (
	sampleVideoDescriptionB64 = "AU1AH//hAA9nTUAfllQFAe2AoEA8IhEBAARo7jyA" // 契約の例（AVCDecoderConfigurationRecord）
	sampleAudioDescriptionB64 = "EhA="                                     // 契約の例（AudioSpecificConfig: AAC-LC・44.1 kHz・2 ch）
)

func startJSON(profile string, mutate ...func(m map[string]string)) string {
	values := map[string]string{
		"profile":     `"` + profile + `"`,
		"vcodec":      `"avc1.4D401F"`,
		"width":       "1280",
		"height":      "720",
		"framerate":   "30",
		"vbitrate":    "4500",
		"vdesc":       `"` + sampleVideoDescriptionB64 + `"`,
		"acodec":      `"mp4a.40.2"`,
		"sample_rate": "44100",
		"channels":    "2",
		"abitrate":    "128",
		"adesc":       `"` + sampleAudioDescriptionB64 + `"`,
	}
	if profile == "480p" {
		values["width"], values["height"], values["vbitrate"] = "854", "480", "1500"
	}
	for _, m := range mutate {
		m(values)
	}
	return fmt.Sprintf(`{"profile":%s,"video":{"codec":%s,"width":%s,"height":%s,"framerate":%s,"bitrate_kbps":%s,"description_b64":%s},`+
		`"audio":{"codec":%s,"sample_rate":%s,"channels":%s,"bitrate_kbps":%s,"description_b64":%s}}`,
		values["profile"], values["vcodec"], values["width"], values["height"], values["framerate"], values["vbitrate"], values["vdesc"],
		values["acodec"], values["sample_rate"], values["channels"], values["abitrate"], values["adesc"])
}

func TestParseStartAcceptsTheContractExample(t *testing.T) {
	// 契約 ws-protocol.md の 5.3 の例そのもの
	example := `{"profile":"720p","video":{"codec":"avc1.4D401F","width":1280,"height":720,"framerate":30,"bitrate_kbps":4500,"description_b64":"AU1AH//hAA9nTUAfllQFAe2AoEA8IhEBAARo7jyA"},"audio":{"codec":"mp4a.40.2","sample_rate":44100,"channels":2,"bitrate_kbps":128,"description_b64":"EhA="}}`
	config, err := parseStart([]byte(example))
	if err != nil {
		t.Fatalf("parseStart: %v", err)
	}
	if config.Profile != contract.Profile720p || config.Video.Codec != contract.VideoCodecMain || config.Video.Width != 1280 ||
		config.Video.Height != 720 || config.Video.Framerate != 30 || config.Video.BitrateKbps != 4500 {
		t.Fatalf("video = %+v", config.Video)
	}
	if config.Audio.Codec != contract.AudioCodec || config.Audio.SampleRateHz != 44100 || config.Audio.Channels != 2 || config.Audio.BitrateKbps != 128 {
		t.Fatalf("audio = %+v", config.Audio)
	}
	wantVideo, _ := base64.StdEncoding.DecodeString(sampleVideoDescriptionB64)
	if string(config.Video.Description) != string(wantVideo) || len(config.Video.Description) == 0 || config.Video.Description[0] != 1 {
		t.Fatalf("the video description was not decoded: % x", config.Video.Description)
	}
	if string(config.Audio.Description) != "\x12\x10" {
		t.Fatalf("the audio description = % x, want 12 10", config.Audio.Description)
	}
}

func TestParseStartAcceptsEachProfileAndCodec(t *testing.T) {
	cases := []struct {
		name string
		body string
		want contract.Profile
	}{
		{"720p", startJSON("720p"), contract.Profile720p},
		{"480p", startJSON("480p"), contract.Profile480p},
		{"Constrained Baseline", startJSON("720p", func(m map[string]string) { m["vcodec"] = `"avc1.42E01F"` }), contract.Profile720p},
		{"映像ビットレートの下限（720p）", startJSON("720p", func(m map[string]string) { m["vbitrate"] = "3000" }), contract.Profile720p},
		{"映像ビットレートの上限（720p）", startJSON("720p", func(m map[string]string) { m["vbitrate"] = "6000" }), contract.Profile720p},
		{"映像ビットレートの下限（480p）", startJSON("480p", func(m map[string]string) { m["vbitrate"] = "800" }), contract.Profile480p},
		{"映像ビットレートの上限（480p）", startJSON("480p", func(m map[string]string) { m["vbitrate"] = "2500" }), contract.Profile480p},
		{"未知のキーは無視する", strings.Replace(startJSON("720p"), `{"profile"`, `{"x_note":"ignored","unknown":[1,2],"profile"`, 1), contract.Profile720p},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			config, err := parseStart([]byte(c.body))
			if err != nil {
				t.Fatalf("parseStart: %v", err)
			}
			if config.Profile != c.want {
				t.Fatalf("profile = %q", config.Profile)
			}
		})
	}
}

func TestParseStartRejectsInvalidBodies(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{"JSON ではない", "not json"},
		{"空", ""},
		{"配列", "[]"},
		{"null", "null"},
		{"プロファイルが無い", `{"video":{},"audio":{}}`},
		{"未知のプロファイル", startJSON("1080p")},
		{"プロファイルが空", startJSON("")},
		{"映像のコーデックが未知", startJSON("720p", func(m map[string]string) { m["vcodec"] = `"hev1.1.6.L93.B0"` })},
		{"映像の幅がプロファイルと違う", startJSON("720p", func(m map[string]string) { m["width"] = "1920" })},
		{"映像の高さがプロファイルと違う", startJSON("720p", func(m map[string]string) { m["height"] = "1080" })},
		{"720p に 480p の解像度", startJSON("720p", func(m map[string]string) { m["width"], m["height"] = "854", "480" })},
		{"フレームレートが違う", startJSON("720p", func(m map[string]string) { m["framerate"] = "60" })},
		{"映像ビットレートが下限未満（720p）", startJSON("720p", func(m map[string]string) { m["vbitrate"] = "2999" })},
		{"映像ビットレートが上限超過（720p）", startJSON("720p", func(m map[string]string) { m["vbitrate"] = "6001" })},
		{"映像ビットレートが下限未満（480p）", startJSON("480p", func(m map[string]string) { m["vbitrate"] = "799" })},
		{"映像ビットレートが上限超過（480p）", startJSON("480p", func(m map[string]string) { m["vbitrate"] = "2501" })},
		{"映像ビットレートが小数", startJSON("720p", func(m map[string]string) { m["vbitrate"] = "4500.5" })},
		{"映像ビットレートが文字列", startJSON("720p", func(m map[string]string) { m["vbitrate"] = `"4500"` })},
		{"音声のコーデックが違う", startJSON("720p", func(m map[string]string) { m["acodec"] = `"opus"` })},
		{"音声の周波数が違う", startJSON("720p", func(m map[string]string) { m["sample_rate"] = "48000" })},
		{"音声のチャンネル数が違う", startJSON("720p", func(m map[string]string) { m["channels"] = "1" })},
		{"音声のビットレートが違う", startJSON("720p", func(m map[string]string) { m["abitrate"] = "192" })},
		{"映像の復号器設定が base64 ではない", startJSON("720p", func(m map[string]string) { m["vdesc"] = `"@@@"` })},
		{"映像の復号器設定が URL 安全の文字集合", startJSON("720p", func(m map[string]string) { m["vdesc"] = `"AU1AH__hAA9nTUAfllQFAe2AoEA8IhEBAARo7jyA"` })},
		{"映像の復号器設定のパディングが無い", startJSON("720p", func(m map[string]string) { m["vdesc"] = `"EhA"` })},
		{"映像の復号器設定に空白", startJSON("720p", func(m map[string]string) { m["vdesc"] = `"AU1A H//h"` })},
		{"映像の復号器設定が空", startJSON("720p", func(m map[string]string) { m["vdesc"] = `""` })},
		{"映像の復号器設定が無い", startJSON("720p", func(m map[string]string) { m["vdesc"] = `null` })},
		{"音声の復号器設定が base64 ではない", startJSON("720p", func(m map[string]string) { m["adesc"] = `"***"` })},
		{"音声の復号器設定が空", startJSON("720p", func(m map[string]string) { m["adesc"] = `""` })},
		{"音声の復号器設定の末尾のビットが非 0", startJSON("720p", func(m map[string]string) { m["adesc"] = `"EhB="` })},
		{"映像の復号器設定が大きすぎる", startJSON("720p", func(m map[string]string) {
			m["vdesc"] = `"` + base64.StdEncoding.EncodeToString(make([]byte, maxDescriptionBytes+1)) + `"`
		})},
		{"audio が無い", `{"profile":"720p","video":{"codec":"avc1.4D401F","width":1280,"height":720,"framerate":30,"bitrate_kbps":4500,"description_b64":"AU1AH//hAA9nTUAfllQFAe2AoEA8IhEBAARo7jyA"}}`},
		{"video が無い", `{"profile":"720p","audio":{"codec":"mp4a.40.2","sample_rate":44100,"channels":2,"bitrate_kbps":128,"description_b64":"EhA="}}`},
		{"本文が大きすぎる", `{"profile":"720p","x_pad":"` + strings.Repeat("a", maxControlBodyBytes) + `"}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if config, err := parseStart([]byte(c.body)); err == nil {
				t.Fatalf("parseStart accepted the body: %+v", config)
			}
		})
	}
}

func reportJSON(events string, mutate ...func(m map[string]string)) string {
	values := map[string]string{"backlog": "1800", "dropped": "12", "target": "3000", "state": `"degraded"`}
	for _, m := range mutate {
		m(values)
	}
	return fmt.Sprintf(`{"backlog_ms":%s,"dropped_video_frames":%s,"target_kbps":%s,"state":%s,"events":%s}`,
		values["backlog"], values["dropped"], values["target"], values["state"], events)
}

func TestParseReportAcceptsTheContractExample(t *testing.T) {
	example := `{"backlog_ms":1800,"dropped_video_frames":12,"target_kbps":3000,"state":"degraded","events":[{"kind":"bitrate_down","detail":{"from_kbps":3300,"to_kbps":3000}},{"kind":"video_dropped","detail":{"frames":12}},{"kind":"degraded_started"}]}`
	report, err := parseReport([]byte(example), 64)
	if err != nil {
		t.Fatalf("parseReport: %v", err)
	}
	if report.BacklogMs != 1800 || report.DroppedVideoFrames != 12 || report.TargetKbps != 3000 || report.State != contract.StudioStateDegraded {
		t.Fatalf("report = %+v", report)
	}
	if len(report.Events) != 3 {
		t.Fatalf("events = %+v", report.Events)
	}
	if report.Events[0].Kind != contract.BrowserEventKindBitrateDown || string(report.Events[0].Detail) != `{"from_kbps":3300,"to_kbps":3000}` {
		t.Fatalf("event 0 = %+v (detail %s)", report.Events[0], report.Events[0].Detail)
	}
	if report.Events[1].Kind != contract.BrowserEventKindVideoDropped || string(report.Events[1].Detail) != `{"frames":12}` {
		t.Fatalf("event 1 = %+v", report.Events[1])
	}
	if report.Events[2].Kind != contract.BrowserEventKindDegradedStarted || len(report.Events[2].Detail) != 0 {
		t.Fatalf("event 2 = %+v", report.Events[2])
	}
}

func TestParseReportAcceptsAllowedShapes(t *testing.T) {
	cases := []struct {
		name       string
		body       string
		wantEvents int
		wantDetail string
	}{
		{"出来事が空", reportJSON(`[]`), 0, ""},
		{"events が無い", `{"backlog_ms":0,"dropped_video_frames":0,"target_kbps":4500,"state":"live"}`, 0, ""},
		{"events が null", reportJSON(`null`), 0, ""},
		{"状態 live", reportJSON(`[]`, func(m map[string]string) { m["state"] = `"live"` }), 0, ""},
		{"滞留 0", reportJSON(`[]`, func(m map[string]string) { m["backlog"] = "0" }), 0, ""},
		{"detail が空のオブジェクト", reportJSON(`[{"kind":"source_lost","detail":{}}]`), 1, ""},
		{"detail が文字列", reportJSON(`[{"kind":"source_lost","detail":{"source":"camera"}}]`), 1, `{"source":"camera"}`},
		{"detail が 4 組", reportJSON(`[{"kind":"fallback_switched","detail":{"a":1,"b":2,"c":3,"d":4}}]`), 1, `{"a":1,"b":2,"c":3,"d":4}`},
		{"detail の負の整数", reportJSON(`[{"kind":"bitrate_down","detail":{"delta":-5}}]`), 1, `{"delta":-5}`},
		{"detail の文字列の長さ 32", reportJSON(`[{"kind":"source_lost","detail":{"s":"` + strings.Repeat("a", 32) + `"}}]`), 1, `{"s":"` + strings.Repeat("a", 32) + `"}`},
		{"detail のキーの長さ 32", reportJSON(`[{"kind":"source_lost","detail":{"` + strings.Repeat("k", 32) + `":1}}]`), 1, `{"` + strings.Repeat("k", 32) + `":1}`},
		{"キーの順は問わない（整列して返す）", reportJSON(`[{"kind":"fallback_switched","detail":{"z":1,"a":2}}]`), 1, `{"a":2,"z":1}`},
		{"未知のキーを無視する", reportJSON(`[{"kind":"source_lost","x_note":"n","detail":{"source":"screen"}}]`, func(m map[string]string) {}), 1, `{"source":"screen"}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			report, err := parseReport([]byte(c.body), 64)
			if err != nil {
				t.Fatalf("parseReport: %v", err)
			}
			if len(report.Events) != c.wantEvents {
				t.Fatalf("events = %d, want %d", len(report.Events), c.wantEvents)
			}
			if c.wantEvents == 1 && string(report.Events[0].Detail) != c.wantDetail {
				t.Fatalf("detail = %q, want %q", report.Events[0].Detail, c.wantDetail)
			}
		})
	}
}

func TestParseReportRejectsInvalidBodies(t *testing.T) {
	longKey := strings.Repeat("k", 33)
	cases := []struct {
		name string
		body string
	}{
		{"JSON ではない", "x"},
		{"配列", "[]"},
		{"滞留が負", reportJSON(`[]`, func(m map[string]string) { m["backlog"] = "-1" })},
		{"滞留が小数", reportJSON(`[]`, func(m map[string]string) { m["backlog"] = "1.5" })},
		{"滞留が指数表記", reportJSON(`[]`, func(m map[string]string) { m["backlog"] = "1e3" })},
		{"滞留が文字列", reportJSON(`[]`, func(m map[string]string) { m["backlog"] = `"5"` })},
		{"滞留が無い", `{"dropped_video_frames":0,"target_kbps":3000,"state":"live"}`},
		{"破棄数が負", reportJSON(`[]`, func(m map[string]string) { m["dropped"] = "-1" })},
		{"目標が 0", reportJSON(`[]`, func(m map[string]string) { m["target"] = "0" })},
		{"目標が負", reportJSON(`[]`, func(m map[string]string) { m["target"] = "-3000" })},
		{"状態が配信中の 2 つ以外（idle）", reportJSON(`[]`, func(m map[string]string) { m["state"] = `"idle"` })},
		{"状態が配信中の 2 つ以外（reconnecting）", reportJSON(`[]`, func(m map[string]string) { m["state"] = `"reconnecting"` })},
		{"状態が無い", `{"backlog_ms":0,"dropped_video_frames":0,"target_kbps":3000}`},
		{"events が配列ではない", reportJSON(`{"kind":"source_lost"}`)},
		{"出来事の種類が未知", reportJSON(`[{"kind":"weird"}]`)},
		{"出来事の種類が無い", reportJSON(`[{"detail":{}}]`)},
		{"出来事が配信の出来事だが、ブラウザ側ではない", reportJSON(`[{"kind":"interrupted"}]`)},
		{"detail が配列", reportJSON(`[{"kind":"source_lost","detail":[1]}]`)},
		{"detail が文字列", reportJSON(`[{"kind":"source_lost","detail":"camera"}]`)},
		{"detail が null", reportJSON(`[{"kind":"source_lost","detail":null}]`)},
		{"detail の値が入れ子", reportJSON(`[{"kind":"source_lost","detail":{"a":{"b":1}}}]`)},
		{"detail の値が配列", reportJSON(`[{"kind":"source_lost","detail":{"a":[1]}}]`)},
		{"detail の値が null", reportJSON(`[{"kind":"source_lost","detail":{"a":null}}]`)},
		{"detail の値が真偽値", reportJSON(`[{"kind":"source_lost","detail":{"a":true}}]`)},
		{"detail の値が小数", reportJSON(`[{"kind":"source_lost","detail":{"a":1.5}}]`)},
		{"detail の値が指数表記", reportJSON(`[{"kind":"source_lost","detail":{"a":1e3}}]`)},
		{"detail の値が大きすぎる整数", reportJSON(`[{"kind":"source_lost","detail":{"a":99999999999999999999}}]`)},
		{"detail の文字列が空", reportJSON(`[{"kind":"source_lost","detail":{"a":""}}]`)},
		{"detail の文字列が大文字", reportJSON(`[{"kind":"source_lost","detail":{"a":"Camera"}}]`)},
		{"detail の文字列に空白（自由記述）", reportJSON(`[{"kind":"source_lost","detail":{"a":"my webcam"}}]`)},
		{"detail の文字列に日本語", reportJSON(`[{"kind":"source_lost","detail":{"a":"` + "カメラ" + `"}}]`)},
		{"detail の文字列が 33 文字", reportJSON(`[{"kind":"source_lost","detail":{"a":"` + strings.Repeat("a", 33) + `"}}]`)},
		{"detail のキーが大文字", reportJSON(`[{"kind":"source_lost","detail":{"Source":1}}]`)},
		{"detail のキーが数字で始まる", reportJSON(`[{"kind":"source_lost","detail":{"1a":1}}]`)},
		{"detail のキーが 33 文字", reportJSON(`[{"kind":"source_lost","detail":{"` + longKey + `":1}}]`)},
		{"detail のキーが空", reportJSON(`[{"kind":"source_lost","detail":{"":1}}]`)},
		{"detail が 5 組", reportJSON(`[{"kind":"source_lost","detail":{"a":1,"b":2,"c":3,"d":4,"e":5}}]`)},
		{"出来事が多すぎる", reportJSON(`[` + strings.TrimSuffix(strings.Repeat(`{"kind":"source_lost"},`, 65), ",") + `]`)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if report, err := parseReport([]byte(c.body), 64); err == nil {
				t.Fatalf("parseReport accepted the body: %+v", report)
			}
		})
	}
}

func TestParseReportAcceptsExactlyTheEventLimit(t *testing.T) {
	body := reportJSON(`[` + strings.TrimSuffix(strings.Repeat(`{"kind":"source_lost"},`, 64), ",") + `]`)
	report, err := parseReport([]byte(body), 64)
	if err != nil {
		t.Fatalf("parseReport: %v", err)
	}
	if len(report.Events) != 64 {
		t.Fatalf("events = %d", len(report.Events))
	}
}

func TestParseEnd(t *testing.T) {
	cases := []struct {
		name    string
		body    string
		want    contract.EndReason
		wantErr bool
	}{
		{"利用者の停止", `{"reason":"user_stop"}`, contract.EndReasonUserStop, false},
		{"利用者の取り消し", `{"reason":"user_cancel"}`, contract.EndReasonUserCancel, false},
		{"回線不足", `{"reason":"insufficient_bandwidth"}`, contract.EndReasonInsufficientBandwidth, false},
		{"未知のキーを無視する", `{"reason":"user_stop","x_note":1}`, contract.EndReasonUserStop, false},
		{"ブラウザが伝えられない理由（time_limit）", `{"reason":"time_limit"}`, "", true},
		{"ブラウザが伝えられない理由（relay_disconnect）", `{"reason":"relay_disconnect"}`, "", true},
		{"未知の理由", `{"reason":"because"}`, "", true},
		{"理由が無い", `{}`, "", true},
		{"理由が数値", `{"reason":1}`, "", true},
		{"JSON ではない", "x", "", true},
		{"空", "", "", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := parseEnd([]byte(c.body))
			if c.wantErr {
				if err == nil {
					t.Fatalf("parseEnd accepted the body: %q", got)
				}
				return
			}
			if err != nil || got != c.want {
				t.Fatalf("parseEnd = %q, %v; want %q", got, err, c.want)
			}
		})
	}
}
