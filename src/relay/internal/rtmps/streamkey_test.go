package rtmps

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"testing"
)

// 配信キーは、メモリ以外へ出さない（requirements.md 6.1・10.1・28.1）。ログ・エラー・%v・JSON のどこにも、現れない。
// 試験の値は、明らかなダミー。

const dummyStreamKey = "dummy-stream-key-SECRET-0123456789"

func TestStreamKeyValidate(t *testing.T) {
	cases := []struct {
		name    string
		key     StreamKey
		wantErr bool
	}{
		{name: "YouTube の配信キーの形", key: "abcd-efgh-ijkl-mnop-qrst"},
		{name: "ダミー", key: dummyStreamKey},
		{name: "1 文字（下限）", key: "k"},
		{name: "記号を含む", key: "a.b_c-d~e!f"},
		{name: "上限ちょうど", key: StreamKey(strings.Repeat("k", maxStreamKeyBytes))},
		{name: "空", key: "", wantErr: true},
		{name: "上限を 1 バイト超える", key: StreamKey(strings.Repeat("k", maxStreamKeyBytes+1)), wantErr: true},
		{name: "空白", key: "abcd efgh", wantErr: true},
		{name: "前に空白", key: " abcd", wantErr: true},
		{name: "後ろに空白", key: "abcd ", wantErr: true},
		{name: "タブ", key: "abcd\tefgh", wantErr: true},
		{name: "改行", key: "abcd\nefgh", wantErr: true},
		{name: "NUL", key: "abcd\x00efgh", wantErr: true},
		{name: "DEL", key: "abcd\x7fefgh", wantErr: true},
		{name: "非 ASCII", key: StreamKey("abcd" + string(rune(0x00E9)) + "efgh"), wantErr: true},
		{name: "全角", key: StreamKey("abcd" + string(rune(0xFF21)) + "efgh"), wantErr: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := c.key.Validate()
			if !c.wantErr {
				if err != nil {
					t.Fatalf("Validate: %v", err)
				}
				return
			}
			if !errors.Is(err, ErrInvalidStreamKey) {
				t.Fatalf("Validate error = %v, want ErrInvalidStreamKey", err)
			}
			// エラーは、キーの内容を含まない
			for _, text := range []string{err.Error(), fmt.Sprintf("%v", err), fmt.Sprintf("%+v", err), fmt.Sprintf("%#v", err)} {
				if len(c.key) >= 4 && strings.Contains(text, string(c.key)) {
					t.Errorf("the error contains the key: %q", text)
				}
			}
		})
	}
}

// 不正なキーのエラーに、キーの一部（不正な文字の値）も含めない。
func TestStreamKeyErrorDoesNotContainAnyPartOfTheKey(t *testing.T) {
	key := StreamKey("SECRET-PREFIX-" + string(rune(0x00E9)) + "-SECRET-SUFFIX")
	err := key.Validate()
	if !errors.Is(err, ErrInvalidStreamKey) {
		t.Fatalf("error = %v, want ErrInvalidStreamKey", err)
	}
	for _, part := range []string{"SECRET", "PREFIX", "SUFFIX", string(rune(0x00E9))} {
		if strings.Contains(err.Error(), part) {
			t.Errorf("the error contains %q: %q", part, err.Error())
		}
	}
}

func TestStreamKeyIsRedactedWhenFormatted(t *testing.T) {
	key := StreamKey(dummyStreamKey)
	pointerKey := &key
	values := []any{
		key, pointerKey, []StreamKey{key}, map[string]StreamKey{"key": key}, struct{ Key StreamKey }{key}, &struct{ Key StreamKey }{key},
		[]any{key}, map[StreamKey]int{key: 1},
	}
	verbs := []string{"%v", "%+v", "%#v", "%s", "%q", "%x", "%X", "%d", "%10v", "%-30s", "%.5s", "%T"}
	for _, value := range values {
		for _, verb := range verbs {
			text := fmt.Sprintf(verb, value)
			if strings.Contains(text, dummyStreamKey) || strings.Contains(text, "SECRET") || strings.Contains(text, "0123456789") {
				t.Errorf("Sprintf(%q, %T) exposed the key: %q", verb, value, text)
			}
		}
	}
	for _, text := range []string{key.String(), key.GoString(), fmt.Sprint(key), fmt.Sprintln(key), fmt.Errorf("publish failed: %v", key).Error(), fmt.Errorf("publish failed: %w", errors.New(fmt.Sprint(key))).Error()} {
		if strings.Contains(text, "SECRET") {
			t.Errorf("the key was exposed: %q", text)
		}
	}
	if key.String() == "" {
		t.Errorf("String() should say that the key is hidden, not be empty")
	}
}

func TestStreamKeyIsRedactedInStructuredOutput(t *testing.T) {
	key := StreamKey(dummyStreamKey)

	// JSON
	for name, value := range map[string]any{
		"値":         key,
		"構造体のフィールド": struct{ Key StreamKey }{key},
		"ポインタ":      &key,
		"スライス":      []StreamKey{key},
		"マップの値":     map[string]StreamKey{"k": key},
	} {
		encoded, err := json.Marshal(value)
		if err != nil {
			t.Fatalf("%s: Marshal: %v", name, err)
		}
		if strings.Contains(string(encoded), "SECRET") {
			t.Errorf("%s: JSON exposed the key: %s", name, encoded)
		}
	}

	// テキスト
	text, err := key.MarshalText()
	if err != nil {
		t.Fatalf("MarshalText: %v", err)
	}
	if strings.Contains(string(text), "SECRET") {
		t.Errorf("MarshalText exposed the key: %s", text)
	}

	// slog（テキスト・JSON のどちらの出力でも）
	var textOut, jsonOut bytes.Buffer
	textLogger := slog.New(slog.NewTextHandler(&textOut, nil))
	jsonLogger := slog.New(slog.NewJSONHandler(&jsonOut, nil))
	for _, logger := range []*slog.Logger{textLogger, jsonLogger} {
		logger.Info("publish", "key", key, slog.Any("again", key), slog.Group("g", slog.Any("inner", &key)))
	}
	for name, out := range map[string]string{"text": textOut.String(), "json": jsonOut.String()} {
		if out == "" {
			t.Fatalf("%s logger wrote nothing", name)
		}
		if strings.Contains(out, "SECRET") || strings.Contains(out, dummyStreamKey) {
			t.Errorf("slog (%s) exposed the key: %s", name, out)
		}
	}
}

// JSON から配信キーを読める（内部通信の準備の応答を、そのまま型へ読み込める）。書き出しは伏せる。
func TestStreamKeyCanBeDecodedFromJSON(t *testing.T) {
	var response struct {
		Ingest struct {
			URL       string    `json:"url"`
			StreamKey StreamKey `json:"stream_key"`
		} `json:"ingest"`
	}
	body := `{"ingest":{"url":"rtmps://a.rtmps.youtube.com:443/live2","stream_key":"` + dummyStreamKey + `"}}`
	if err := json.Unmarshal([]byte(body), &response); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if response.Ingest.StreamKey.reveal() != dummyStreamKey {
		t.Fatalf("the decoded key does not match")
	}
	if err := response.Ingest.StreamKey.Validate(); err != nil {
		t.Fatalf("Validate: %v", err)
	}
	encoded, err := json.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "SECRET") {
		t.Errorf("re-encoding exposed the key: %s", encoded)
	}
}
