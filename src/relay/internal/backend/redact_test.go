package backend

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"testing"
)

// 共有の秘密値・接続チケット・取り込み先は、ログ・エラー・%v・JSON のどこにも出さない（requirements.md 6.1・28.1。
// 契約 internal-api.md の 1 章「機密」）。試験の値は、明らかなダミー。

const (
	canarySecret = "dummy-shared-secret-CANARY-0001"
	canaryTicket = "dummy-ticket-CANARY-0002-abcdefghijklmnopqrstuvwxyz"
	canaryURL    = "rtmps://dummy-ingest-CANARY-0003.example/live2"
)

func TestSensitiveValuesAreRedactedWhenFormatted(t *testing.T) {
	secret := Secret(canarySecret)
	ticket := Ticket(canaryTicket)
	ingest := IngestURL(canaryURL)
	values := []struct {
		name   string
		value  any
		canary string
	}{
		{"Secret", secret, canarySecret},
		{"*Secret", &secret, canarySecret},
		{"Ticket", ticket, canaryTicket},
		{"*Ticket", &ticket, canaryTicket},
		{"IngestURL", ingest, canaryURL},
		{"*IngestURL", &ingest, canaryURL},
		{"VerifyResult の組み込み", struct{ T Ticket }{ticket}, canaryTicket},
		{"ProvisionResult", ProvisionResult{Ingest: Ingest{URL: ingest, StreamKey: "dummy-stream-key-CANARY-0004"}}, canaryURL},
	}
	verbs := []string{"%v", "%+v", "%#v", "%s", "%q", "%x", "%d", "%T"}
	for _, v := range values {
		for _, verb := range verbs {
			t.Run(v.name+" "+verb, func(t *testing.T) {
				text := fmt.Sprintf(verb, v.value)
				if verb != "%T" && strings.Contains(text, v.canary) {
					t.Fatalf("%s leaked the value: %q", verb, text)
				}
				if strings.Contains(text, "CANARY") {
					t.Fatalf("%s leaked a canary: %q", verb, text)
				}
			})
		}
	}
}

func TestSensitiveValuesAreRedactedInJSONAndText(t *testing.T) {
	secret := Secret(canarySecret)
	ticket := Ticket(canaryTicket)
	ingest := IngestURL(canaryURL)

	encoded, err := json.Marshal(struct {
		S Secret    `json:"s"`
		T Ticket    `json:"t"`
		U IngestURL `json:"u"`
	}{secret, ticket, ingest})
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if strings.Contains(string(encoded), "CANARY") {
		t.Fatalf("JSON leaked a value: %s", encoded)
	}
	for _, text := range []interface{ MarshalText() ([]byte, error) }{secret, ticket, ingest} {
		out, err := text.MarshalText()
		if err != nil || strings.Contains(string(out), "CANARY") {
			t.Fatalf("MarshalText leaked a value: %q, %v", out, err)
		}
	}
}

func TestSensitiveValuesAreRedactedInStructuredLogs(t *testing.T) {
	var text, jsonOut bytes.Buffer
	textLog := slog.New(slog.NewTextHandler(&text, nil))
	jsonLog := slog.New(slog.NewJSONHandler(&jsonOut, nil))
	for _, log := range []*slog.Logger{textLog, jsonLog} {
		log.Info("sample", "secret", Secret(canarySecret), "ticket", Ticket(canaryTicket), "url", IngestURL(canaryURL),
			slog.Any("any", Ticket(canaryTicket)))
	}
	for name, out := range map[string]string{"text": text.String(), "json": jsonOut.String()} {
		if strings.Contains(out, "CANARY") {
			t.Errorf("%s log leaked a value: %s", name, out)
		}
		if out == "" {
			t.Errorf("%s log is empty (the test did not log)", name)
		}
	}
}

func TestSensitiveValuesCanBeReadFromJSON(t *testing.T) {
	var decoded struct {
		URL IngestURL `json:"url"`
	}
	if err := json.Unmarshal([]byte(`{"url":"`+canaryURL+`"}`), &decoded); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if string(decoded.URL) != canaryURL {
		t.Fatalf("the value was not read: %q", string(decoded.URL))
	}
}

func TestNewTicketChecksTheSyntax(t *testing.T) {
	cases := []struct {
		name    string
		raw     string
		wantErr bool
	}{
		{"URL 安全な文字", "AbC-_123456789012345678901234567890123", false},
		{"1 文字", "a", false},
		{"上限ちょうど", strings.Repeat("a", MaxTicketBytes), false},
		{"空", "", true},
		{"上限を超える", strings.Repeat("a", MaxTicketBytes+1), true},
		{"空白", "abc def", true},
		{"改行", "abc\ndef", true},
		{"NUL", "abc\x00def", true},
		{"DEL", "abc\x7fdef", true},
		{"非 ASCII", "abcédef", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ticket, err := NewTicket([]byte(c.raw))
			if c.wantErr {
				if err == nil {
					t.Fatalf("NewTicket(%q) succeeded", c.raw)
				}
				if !isError(err, ErrTicketInvalid) {
					t.Fatalf("error = %v, want ErrTicketInvalid", err)
				}
				if c.raw != "" && strings.Contains(err.Error(), c.raw) {
					t.Fatalf("the error contains the ticket: %q", err.Error())
				}
				return
			}
			if err != nil {
				t.Fatalf("NewTicket: %v", err)
			}
			if ticket.reveal() != c.raw {
				t.Fatalf("ticket = %q, want %q", ticket.reveal(), c.raw)
			}
		})
	}
}
