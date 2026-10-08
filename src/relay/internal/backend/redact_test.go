package backend

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
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

// ---- Client（共有の秘密値を、非公開の欄に持つ） ----
//
// fmt は、非公開の欄のメソッドを呼ばない。欄の型（Secret）が伏せる実装を持っていても、Client の整形が何も握らないと、
// %+v などで中身の文字列がそのまま出る。そのため、Client 自身が整形を握る（値レシーバ。Client の値でも *Client でも効く）。

const redactedClientText = "backend.Client{}"

func newRedactionClient(t *testing.T) *Client {
	t.Helper()
	client, err := NewClient(Config{BaseURL: "http://backend.invalid:3101", Secret: Secret(canarySecret)})
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	return client
}

// assertNoSharedSecret は、text に、共有の秘密値が（そのままでも、16 進数でも）含まれないことを確かめる。
func assertNoSharedSecret(t *testing.T, what, text string) {
	t.Helper()
	for _, leaked := range []string{canarySecret, "CANARY", hex.EncodeToString([]byte(canarySecret))} {
		if strings.Contains(text, leaked) {
			t.Fatalf("%s leaked the shared secret (%q):\n%s", what, leaked, text)
		}
	}
}

func clientValues(client *Client) map[string]any {
	return map[string]any{"*Client": client, "Client": *client}
}

func TestFormattingTheClientNeverExposesTheSharedSecret(t *testing.T) {
	client := newRedactionClient(t)
	verbs := []string{"%v", "%+v", "%#v", "%s", "%q", "%x", "%d"}
	for name, value := range clientValues(client) {
		for _, verb := range verbs {
			t.Run(name+" "+verb, func(t *testing.T) {
				assertNoSharedSecret(t, verb, fmt.Sprintf(verb, value))
			})
		}
		t.Run(name+" Sprint・Sprintln", func(t *testing.T) {
			assertNoSharedSecret(t, "Sprint", fmt.Sprint(value))
			assertNoSharedSecret(t, "Sprintln", fmt.Sprintln(value))
		})
		t.Run(name+" 構造体の欄として", func(t *testing.T) {
			wrapped := struct {
				Backend any
				Pointer *Client
			}{Backend: value, Pointer: client}
			assertNoSharedSecret(t, "a struct holding the client", fmt.Sprintf("%v %+v %#v", wrapped, wrapped, wrapped))
		})
		t.Run(name+" log パッケージ", func(t *testing.T) {
			var out bytes.Buffer
			logger := log.New(&out, "", 0)
			logger.Printf("%v", value)
			logger.Printf("%+v", value)
			logger.Println(value)
			if out.Len() == 0 {
				t.Fatal("nothing was logged; the check below would pass vacuously")
			}
			assertNoSharedSecret(t, "the log package", out.String())
		})
	}
}

func TestTheClientPrintsOnlyAFixedText(t *testing.T) {
	client := newRedactionClient(t)
	for name, value := range clientValues(client) {
		for _, verb := range []string{"%v", "%+v", "%#v", "%s"} {
			t.Run(name+" "+verb, func(t *testing.T) {
				if got := fmt.Sprintf(verb, value); got != redactedClientText {
					t.Fatalf("%s = %q, want the fixed text %q (the internal URL and the secret must not appear)", verb, got, redactedClientText)
				}
			})
		}
	}
}

func TestTheClientDefinesEveryFormattingGuard(t *testing.T) {
	for name, value := range map[string]any{"Client": Client{}, "*Client": &Client{}} {
		t.Run(name, func(t *testing.T) {
			if _, ok := value.(fmt.Stringer); !ok {
				t.Error("String is missing")
			}
			if _, ok := value.(fmt.GoStringer); !ok {
				t.Error("GoString is missing")
			}
			if _, ok := value.(fmt.Formatter); !ok {
				t.Error("Format is missing")
			}
			valuer, ok := value.(slog.LogValuer)
			if !ok {
				t.Fatal("LogValue is missing")
			}
			if got := valuer.LogValue().String(); got != redactedClientText {
				t.Errorf("LogValue = %q, want %q", got, redactedClientText)
			}
		})
	}
}

func TestTheClientIsRedactedInStructuredLogs(t *testing.T) {
	client := newRedactionClient(t)
	var text, jsonOut bytes.Buffer
	textLog := slog.New(slog.NewTextHandler(&text, nil))
	jsonLog := slog.New(slog.NewJSONHandler(&jsonOut, nil))
	for _, logger := range []*slog.Logger{textLog, jsonLog} {
		logger.Info("sample", "client", client, "value", *client, slog.Any("any", client), slog.Any("anyValue", *client))
		logger.With("client", client).Warn("with")
		logger.WithGroup("group").Error("grouped", slog.Any("client", client))
	}
	for name, out := range map[string]string{"text": text.String(), "json": jsonOut.String()} {
		if out == "" {
			t.Errorf("the %s log is empty (the test did not log)", name)
		}
		assertNoSharedSecret(t, "the "+name+" log", out)
	}
}

func TestEncodingTheClientNeverExposesTheSharedSecret(t *testing.T) {
	client := newRedactionClient(t)
	encoded, err := json.Marshal(struct {
		Pointer *Client
		Value   Client
	}{client, *client})
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	assertNoSharedSecret(t, "the JSON encoding", string(encoded))
}
