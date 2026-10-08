package backend

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync"
	"testing"
)

// 試験の補助。アプリケーションの疑似（httptest のローカルのサーバー）と、JSON の比較。実際のアプリケーションは呼ばない。

func isError(err, target error) bool { return errors.Is(err, target) }

// 契約 internal-api.md の例どおりの、正常な応答の本文。
const (
	sampleBroadcastID = "2f6c1d0e-7b5a-4f0e-9a43-5c8f1e2d3a4b"
	sampleAccountKey  = "3f1b2c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809"

	sampleVerifyBody = `{"broadcast_id":"` + sampleBroadcastID + `","state":"reserved","epoch":1,"account_key":"` + sampleAccountKey +
		`","profile":null,"limits":{"time_limit_seconds":3600}}`
	sampleProvisionBody = `{"ingest":{"url":"rtmps://a.rtmps.youtube.com:443/live2","stream_key":"dummy-stream-key"},` +
		`"watch_url":"https://www.youtube.com/watch?v=dummyVideoId","state":"awaiting_media"}`
	sampleHeartbeatBody = `{"command":"continue","notices":[{"kind":"status","state":"live",` +
		`"watch_url":"https://www.youtube.com/watch?v=dummyVideoId","warning":null,"time_limit_notice_seconds":null,"end_reason":null}]}`
)

type recordedRequest struct {
	Method string
	Path   string
	Header http.Header
	Body   []byte
}

// fakeApp は、アプリケーションの内部通信の口の疑似。受けた要求を記録し、respond が応答を決める。
type fakeApp struct {
	server *httptest.Server

	mu       sync.Mutex
	requests []recordedRequest
	respond  func(w http.ResponseWriter, r *http.Request)
}

func newFakeApp(t *testing.T, respond func(w http.ResponseWriter, r *http.Request)) *fakeApp {
	t.Helper()
	app := &fakeApp{respond: respond}
	app.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		app.mu.Lock()
		app.requests = append(app.requests, recordedRequest{Method: r.Method, Path: r.URL.Path, Header: r.Header.Clone(), Body: body})
		handler := app.respond
		app.mu.Unlock()
		r.Body = io.NopCloser(bytes.NewReader(body))
		handler(w, r)
	}))
	t.Cleanup(app.server.Close)
	return app
}

func (a *fakeApp) setRespond(respond func(w http.ResponseWriter, r *http.Request)) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.respond = respond
}

func (a *fakeApp) recorded() []recordedRequest {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]recordedRequest(nil), a.requests...)
}

func (a *fakeApp) only(t *testing.T) recordedRequest {
	t.Helper()
	requests := a.recorded()
	if len(requests) != 1 {
		t.Fatalf("the app received %d requests, want 1", len(requests))
	}
	return requests[0]
}

// reply は、固定の応答を返す handler。
func reply(status int, body string) func(w http.ResponseWriter, r *http.Request) {
	return func(w http.ResponseWriter, _ *http.Request) {
		if body != "" {
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
		}
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}
}

// errorBody は、契約 internal-api.md の 2 章の、エラーの本文。
func errorBody(code string, details string) string {
	if details == "" {
		return `{"error":{"code":"` + code + `"}}`
	}
	return `{"error":{"code":"` + code + `","details":` + details + `}}`
}

func newTestClient(t *testing.T, app *fakeApp, mutate ...func(*Config)) *Client {
	t.Helper()
	cfg := Config{BaseURL: app.server.URL, Secret: Secret(canarySecret)}
	for _, m := range mutate {
		m(&cfg)
	}
	client, err := NewClient(cfg)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	return client
}

// assertJSONEqual は、2 つの JSON が、キーの順・空白によらず、同じ値かを調べる。
func assertJSONEqual(t *testing.T, got []byte, want string) {
	t.Helper()
	var gotValue, wantValue any
	if err := json.Unmarshal(got, &gotValue); err != nil {
		t.Fatalf("the body is not JSON: %v: %q", err, got)
	}
	if err := json.Unmarshal([]byte(want), &wantValue); err != nil {
		t.Fatalf("the expected body is not JSON: %v", err)
	}
	if !reflect.DeepEqual(gotValue, wantValue) {
		t.Fatalf("body = %s\nwant   %s", got, want)
	}
}
