package backend

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// 内部通信クライアント（契約 internal-api.md）の試験。アプリケーションの疑似（httptest）を使う。実際のアプリケーションは呼ばない。

func TestNewClientChecksTheConfig(t *testing.T) {
	cases := []struct {
		name    string
		url     string
		secret  Secret
		wantErr bool
	}{
		{"開発環境の内部通信の口", "http://backend:3101", Secret(canarySecret), false},
		{"末尾のスラッシュ", "http://127.0.0.1:3101/", Secret(canarySecret), false},
		{"https", "https://backend.internal", Secret(canarySecret), false},
		{"空の URL", "", Secret(canarySecret), true},
		{"スキームなし", "backend:3101", Secret(canarySecret), true},
		{"ftp", "ftp://backend:3101", Secret(canarySecret), true},
		{"ホストなし", "http://", Secret(canarySecret), true},
		{"ユーザー情報つき", "http://user:pass@backend:3101", Secret(canarySecret), true},
		{"クエリつき", "http://backend:3101/?a=1", Secret(canarySecret), true},
		{"フラグメントつき", "http://backend:3101/#x", Secret(canarySecret), true},
		{"パスつき", "http://backend:3101/internal", Secret(canarySecret), true},
		{"秘密値が空", "http://backend:3101", Secret(""), true},
		{"秘密値に改行", "http://backend:3101", Secret("abc\r\nX-Evil: 1"), true},
		{"秘密値に空白", "http://backend:3101", Secret("abc def"), true},
		{"秘密値に非 ASCII", "http://backend:3101", Secret("abcé"), true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := NewClient(Config{BaseURL: c.url, Secret: c.secret})
			if !c.wantErr {
				if err != nil {
					t.Fatalf("NewClient: %v", err)
				}
				return
			}
			if !isError(err, ErrInvalidConfig) {
				t.Fatalf("error = %v, want ErrInvalidConfig", err)
			}
			if strings.Contains(err.Error(), "CANARY") || strings.Contains(err.Error(), "X-Evil") {
				t.Fatalf("the error leaks the secret: %q", err.Error())
			}
		})
	}
}

func TestNewClientRejectsNegativeTimeouts(t *testing.T) {
	_, err := NewClient(Config{BaseURL: "http://backend:3101", Secret: Secret(canarySecret), Timeouts: Timeouts{Heartbeat: -time.Second}})
	if !isError(err, ErrInvalidConfig) {
		t.Fatalf("error = %v, want ErrInvalidConfig", err)
	}
}

func TestDefaultTimeoutsFollowTheIssue(t *testing.T) {
	// 心拍・事象 5 秒、準備 90 秒（issue #20）。照合は契約に定めが無く、接続通知の期限と同じ 10 秒（解釈）
	got := DefaultTimeouts()
	want := Timeouts{Verify: 10 * time.Second, Provision: 90 * time.Second, Heartbeat: 5 * time.Second, Event: 5 * time.Second}
	if got != want {
		t.Fatalf("DefaultTimeouts = %+v, want %+v", got, want)
	}
}

// ---- 照合 ----

func TestVerifySendsTheContractRequestAndParsesTheResult(t *testing.T) {
	app := newFakeApp(t, reply(200, sampleVerifyBody))
	client := newTestClient(t, app)

	result, err := client.Verify(context.Background(), Ticket("dummy-ticket-0123456789abcdefghijklmnopqrstuvwxyz"))
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	want := VerifyResult{
		BroadcastID: sampleBroadcastID,
		State:       contract.BroadcastStateReserved,
		Epoch:       1,
		AccountKey:  sampleAccountKey,
		Profile:     "",
		Limits:      Limits{TimeLimitSeconds: 3600},
	}
	if result != want {
		t.Fatalf("result = %+v, want %+v", result, want)
	}

	request := app.only(t)
	if request.Method != http.MethodPost || request.Path != "/internal/v1/verify" {
		t.Fatalf("request = %s %s", request.Method, request.Path)
	}
	if got := request.Header.Get("X-Relay-Secret"); got != canarySecret {
		t.Fatalf("X-Relay-Secret = %q", got)
	}
	if got := request.Header.Get("Content-Type"); got != "application/json; charset=utf-8" {
		t.Fatalf("Content-Type = %q", got)
	}
	assertJSONEqual(t, request.Body, `{"ticket":"dummy-ticket-0123456789abcdefghijklmnopqrstuvwxyz"}`)
}

func TestVerifyParsesAResumedBroadcast(t *testing.T) {
	body := `{"broadcast_id":"` + sampleBroadcastID + `","state":"interrupted","epoch":7,"account_key":"` + sampleAccountKey +
		`","profile":"480p","limits":{"time_limit_seconds":1800}}`
	app := newFakeApp(t, reply(200, body))
	result, err := newTestClient(t, app).Verify(context.Background(), Ticket("t"))
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if result.State != contract.BroadcastStateInterrupted || result.Epoch != 7 || result.Profile != contract.Profile480p || result.Limits.TimeLimitSeconds != 1800 {
		t.Fatalf("result = %+v", result)
	}
}

func TestVerifyAcceptsEveryAttachableState(t *testing.T) {
	for _, state := range []string{"reserved", "awaiting_media", "confirming", "live", "interrupted"} {
		t.Run(state, func(t *testing.T) {
			body := strings.Replace(sampleVerifyBody, `"state":"reserved"`, `"state":"`+state+`"`, 1)
			app := newFakeApp(t, reply(200, body))
			if _, err := newTestClient(t, app).Verify(context.Background(), Ticket("t")); err != nil {
				t.Fatalf("Verify: %v", err)
			}
		})
	}
}

func TestVerifyRejectsAMalformedResult(t *testing.T) {
	good := sampleVerifyBody
	cases := []struct {
		name string
		body string
	}{
		{"JSON ではない", "not json"},
		{"空の本文", ""},
		{"配列", "[]"},
		{"終了済みの状態", strings.Replace(good, `"state":"reserved"`, `"state":"ended"`, 1)},
		{"未知の状態", strings.Replace(good, `"state":"reserved"`, `"state":"weird"`, 1)},
		{"状態が無い", strings.Replace(good, `"state":"reserved",`, "", 1)},
		{"世代が 0", strings.Replace(good, `"epoch":1`, `"epoch":0`, 1)},
		{"世代が負", strings.Replace(good, `"epoch":1`, `"epoch":-3`, 1)},
		{"世代が小数", strings.Replace(good, `"epoch":1`, `"epoch":1.5`, 1)},
		{"配信の識別子が UUID ではない", strings.Replace(good, sampleBroadcastID, "../../etc", 1)},
		{"配信の識別子が空", strings.Replace(good, sampleBroadcastID, "", 1)},
		{"アカウントの値が短い", strings.Replace(good, sampleAccountKey, "abcd", 1)},
		{"アカウントの値が大文字", strings.Replace(good, sampleAccountKey, strings.ToUpper(sampleAccountKey), 1)},
		{"アカウントの値が 16 進数ではない", strings.Replace(good, sampleAccountKey, strings.Repeat("z", 64), 1)},
		{"未知のプロファイル", strings.Replace(good, `"profile":null`, `"profile":"1080p"`, 1)},
		{"時間上限が無い", strings.Replace(good, `"limits":{"time_limit_seconds":3600}`, `"limits":{}`, 1)},
		{"時間上限が 0", strings.Replace(good, `"time_limit_seconds":3600`, `"time_limit_seconds":0`, 1)},
		{"時間上限が文字列", strings.Replace(good, `"time_limit_seconds":3600`, `"time_limit_seconds":"3600"`, 1)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			app := newFakeApp(t, reply(200, c.body))
			_, err := newTestClient(t, app).Verify(context.Background(), Ticket("t"))
			if !isError(err, ErrInvalidResponse) {
				t.Fatalf("error = %v, want ErrInvalidResponse", err)
			}
		})
	}
}

// 失敗の型（契約 internal-api.md の 2 章）。errors.Is で判定でき、*APIError に、呼び出し・HTTP ステータス・符号が入る。
func TestCallFailuresAreTyped(t *testing.T) {
	cases := []struct {
		name       string
		call       string // verify・provision・heartbeat・event
		status     int
		body       string
		want       error
		wantCode   string
		wantReason contract.EndReason
	}{
		{"照合: 無効なチケット", "verify", 404, errorBody("ticket_invalid", ""), ErrTicketInvalid, "ticket_invalid", ""},
		{"照合: 付けられない状態", "verify", 409, errorBody("broadcast_not_attachable", ""), ErrBroadcastNotAttachable, "broadcast_not_attachable", ""},
		{"照合: 認証の失敗", "verify", 401, errorBody("unauthorized", ""), ErrUnauthorized, "unauthorized", ""},
		{"照合: 入力の不備", "verify", 422, errorBody("invalid_input", `{"fields":["ticket"]}`), ErrInvalidInput, "invalid_input", ""},
		{"準備: 古い世代", "provision", 409, errorBody("stale_epoch", ""), ErrStaleEpoch, "stale_epoch", ""},
		{"準備: 終了済み", "provision", 409, errorBody("broadcast_ended", `{"end_reason":"start_timeout"}`), ErrBroadcastEnded, "broadcast_ended", contract.EndReasonStartTimeout},
		{"準備: 先行配信が未清算", "provision", 422, errorBody("prior_unsettled", `{"end_reason":"prior_unsettled"}`), ErrPriorUnsettled, "prior_unsettled", contract.EndReasonPriorUnsettled},
		{"準備: 準備の失敗", "provision", 502, errorBody("prepare_failed", `{"end_reason":"prepare_failed"}`), ErrPrepareFailed, "prepare_failed", contract.EndReasonPrepareFailed},
		{"準備: 認可の失効", "provision", 409, errorBody("authorization_revoked", `{"end_reason":"authorization_revoked"}`), ErrAuthorizationRevoked, "authorization_revoked", contract.EndReasonAuthorizationRevoked},
		{"準備: ライブ未有効", "provision", 409, errorBody("live_not_enabled", `{"end_reason":"prepare_failed"}`), ErrLiveNotEnabled, "live_not_enabled", contract.EndReasonPrepareFailed},
		{"準備: 配信が無い", "provision", 404, errorBody("not_found", ""), ErrNotFound, "not_found", ""},
		{"心拍: 配信が無い", "heartbeat", 404, errorBody("not_found", ""), ErrNotFound, "not_found", ""},
		{"心拍: 入力の不備", "heartbeat", 422, errorBody("invalid_input", ""), ErrInvalidInput, "invalid_input", ""},
		{"事象: 配信が無い", "event", 404, errorBody("not_found", ""), ErrNotFound, "not_found", ""},
		{"事象: 認証の失敗", "event", 401, errorBody("unauthorized", ""), ErrUnauthorized, "unauthorized", ""},
		// 到達できない・一時的な失敗（5xx）
		{"照合: 500", "verify", 500, "", ErrUnavailable, "", ""},
		{"照合: 503（JSON ではない本文）", "verify", 503, "<html>maintenance</html>", ErrUnavailable, "", ""},
		{"準備: 504", "provision", 504, "", ErrUnavailable, "", ""},
		{"準備: 502 だが符号が未知（プロキシ）", "provision", 502, errorBody("bad_gateway", ""), ErrUnavailable, "", ""},
		{"心拍: 500 に未知の符号", "heartbeat", 500, errorBody("internal", ""), ErrUnavailable, "", ""},
		{"事象: 500", "event", 500, "", ErrUnavailable, "", ""},
		// 契約に無い組（ステータスと符号が合わない）は、想定外
		{"照合: 想定外の 400", "verify", 400, errorBody("ticket_invalid", ""), ErrUnexpectedStatus, "", ""},
		{"照合: 符号とステータスが合わない", "verify", 409, errorBody("ticket_invalid", ""), ErrUnexpectedStatus, "", ""},
		{"心拍: 想定外の 403", "heartbeat", 403, "", ErrUnexpectedStatus, "", ""},
		{"事象: 想定外の 429", "event", 429, "", ErrUnexpectedStatus, "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			app := newFakeApp(t, reply(c.status, c.body))
			client := newTestClient(t, app)
			err := invoke(client, c.call)
			if err == nil {
				t.Fatal("the call succeeded")
			}
			if !isError(err, c.want) {
				t.Fatalf("error = %v, want %v", err, c.want)
			}
			// 5xx 以外は「到達できない」ではない（再送の対象にしない）
			if c.want != ErrUnavailable && isError(err, ErrUnavailable) {
				t.Fatalf("error %v must not be ErrUnavailable", err)
			}
			var apiErr *APIError
			if !errors.As(err, &apiErr) {
				t.Fatalf("error %v is not an *APIError", err)
			}
			if apiErr.Status != c.status || apiErr.Code != c.wantCode || apiErr.EndReason != c.wantReason {
				t.Fatalf("APIError = %+v, want status %d code %q end_reason %q", apiErr, c.status, c.wantCode, c.wantReason)
			}
			if string(apiErr.Call) != c.call {
				t.Fatalf("APIError.Call = %q, want %q", apiErr.Call, c.call)
			}
		})
	}
}

// invoke は、call の名前の呼び出しを、標準の引数で行う。
func invoke(client *Client, call string) error {
	ctx := context.Background()
	switch call {
	case "verify":
		_, err := client.Verify(ctx, Ticket("t"))
		return err
	case "provision":
		_, err := client.Provision(ctx, sampleBroadcastID, 1, contract.Profile720p)
		return err
	case "heartbeat":
		_, err := client.Heartbeat(ctx, sampleBroadcastID, HeartbeatRequest{Epoch: 1, Seq: 1})
		return err
	case "event":
		return client.Event(ctx, sampleBroadcastID, EventRequest{Epoch: 1, Kind: contract.RelayEventKindSessionEnded, At: time.Unix(0, 0)})
	}
	panic("unknown call " + call)
}

func TestErrorTextIsFixedVocabularyAndDoesNotEchoTheBody(t *testing.T) {
	hostile := errorBody("ticket_invalid", `{"end_reason":"`+canarySecret+`"}`) // 符号は既知。詳細に秘密値を載せた敵対的な応答
	app := newFakeApp(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Echo", canarySecret+canaryTicket)
		w.WriteHeader(404)
		_, _ = io.WriteString(w, hostile)
	})
	err := invoke(newTestClient(t, app), "verify")
	if !isError(err, ErrTicketInvalid) {
		t.Fatalf("error = %v", err)
	}
	for _, text := range []string{err.Error(), fmt.Sprintf("%v", err), fmt.Sprintf("%+v", err), fmt.Sprintf("%#v", err)} {
		if strings.Contains(text, "CANARY") {
			t.Fatalf("the error echoes the response: %q", text)
		}
	}
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.EndReason != "" {
		t.Fatalf("an unknown end_reason must be dropped: %+v", apiErr)
	}
}

func TestUnknownErrorCodeIsNotEchoed(t *testing.T) {
	app := newFakeApp(t, reply(502, errorBody("dummy-code-CANARY-9999", "")))
	err := invoke(newTestClient(t, app), "provision")
	if !isError(err, ErrUnavailable) {
		t.Fatalf("error = %v", err)
	}
	if strings.Contains(err.Error(), "CANARY") {
		t.Fatalf("the error echoes the code: %q", err.Error())
	}
}

func TestTransportFailureIsUnavailable(t *testing.T) {
	// 閉じたポートへ接続する（接続の拒否）
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	address := listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	client, err := NewClient(Config{BaseURL: "http://" + address, Secret: Secret(canarySecret)})
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	for _, call := range []string{"verify", "provision", "heartbeat", "event"} {
		t.Run(call, func(t *testing.T) {
			err := invoke(client, call)
			if !isError(err, ErrUnavailable) {
				t.Fatalf("error = %v, want ErrUnavailable", err)
			}
			if strings.Contains(err.Error(), "CANARY") {
				t.Fatalf("the error leaks a secret: %q", err.Error())
			}
		})
	}
}

func TestTimeoutIsUnavailableAndKeepsTheDeadlineCause(t *testing.T) {
	release := make(chan struct{})
	app := newFakeApp(t, func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
		w.WriteHeader(204)
	})
	t.Cleanup(func() { close(release) })
	client := newTestClient(t, app, func(c *Config) {
		c.Timeouts = Timeouts{Verify: 30 * time.Millisecond, Provision: 30 * time.Millisecond, Heartbeat: 30 * time.Millisecond, Event: 30 * time.Millisecond}
	})
	for _, call := range []string{"verify", "provision", "heartbeat", "event"} {
		t.Run(call, func(t *testing.T) {
			err := invoke(client, call)
			if !isError(err, ErrUnavailable) || !isError(err, context.DeadlineExceeded) {
				t.Fatalf("error = %v, want ErrUnavailable and DeadlineExceeded", err)
			}
		})
	}
}

func TestCallerCancellationIsNotUnavailable(t *testing.T) {
	release := make(chan struct{})
	app := newFakeApp(t, func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	})
	t.Cleanup(func() { close(release) })
	client := newTestClient(t, app)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := client.Verify(ctx, Ticket("t"))
		done <- err
	}()
	cancel()
	err := <-done
	if !isError(err, context.Canceled) {
		t.Fatalf("error = %v, want context.Canceled", err)
	}
	if isError(err, ErrUnavailable) {
		t.Fatalf("a caller cancellation must not be reported as ErrUnavailable: %v", err)
	}
}

// 各呼び出しの期限（心拍・事象 5 秒、準備 90 秒、照合 10 秒）が、要求の context に設定される。
type deadlineRecorder struct {
	deadlines map[string]time.Duration
}

func (d *deadlineRecorder) RoundTrip(req *http.Request) (*http.Response, error) {
	deadline, ok := req.Context().Deadline()
	if !ok {
		d.deadlines[req.URL.Path] = -1
	} else {
		d.deadlines[req.URL.Path] = time.Until(deadline)
	}
	status := 204
	body := ""
	switch {
	case strings.HasSuffix(req.URL.Path, "/verify"):
		status, body = 200, sampleVerifyBody
	case strings.HasSuffix(req.URL.Path, "/provision"):
		status, body = 200, sampleProvisionBody
	case strings.HasSuffix(req.URL.Path, "/heartbeat"):
		status, body = 200, sampleHeartbeatBody
	}
	return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body)), Request: req}, nil
}

func TestEachCallHasItsOwnDeadline(t *testing.T) {
	recorder := &deadlineRecorder{deadlines: map[string]time.Duration{}}
	client, err := NewClient(Config{BaseURL: "http://backend:3101", Secret: Secret(canarySecret), HTTPClient: &http.Client{Transport: recorder}})
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	for _, call := range []string{"verify", "provision", "heartbeat", "event"} {
		if err := invoke(client, call); err != nil {
			t.Fatalf("%s: %v", call, err)
		}
	}
	want := map[string]time.Duration{
		"/internal/v1/verify": 10 * time.Second,
		"/internal/v1/broadcasts/" + sampleBroadcastID + "/provision": 90 * time.Second,
		"/internal/v1/broadcasts/" + sampleBroadcastID + "/heartbeat": 5 * time.Second,
		"/internal/v1/broadcasts/" + sampleBroadcastID + "/events":    5 * time.Second,
	}
	for path, limit := range want {
		got, ok := recorder.deadlines[path]
		if !ok {
			t.Errorf("no request for %s", path)
			continue
		}
		// 経過は数ミリ秒。上限を超えず、上限に近いこと
		if got > limit || got < limit-2*time.Second {
			t.Errorf("%s: remaining deadline = %v, want just under %v", path, got, limit)
		}
	}
}

// リダイレクトを追わない（内部通信の口から別の場所へ、秘密値つきの要求を転送しない）。
func TestRedirectsAreNotFollowed(t *testing.T) {
	other := newFakeApp(t, reply(200, sampleVerifyBody))
	app := newFakeApp(t, func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.server.URL+"/internal/v1/verify", http.StatusTemporaryRedirect)
	})
	client := newTestClient(t, app)
	_, err := client.Verify(context.Background(), Ticket("t"))
	if !isError(err, ErrUnexpectedStatus) {
		t.Fatalf("error = %v, want ErrUnexpectedStatus", err)
	}
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Status != http.StatusTemporaryRedirect {
		t.Fatalf("error = %v", err)
	}
	if got := len(other.recorded()); got != 0 {
		t.Fatalf("the redirect target received %d requests (the secret was forwarded)", got)
	}
}

func TestRedirectsAreNotFollowedEvenWithACustomHTTPClient(t *testing.T) {
	other := newFakeApp(t, reply(200, sampleVerifyBody))
	app := newFakeApp(t, func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.server.URL+"/x", http.StatusFound)
	})
	followAll := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return nil }}
	client := newTestClient(t, app, func(c *Config) { c.HTTPClient = followAll })
	if _, err := client.Verify(context.Background(), Ticket("t")); !isError(err, ErrUnexpectedStatus) {
		t.Fatalf("error = %v, want ErrUnexpectedStatus", err)
	}
	if got := len(other.recorded()); got != 0 {
		t.Fatalf("the redirect target received %d requests", got)
	}
}

func TestClientDoesNotUseEnvironmentProxies(t *testing.T) {
	client, err := NewClient(Config{BaseURL: "http://backend:3101", Secret: Secret(canarySecret)})
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	transport, ok := client.httpClient.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("transport = %T, want *http.Transport", client.httpClient.Transport)
	}
	if transport.Proxy != nil {
		t.Fatal("the internal client must not use proxies from the environment")
	}
}

func TestOversizedResponseIsInvalid(t *testing.T) {
	huge := strings.Repeat("a", maxResponseBytes+10)
	app := newFakeApp(t, reply(200, `{"x":"`+huge+`"}`))
	if _, err := newTestClient(t, app).Verify(context.Background(), Ticket("t")); !isError(err, ErrInvalidResponse) {
		t.Fatalf("error = %v, want ErrInvalidResponse", err)
	}
}

// 約束した長さの途中で切れた応答（接続の切断・アプリケーションの異常）。読み取りの失敗を捨てて、欠けた本文を解釈しない。
// 応答は届かなかったものとして ErrUnavailable（再送の対象）にする。
func truncatedBody(status int) func(w http.ResponseWriter, r *http.Request) {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Content-Length", "1000")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, `{"broadcast_id":"`)
		w.(http.Flusher).Flush()
		panic(http.ErrAbortHandler) // 接続を、本文の途中で切る（サーバーは、記録しない）
	}
}

func TestAResponseBodyThatCannotBeReadToTheEndIsUnavailable(t *testing.T) {
	cases := []struct {
		name   string
		status int
		call   string
	}{
		{"照合の成功の応答", 200, "verify"},
		{"準備の成功の応答", 200, "provision"},
		{"心拍の成功の応答", 200, "heartbeat"},
		{"事象の成功の応答", 200, "event"},
		{"照合の 404", 404, "verify"},
		{"照合の 409", 409, "verify"},
		{"準備の 409", 409, "provision"},
		{"照合の 500", 500, "verify"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			app := newFakeApp(t, truncatedBody(c.status))
			err := invoke(newTestClient(t, app), c.call)
			if !isError(err, ErrUnavailable) {
				t.Fatalf("error = %v, want ErrUnavailable", err)
			}
			if isError(err, ErrInvalidResponse) {
				t.Fatalf("the truncated body was interpreted as an invalid response: %v", err)
			}
			if strings.Contains(err.Error(), "CANARY") {
				t.Fatalf("the error leaks a secret: %q", err.Error())
			}
		})
	}
}

// bodyReadSignal は、応答の本文の読み取りが始まったことを知らせる（試験が、取り消しを、応答の見出しを受けたあとに行うため）。
type bodyReadSignal struct {
	base    http.RoundTripper
	started chan struct{}
	once    sync.Once
}

func (b *bodyReadSignal) RoundTrip(req *http.Request) (*http.Response, error) {
	response, err := b.base.RoundTrip(req)
	if err != nil {
		return nil, err
	}
	response.Body = &signalingBody{ReadCloser: response.Body, signal: func() { b.once.Do(func() { close(b.started) }) }}
	return response, nil
}

type signalingBody struct {
	io.ReadCloser
	signal func()
}

func (b *signalingBody) Read(p []byte) (int, error) {
	b.signal()
	return b.ReadCloser.Read(p)
}

// 本文を読んでいる最中に、呼び出し側が取り消した場合は、ErrUnavailable にしない（再送の対象にしない）。
func TestCancellationWhileReadingTheBodyIsNotUnavailable(t *testing.T) {
	release := make(chan struct{})
	app := newFakeApp(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Content-Length", "1000")
		w.WriteHeader(200)
		_, _ = io.WriteString(w, `{"broadcast_id":"`)
		w.(http.Flusher).Flush()
		select { // 残りの本文は、送らない
		case <-release:
		case <-r.Context().Done():
		}
	})
	t.Cleanup(func() { close(release) })
	signal := &bodyReadSignal{base: &http.Transport{}, started: make(chan struct{})}
	client := newTestClient(t, app, func(c *Config) { c.HTTPClient = &http.Client{Transport: signal} })
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		_, err := client.Verify(ctx, Ticket("t"))
		result <- err
	}()
	select {
	case <-signal.started: // 応答の見出しを受け、本文を読み始めた
	case <-time.After(5 * time.Second):
		t.Fatal("the client did not start reading the response body")
	}
	cancel()
	select {
	case err := <-result:
		if !isError(err, context.Canceled) || isError(err, ErrUnavailable) {
			t.Fatalf("error = %v, want context.Canceled and not ErrUnavailable", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the call did not return after the cancellation")
	}
}

// ---- 準備 ----

func TestProvisionSendsTheContractRequestAndParsesTheResult(t *testing.T) {
	app := newFakeApp(t, reply(200, sampleProvisionBody))
	client := newTestClient(t, app)
	result, err := client.Provision(context.Background(), sampleBroadcastID, 1, contract.Profile720p)
	if err != nil {
		t.Fatalf("Provision: %v", err)
	}
	if string(result.Ingest.URL) != "rtmps://a.rtmps.youtube.com:443/live2" || string(result.Ingest.StreamKey) != "dummy-stream-key" {
		t.Fatalf("ingest was not parsed")
	}
	if result.WatchURL != "https://www.youtube.com/watch?v=dummyVideoId" || result.State != contract.BroadcastStateAwaitingMedia {
		t.Fatalf("result = %+v", result)
	}
	request := app.only(t)
	if request.Method != http.MethodPost || request.Path != "/internal/v1/broadcasts/"+sampleBroadcastID+"/provision" {
		t.Fatalf("request = %s %s", request.Method, request.Path)
	}
	if request.Header.Get("X-Relay-Secret") != canarySecret {
		t.Fatal("X-Relay-Secret is missing")
	}
	assertJSONEqual(t, request.Body, `{"epoch":1,"profile":"720p"}`)

	// 秘密値（配信キー・取り込み先）は、書式化しても出ない
	text := fmt.Sprintf("%v %+v %#v", result, result, result)
	if strings.Contains(text, "dummy-stream-key") || strings.Contains(text, "rtmps.youtube.com") {
		t.Fatalf("the result leaks the ingest: %s", text)
	}
}

func TestProvisionChecksItsArgumentsBeforeSending(t *testing.T) {
	cases := []struct {
		name      string
		id        string
		epoch     int
		profile   contract.Profile
		wantError error
	}{
		{"識別子が UUID ではない", "abc", 1, contract.Profile720p, ErrInvalidArgument},
		{"識別子にパスの区切り", "../../admin", 1, contract.Profile720p, ErrInvalidArgument},
		{"識別子が空", "", 1, contract.Profile720p, ErrInvalidArgument},
		{"世代が 0", sampleBroadcastID, 0, contract.Profile720p, ErrInvalidArgument},
		{"プロファイルが不正", sampleBroadcastID, 1, contract.Profile("4k"), ErrInvalidArgument},
		{"プロファイルが空", sampleBroadcastID, 1, "", ErrInvalidArgument},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			app := newFakeApp(t, reply(200, sampleProvisionBody))
			_, err := newTestClient(t, app).Provision(context.Background(), c.id, c.epoch, c.profile)
			if !isError(err, c.wantError) {
				t.Fatalf("error = %v, want %v", err, c.wantError)
			}
			if got := len(app.recorded()); got != 0 {
				t.Fatalf("a request was sent (%d)", got)
			}
		})
	}
}

func TestProvisionRejectsAMalformedResult(t *testing.T) {
	good := sampleProvisionBody
	cases := []struct {
		name string
		body string
	}{
		{"JSON ではない", "x"},
		{"取り込み先が無い", `{"watch_url":"https://www.youtube.com/watch?v=a","state":"awaiting_media"}`},
		{"取り込み先の URL が空", strings.Replace(good, `"url":"rtmps://a.rtmps.youtube.com:443/live2"`, `"url":""`, 1)},
		{"配信キーが空", strings.Replace(good, `"stream_key":"dummy-stream-key"`, `"stream_key":""`, 1)},
		{"配信キーが数値", strings.Replace(good, `"stream_key":"dummy-stream-key"`, `"stream_key":12`, 1)},
		{"視聴 URL が空", strings.Replace(good, `"watch_url":"https://www.youtube.com/watch?v=dummyVideoId"`, `"watch_url":""`, 1)},
		{"視聴 URL が http", strings.Replace(good, "https://www.youtube.com", "http://www.youtube.com", 1)},
		{"視聴 URL が javascript", strings.Replace(good, "https://www.youtube.com/watch?v=dummyVideoId", "javascript:alert(1)", 1)},
		{"視聴 URL にホストが無い", strings.Replace(good, "https://www.youtube.com/watch?v=dummyVideoId", "https:///watch", 1)},
		{"状態が終了", strings.Replace(good, `"state":"awaiting_media"`, `"state":"ended"`, 1)},
		{"状態が未知", strings.Replace(good, `"state":"awaiting_media"`, `"state":"x"`, 1)},
		{"取り込み先が長すぎる", strings.Replace(good, `rtmps://a.rtmps.youtube.com:443/live2`, `rtmps://a.rtmps.youtube.com:443/`+strings.Repeat("a", 5000), 1)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			app := newFakeApp(t, reply(200, c.body))
			_, err := newTestClient(t, app).Provision(context.Background(), sampleBroadcastID, 1, contract.Profile720p)
			if !isError(err, ErrInvalidResponse) {
				t.Fatalf("error = %v, want ErrInvalidResponse", err)
			}
			// 秘密値を含む応答でも、エラーには出さない
			if strings.Contains(err.Error(), "dummy-stream-key") {
				t.Fatalf("the error leaks the stream key: %q", err.Error())
			}
		})
	}
}

func TestProvisionAcceptsTheCurrentStateOfAResumedBroadcast(t *testing.T) {
	for _, state := range []string{"awaiting_media", "confirming", "live", "interrupted", "reserved"} {
		t.Run(state, func(t *testing.T) {
			body := strings.Replace(sampleProvisionBody, `"state":"awaiting_media"`, `"state":"`+state+`"`, 1)
			app := newFakeApp(t, reply(200, body))
			result, err := newTestClient(t, app).Provision(context.Background(), sampleBroadcastID, 2, contract.Profile480p)
			if err != nil {
				t.Fatalf("Provision: %v", err)
			}
			if string(result.State) != state {
				t.Fatalf("state = %q", result.State)
			}
		})
	}
}

// ---- 心拍 ----

func TestHeartbeatSendsTheContractRequest(t *testing.T) {
	app := newFakeApp(t, reply(200, sampleHeartbeatBody))
	client := newTestClient(t, app)
	request := HeartbeatRequest{
		Epoch: 3, Seq: 42, Publishing: true, OutKbps: 4620, SentBytesDelta: 1155000,
		Browser: &BrowserReport{BacklogMs: 120, DroppedVideoFrames: 0, TargetKbps: 4500, State: contract.StudioStateLive},
	}
	if _, err := client.Heartbeat(context.Background(), sampleBroadcastID, request); err != nil {
		t.Fatalf("Heartbeat: %v", err)
	}
	recorded := app.only(t)
	if recorded.Path != "/internal/v1/broadcasts/"+sampleBroadcastID+"/heartbeat" {
		t.Fatalf("path = %s", recorded.Path)
	}
	// 出来事が無いときも、events は null ではなく空の配列（契約の例）
	assertJSONEqual(t, recorded.Body, `{"epoch":3,"seq":42,"publishing":true,"out_kbps":4620,"sent_bytes_delta":1155000,"browser":{"backlog_ms":120,"dropped_video_frames":0,"target_kbps":4500,"state":"live","events":[]}}`)
}

func TestHeartbeatSendsBrowserEventsAndNullBrowser(t *testing.T) {
	app := newFakeApp(t, reply(200, sampleHeartbeatBody))
	client := newTestClient(t, app)

	if _, err := client.Heartbeat(context.Background(), sampleBroadcastID, HeartbeatRequest{Epoch: 1, Seq: 1}); err != nil {
		t.Fatalf("Heartbeat: %v", err)
	}
	assertJSONEqual(t, app.recorded()[0].Body, `{"epoch":1,"seq":1,"publishing":false,"out_kbps":0,"sent_bytes_delta":0,"browser":null}`)

	report := &BrowserReport{
		BacklogMs: 1800, DroppedVideoFrames: 12, TargetKbps: 3000, State: contract.StudioStateDegraded,
		Events: []BrowserEvent{
			{Kind: contract.BrowserEventKindBitrateDown, Detail: []byte(`{"from_kbps":3300,"to_kbps":3000}`)},
			{Kind: contract.BrowserEventKindVideoDropped, Detail: []byte(`{"frames":12}`)},
			{Kind: contract.BrowserEventKindDegradedStarted},
		},
	}
	if _, err := client.Heartbeat(context.Background(), sampleBroadcastID, HeartbeatRequest{Epoch: 2, Seq: 2, Browser: report}); err != nil {
		t.Fatalf("Heartbeat: %v", err)
	}
	assertJSONEqual(t, app.recorded()[1].Body, `{"epoch":2,"seq":2,"publishing":false,"out_kbps":0,"sent_bytes_delta":0,"browser":{"backlog_ms":1800,"dropped_video_frames":12,"target_kbps":3000,"state":"degraded","events":[`+
		`{"kind":"bitrate_down","detail":{"from_kbps":3300,"to_kbps":3000}},{"kind":"video_dropped","detail":{"frames":12}},{"kind":"degraded_started"}]}}`)
}

// 世代が決まる前（0）の心拍・連番が 0 以下の心拍は、アプリケーションに古い世代と受け取られて、取り込みセッションを止めかねない。
// 要求を送らずに、ErrInvalidArgument（準備・事象と同じ）。
func TestHeartbeatChecksItsArgumentsBeforeSending(t *testing.T) {
	cases := []struct {
		name    string
		id      string
		request HeartbeatRequest
	}{
		{"識別子が UUID ではない", "abc", HeartbeatRequest{Epoch: 1, Seq: 1}},
		{"識別子にパスの区切り", "../../admin", HeartbeatRequest{Epoch: 1, Seq: 1}},
		{"世代が 0（世代が決まる前）", sampleBroadcastID, HeartbeatRequest{Epoch: 0, Seq: 1}},
		{"世代が負", sampleBroadcastID, HeartbeatRequest{Epoch: -1, Seq: 1}},
		{"連番が 0", sampleBroadcastID, HeartbeatRequest{Epoch: 1, Seq: 0}},
		{"連番が負", sampleBroadcastID, HeartbeatRequest{Epoch: 1, Seq: -1}},
		{"世代も連番も 0", sampleBroadcastID, HeartbeatRequest{}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			app := newFakeApp(t, reply(200, sampleHeartbeatBody))
			_, err := newTestClient(t, app).Heartbeat(context.Background(), c.id, c.request)
			if !isError(err, ErrInvalidArgument) {
				t.Fatalf("error = %v, want ErrInvalidArgument", err)
			}
			if got := len(app.recorded()); got != 0 {
				t.Fatalf("a request was sent (%d)", got)
			}
		})
	}
}

func TestHeartbeatAcceptsTheSmallestValidEpochAndSeq(t *testing.T) {
	app := newFakeApp(t, reply(200, sampleHeartbeatBody))
	if _, err := newTestClient(t, app).Heartbeat(context.Background(), sampleBroadcastID, HeartbeatRequest{Epoch: 1, Seq: 1}); err != nil {
		t.Fatalf("Heartbeat: %v", err)
	}
	if got := len(app.recorded()); got != 1 {
		t.Fatalf("requests = %d, want 1", got)
	}
}

func TestHeartbeatParsesTheResponse(t *testing.T) {
	cases := []struct {
		name string
		body string
		want HeartbeatResponse
	}{
		{
			"継続と状態の通知",
			sampleHeartbeatBody,
			HeartbeatResponse{Command: CommandContinue, Notices: []Notice{{State: contract.BroadcastStateLive, WatchURL: "https://www.youtube.com/watch?v=dummyVideoId"}}},
		},
		{
			"通知が無い（省略）",
			`{"command":"continue"}`,
			HeartbeatResponse{Command: CommandContinue},
		},
		{
			"世代が古い",
			`{"command":"stop","reason":"stale_epoch"}`,
			HeartbeatResponse{Command: CommandStop, Reason: ReasonStaleEpoch},
		},
		{
			"終了の理由つきの停止と、終了の通知",
			`{"command":"stop","end_reason":"time_limit","notices":[{"kind":"status","state":"ended","watch_url":null,"warning":null,"time_limit_notice_seconds":null,"end_reason":"time_limit"}]}`,
			HeartbeatResponse{Command: CommandStop, EndReason: contract.EndReasonTimeLimit, Notices: []Notice{{State: contract.BroadcastStateEnded, EndReason: contract.EndReasonTimeLimit}}},
		},
		{
			"警告と時間上限の予告",
			`{"command":"continue","notices":[{"kind":"status","state":"live","watch_url":null,"warning":"youtube_stream_unhealthy","time_limit_notice_seconds":300,"end_reason":null}]}`,
			HeartbeatResponse{Command: CommandContinue, Notices: []Notice{{State: contract.BroadcastStateLive, Warning: "youtube_stream_unhealthy", TimeLimitNoticeSeconds: 300}}},
		},
		{
			"未知の種類の通知は無視する（前方互換）",
			`{"command":"continue","notices":[{"kind":"banner","text":"x"},{"kind":"status","state":"live","watch_url":null,"warning":null,"time_limit_notice_seconds":null,"end_reason":null}]}`,
			HeartbeatResponse{Command: CommandContinue, Notices: []Notice{{State: contract.BroadcastStateLive}}},
		},
		{
			"未知のキーは無視する",
			`{"command":"continue","x_extra":1,"notices":[]}`,
			HeartbeatResponse{Command: CommandContinue},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			app := newFakeApp(t, reply(200, c.body))
			got, err := newTestClient(t, app).Heartbeat(context.Background(), sampleBroadcastID, HeartbeatRequest{Epoch: 1, Seq: 1})
			if err != nil {
				t.Fatalf("Heartbeat: %v", err)
			}
			if !heartbeatResponsesEqual(got, c.want) {
				t.Fatalf("response = %+v, want %+v", got, c.want)
			}
		})
	}
}

func heartbeatResponsesEqual(a, b HeartbeatResponse) bool {
	if a.Command != b.Command || a.Reason != b.Reason || a.EndReason != b.EndReason || len(a.Notices) != len(b.Notices) {
		return false
	}
	for i := range a.Notices {
		if a.Notices[i] != b.Notices[i] {
			return false
		}
	}
	return true
}

func TestHeartbeatRejectsAMalformedResponse(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{"JSON ではない", "x"},
		{"命令が無い", `{"notices":[]}`},
		{"未知の命令", `{"command":"restart"}`},
		{"理由が未知", `{"command":"stop","reason":"because"}`},
		{"終了の理由が未知", `{"command":"stop","end_reason":"because"}`},
		{"通知の状態が未知", `{"command":"continue","notices":[{"kind":"status","state":"x","watch_url":null,"warning":null,"time_limit_notice_seconds":null,"end_reason":null}]}`},
		{"通知の警告が未知", `{"command":"continue","notices":[{"kind":"status","state":"live","watch_url":null,"warning":"boom","time_limit_notice_seconds":null,"end_reason":null}]}`},
		{"通知の終了の理由が未知", `{"command":"continue","notices":[{"kind":"status","state":"ended","watch_url":null,"warning":null,"time_limit_notice_seconds":null,"end_reason":"x"}]}`},
		{"通知の予告が負", `{"command":"continue","notices":[{"kind":"status","state":"live","watch_url":null,"warning":null,"time_limit_notice_seconds":-1,"end_reason":null}]}`},
		{"通知の視聴 URL が javascript", `{"command":"continue","notices":[{"kind":"status","state":"live","watch_url":"javascript:alert(1)","warning":null,"time_limit_notice_seconds":null,"end_reason":null}]}`},
		{"通知が配列ではない", `{"command":"continue","notices":"x"}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			app := newFakeApp(t, reply(200, c.body))
			_, err := newTestClient(t, app).Heartbeat(context.Background(), sampleBroadcastID, HeartbeatRequest{Epoch: 1, Seq: 1})
			if !isError(err, ErrInvalidResponse) {
				t.Fatalf("error = %v, want ErrInvalidResponse", err)
			}
		})
	}
}

// ---- 事象 ----

func TestEventSendsTheContractRequest(t *testing.T) {
	app := newFakeApp(t, reply(204, ""))
	client := newTestClient(t, app)
	// 2026-10-07 04:30:12 UTC は、JST の 13:30:12（契約の例）
	at := time.Date(2026, 10, 7, 4, 30, 12, 345, time.UTC)

	if err := client.Event(context.Background(), sampleBroadcastID, EventRequest{
		Epoch: 3, Kind: contract.RelayEventKindInterrupted, At: at, Cause: contract.InterruptCauseBrowserDisconnected,
	}); err != nil {
		t.Fatalf("Event: %v", err)
	}
	recorded := app.only(t)
	if recorded.Path != "/internal/v1/broadcasts/"+sampleBroadcastID+"/events" || recorded.Header.Get("X-Relay-Secret") != canarySecret {
		t.Fatalf("request = %s", recorded.Path)
	}
	assertJSONEqual(t, recorded.Body, `{"epoch":3,"kind":"interrupted","at":"2026-10-07T13:30:12+09:00","detail":{"cause":"browser_disconnected"}}`)

	if err := client.Event(context.Background(), sampleBroadcastID, EventRequest{Epoch: 4, Kind: contract.RelayEventKindSessionEnded, At: at.Add(time.Hour)}); err != nil {
		t.Fatalf("Event: %v", err)
	}
	assertJSONEqual(t, app.recorded()[1].Body, `{"epoch":4,"kind":"session_ended","at":"2026-10-07T14:30:12+09:00"}`)
}

func TestEventAtIsInJSTWhateverTheLocationOfTheInput(t *testing.T) {
	app := newFakeApp(t, reply(204, ""))
	client := newTestClient(t, app)
	tokyo := time.FixedZone("elsewhere", -5*60*60)
	at := time.Date(2026, 10, 7, 0, 0, 59, 0, tokyo) // UTC 05:00:59 = JST 14:00:59
	if err := client.Event(context.Background(), sampleBroadcastID, EventRequest{Epoch: 1, Kind: contract.RelayEventKindResumed, At: at}); err != nil {
		t.Fatalf("Event: %v", err)
	}
	assertJSONEqual(t, app.only(t).Body, `{"epoch":1,"kind":"resumed","at":"2026-10-07T14:00:59+09:00"}`)
}

func TestEventChecksItsArguments(t *testing.T) {
	cases := []struct {
		name string
		id   string
		ev   EventRequest
	}{
		{"識別子が不正", "abc", EventRequest{Epoch: 1, Kind: contract.RelayEventKindResumed, At: time.Unix(1, 0)}},
		{"世代が 0", sampleBroadcastID, EventRequest{Epoch: 0, Kind: contract.RelayEventKindResumed, At: time.Unix(1, 0)}},
		{"種類が未知", sampleBroadcastID, EventRequest{Epoch: 1, Kind: contract.RelayEventKind("weird"), At: time.Unix(1, 0)}},
		{"時刻が無い", sampleBroadcastID, EventRequest{Epoch: 1, Kind: contract.RelayEventKindResumed}},
		{"原因が未知", sampleBroadcastID, EventRequest{Epoch: 1, Kind: contract.RelayEventKindInterrupted, At: time.Unix(1, 0), Cause: contract.InterruptCause("x")}},
		{"中断に原因が無い", sampleBroadcastID, EventRequest{Epoch: 1, Kind: contract.RelayEventKindInterrupted, At: time.Unix(1, 0)}},
		{"送出失敗の原因がブラウザの切断", sampleBroadcastID, EventRequest{Epoch: 1, Kind: contract.RelayEventKindPublishFailed, At: time.Unix(1, 0), Cause: contract.InterruptCauseBrowserDisconnected}},
		{"送出失敗の原因が映像の途絶", sampleBroadcastID, EventRequest{Epoch: 1, Kind: contract.RelayEventKindPublishFailed, At: time.Unix(1, 0), Cause: contract.InterruptCauseMediaStalled}},
		{"復帰に原因がある", sampleBroadcastID, EventRequest{Epoch: 1, Kind: contract.RelayEventKindResumed, At: time.Unix(1, 0), Cause: contract.InterruptCauseRTMPSDisconnected}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			app := newFakeApp(t, reply(204, ""))
			err := newTestClient(t, app).Event(context.Background(), c.id, c.ev)
			if !isError(err, ErrInvalidArgument) {
				t.Fatalf("error = %v, want ErrInvalidArgument", err)
			}
			if got := len(app.recorded()); got != 0 {
				t.Fatalf("a request was sent (%d)", got)
			}
		})
	}
}

func TestEventAcceptsAny2xx(t *testing.T) {
	for _, status := range []int{200, 202, 204} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			app := newFakeApp(t, reply(status, ""))
			err := newTestClient(t, app).Event(context.Background(), sampleBroadcastID, EventRequest{Epoch: 1, Kind: contract.RelayEventKindResumed, At: time.Unix(1, 0)})
			if err != nil {
				t.Fatalf("Event: %v", err)
			}
		})
	}
}

// 秘密値は、ヘッダにだけ載る（本文・URL・ログに載らない）。
func TestTheSecretTravelsOnlyInTheHeader(t *testing.T) {
	app := newFakeApp(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(204)
	})
	client := newTestClient(t, app)
	for _, call := range []string{"verify", "provision", "heartbeat", "event"} {
		app.setRespond(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(500) })
		_ = invoke(client, call)
	}
	for _, request := range app.recorded() {
		if strings.Contains(string(request.Body), canarySecret) || strings.Contains(request.Path, canarySecret) {
			t.Fatalf("the secret travelled outside the header: %s", request.Path)
		}
		if request.Header.Get("X-Relay-Secret") != canarySecret {
			t.Fatalf("X-Relay-Secret is missing on %s", request.Path)
		}
	}
}

// 他のパッケージの疑似の実装が、Client と同じ型付きのエラーを作れる。
func TestNewAPIErrorBuildsTheSameTypedErrorAsTheClient(t *testing.T) {
	cases := []struct {
		name       string
		status     int
		code       string
		endReason  contract.EndReason
		want       error
		wantCode   string
		wantReason contract.EndReason
	}{
		{"準備の失敗", 502, "prepare_failed", contract.EndReasonPrepareFailed, ErrPrepareFailed, "prepare_failed", contract.EndReasonPrepareFailed},
		{"古い世代", 409, "stale_epoch", "", ErrStaleEpoch, "stale_epoch", ""},
		{"終了理由が列挙の値でない", 409, "broadcast_ended", contract.EndReason("x"), ErrBroadcastEnded, "broadcast_ended", ""},
		{"ステータスと符号が合わない", 400, "stale_epoch", "", ErrUnexpectedStatus, "", ""},
		{"未知の符号の 5xx", 503, "x", "", ErrUnavailable, "", ""},
		{"符号なしの 404", 404, "", "", ErrUnexpectedStatus, "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := NewAPIError(contract.InternalCallProvision, c.status, c.code, c.endReason)
			if !isError(err, c.want) {
				t.Fatalf("error = %v, want %v", err, c.want)
			}
			if err.Code != c.wantCode || err.EndReason != c.wantReason || err.Status != c.status {
				t.Fatalf("APIError = %+v", err)
			}
		})
	}
}

func TestCloseIdleConnectionsIsSafeAndTheClientKeepsWorking(t *testing.T) {
	app := newFakeApp(t, reply(200, sampleVerifyBody))
	client := newTestClient(t, app)
	if _, err := client.Verify(context.Background(), Ticket("t")); err != nil {
		t.Fatalf("Verify: %v", err)
	}
	client.CloseIdleConnections()
	client.CloseIdleConnections()
	if _, err := client.Verify(context.Background(), Ticket("t")); err != nil {
		t.Fatalf("Verify after CloseIdleConnections: %v", err)
	}
}
