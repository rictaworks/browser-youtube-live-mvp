package server

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/appenv"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/config"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps"
)

const (
	testSecret = "dummy-shared-secret-SECRET-0001"
	// testInternalURL は、どこにも繋がらない接続先（この試験では、アプリケーションを呼ばない）
	testInternalURL = "http://127.0.0.1:9"
)

func testConfig(env appenv.Environment) config.Config {
	return config.Config{Environment: env, ListenAddr: ":0", BackendInternalURL: testInternalURL, SharedSecret: backend.Secret(testSecret)}
}

func newTestApp(t *testing.T, env appenv.Environment, mutate ...func(*Deps)) *App {
	t.Helper()
	deps := Deps{}
	for _, m := range mutate {
		m(&deps)
	}
	app, err := NewApp(testConfig(env), deps)
	if err != nil {
		t.Fatalf("NewApp() error = %v; want nil", err)
	}
	return app
}

func TestNewAppRejectsAnInvalidInternalConfigWithoutEchoingIt(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*config.Config)
	}{
		{"接続先が http(s) ではない", func(c *config.Config) { c.BackendInternalURL = "ftp://backend.internal.example:3101" }},
		{"接続先にパスがある", func(c *config.Config) { c.BackendInternalURL = "http://backend.internal.example:3101/internal" }},
		{"接続先にユーザー情報がある", func(c *config.Config) {
			c.BackendInternalURL = "http://user:dummy-pass-SECRET@backend.internal.example:3101"
		}},
		{"秘密値に空白がある", func(c *config.Config) { c.SharedSecret = backend.Secret("dummy secret SECRET with spaces") }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := testConfig(appenv.Test)
			tc.mutate(&cfg)
			app, err := NewApp(cfg, Deps{})
			if err == nil {
				t.Fatalf("NewApp() = %v, nil; want an error", app)
			}
			if !errors.Is(err, backend.ErrInvalidConfig) {
				t.Errorf("NewApp() error = %v; want backend.ErrInvalidConfig", err)
			}
			for _, leaked := range []string{"SECRET", "dummy-pass", "backend.internal.example", testSecret} {
				if strings.Contains(err.Error(), leaked) {
					t.Errorf("error text %q must not contain %q", err.Error(), leaked)
				}
			}
		})
	}
}

// 送出先の許可リストは、環境から決める。production には、開発用の疑似の取り込み口が存在しない。差し替えは、production では拒否する
func TestDestinationPolicyFollowsTheEnvironment(t *testing.T) {
	contains := func(policy rtmps.Policy, host string) bool {
		for _, target := range policy.Targets() {
			if target.Host == host {
				return true
			}
		}
		return false
	}
	production, err := DestinationPolicy(appenv.Production, nil)
	if err != nil {
		t.Fatalf("DestinationPolicy(production) error = %v", err)
	}
	if !contains(production, "a.rtmps.youtube.com") || !contains(production, "b.rtmps.youtube.com") {
		t.Errorf("production targets = %v; want the YouTube ingest hosts", production.Targets())
	}
	if contains(production, "fake-ingest") {
		t.Errorf("production targets = %v; the development ingest must not exist in production", production.Targets())
	}
	for _, env := range []appenv.Environment{appenv.Development, appenv.Test} {
		policy, err := DestinationPolicy(env, nil)
		if err != nil {
			t.Fatalf("DestinationPolicy(%s) error = %v", env, err)
		}
		if !contains(policy, "fake-ingest") || !contains(policy, "a.rtmps.youtube.com") {
			t.Errorf("%s targets = %v; want the YouTube hosts and the development ingest", env, policy.Targets())
		}
	}

	override, err := rtmps.NewPolicy(rtmps.Target{Host: "localhost", Port: 4443})
	if err != nil {
		t.Fatalf("NewPolicy: %v", err)
	}
	if _, err := DestinationPolicy(appenv.Production, &override); !errors.Is(err, ErrPolicyOverrideInProduction) {
		t.Errorf("DestinationPolicy(production, override) error = %v; want ErrPolicyOverrideInProduction", err)
	}
	got, err := DestinationPolicy(appenv.Test, &override)
	if err != nil {
		t.Fatalf("DestinationPolicy(test, override) error = %v", err)
	}
	if len(got.Targets()) != 1 || got.Targets()[0].Host != "localhost" {
		t.Errorf("override targets = %v; want only the injected target", got.Targets())
	}
	if _, err := DestinationPolicy(appenv.Environment("staging"), nil); err == nil {
		t.Error("DestinationPolicy(unknown environment) = nil error; want an error (no fallback to another environment)")
	}
}

func TestNewAppRefusesAPolicyOverrideInProduction(t *testing.T) {
	override, err := rtmps.NewPolicy(rtmps.Target{Host: "localhost", Port: 4443})
	if err != nil {
		t.Fatalf("NewPolicy: %v", err)
	}
	if _, err := NewApp(testConfig(appenv.Production), Deps{Policy: &override}); !errors.Is(err, ErrPolicyOverrideInProduction) {
		t.Fatalf("NewApp() error = %v; want ErrPolicyOverrideInProduction", err)
	}
}

func TestSessionsContextKeepsAReserveForTheEventFlush(t *testing.T) {
	parent, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	parentDeadline, _ := parent.Deadline()

	child, release := sessionsContext(parent, 2*time.Second)
	defer release()
	childDeadline, ok := child.Deadline()
	if !ok {
		t.Fatal("the sessions context has no deadline")
	}
	if got := parentDeadline.Sub(childDeadline); got != 2*time.Second {
		t.Errorf("reserve = %v; want 2s", got)
	}

	// 猶予が短いときは、残りの時間の半分までに留める（取り込みセッションを閉じる時間が無くならない）
	short, shortCancel := context.WithTimeout(context.Background(), time.Second)
	defer shortCancel()
	shortDeadline, _ := short.Deadline()
	shortChild, shortRelease := sessionsContext(short, 2*time.Second)
	defer shortRelease()
	shortChildDeadline, _ := shortChild.Deadline()
	if got := shortDeadline.Sub(shortChildDeadline); got < 400*time.Millisecond || got > 600*time.Millisecond {
		t.Errorf("reserve of a short grace = %v; want about half of it (500ms)", got)
	}

	// 期限の無い親は、期限の無いまま（親が取り消されたら、子も終わる）
	open, openCancel := context.WithCancel(context.Background())
	defer openCancel()
	openChild, openRelease := sessionsContext(open, 2*time.Second)
	defer openRelease()
	if _, ok := openChild.Deadline(); ok {
		t.Error("a deadline appeared out of nothing")
	}
	openCancel()
	select {
	case <-openChild.Done():
	case <-time.After(time.Second):
		t.Error("the child was not cancelled with its parent")
	}
}

func TestServeAnswersHealthAndStopsWhenTheContextIsDone(t *testing.T) {
	app := newTestApp(t, appenv.Test)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	served := make(chan error, 1)
	go func() { served <- app.Serve(ctx, listener) }()

	base := "http://" + listener.Addr().String()
	var response *http.Response
	deadline := time.Now().Add(5 * time.Second)
	for {
		response, err = http.Get(base + "/health")
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("GET /health: %v", err)
		}
		time.Sleep(5 * time.Millisecond)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != http.StatusOK || !strings.Contains(string(body), `"status":"ok"`) {
		t.Fatalf("GET /health = %d %q; want 200 and status ok", response.StatusCode, body)
	}

	cancel()
	select {
	case err := <-served:
		if err != nil {
			t.Fatalf("Serve() error = %v; want nil after a requested stop", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Serve did not return after the context was cancelled")
	}
	if _, err := http.Get(base + "/health"); err == nil {
		t.Fatal("the server still accepts connections after the stop")
	}
}

func TestServeReturnsAnErrorWhenTheListenerIsBroken(t *testing.T) {
	app := newTestApp(t, appenv.Test)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	_ = listener.Close()
	served := make(chan error, 1)
	go func() { served <- app.Serve(context.Background(), listener) }()
	select {
	case err := <-served:
		if err == nil || errors.Is(err, http.ErrServerClosed) {
			t.Fatalf("Serve() error = %v; want the listener's failure", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Serve did not return although the listener is closed")
	}
}

func TestShutdownCanBeCalledTwiceAndRefusesNewWebSocketsAtOnce(t *testing.T) {
	app := newTestApp(t, appenv.Test)
	server := httptest.NewServer(app.Handler())
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := app.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown() error = %v; want nil", err)
	}
	if err := app.Shutdown(ctx); err != nil {
		t.Fatalf("second Shutdown() error = %v; want nil", err)
	}

	_, response, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http")+"/ws", nil)
	if err == nil {
		t.Fatal("a WebSocket connection was accepted after Shutdown")
	}
	if response == nil || response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("response = %v; want HTTP 503", response)
	}
	// /health は、停止の手順に入っても答える
	health, err := http.Get(server.URL + "/health")
	if err != nil {
		t.Fatalf("GET /health: %v", err)
	}
	health.Body.Close()
	if health.StatusCode != http.StatusOK {
		t.Fatalf("GET /health status = %d; want 200", health.StatusCode)
	}
}

func TestTheAppFormatsWithoutAnySecretOrAddress(t *testing.T) {
	app := newTestApp(t, appenv.Test)
	for _, text := range []string{app.String(), app.GoString()} {
		for _, leaked := range []string{testSecret, "SECRET", testInternalURL, "127.0.0.1"} {
			if strings.Contains(text, leaked) {
				t.Errorf("%q contains %q", text, leaked)
			}
		}
	}
}
