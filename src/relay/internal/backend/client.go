package backend

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

const (
	headerSecret      = "X-Relay-Secret"
	headerContentType = "Content-Type"
	headerAccept      = "Accept"
	contentTypeJSON   = "application/json; charset=utf-8"
	acceptJSON        = "application/json"

	pathPrefix   = "/internal/v1"
	pathVerify   = pathPrefix + "/verify"
	pathBcasts   = pathPrefix + "/broadcasts/"
	suffixProv   = "/provision"
	suffixBeat   = "/heartbeat"
	suffixEvents = "/events"

	// maxResponseBytes は、応答の本文として読む上限（バイト）。契約の応答は、数百バイトから数 KB。
	maxResponseBytes = 1 << 20

	// maxSecretBytes は、共有の秘密値の長さの上限（バイト）。
	maxSecretBytes = 256

	dialTimeout     = 3 * time.Second
	dialKeepAlive   = 30 * time.Second
	idleConnTimeout = 60 * time.Second
	maxIdleConns    = 8
	maxIdlePerHost  = 4
)

// 呼び出しごとの期限の既定値。心拍・事象は 5 秒、準備は 90 秒（受理済みの期限 deadlines.reserved_seconds と同じ。issue #20）。
// 照合は、契約に定めが無く、接続通知の期限（relay.hello_timeout_seconds）と同じ 10 秒にした（解釈）。
const (
	DefaultVerifyTimeout    = time.Duration(contract.RelayHelloTimeoutSeconds) * time.Second
	DefaultProvisionTimeout = time.Duration(contract.DeadlinesReservedSeconds) * time.Second
	DefaultHeartbeatTimeout = 5 * time.Second
	DefaultEventTimeout     = 5 * time.Second
)

// Timeouts は、呼び出しごとの期限。ゼロの欄は既定値。負は ErrInvalidConfig。
type Timeouts struct {
	Verify    time.Duration
	Provision time.Duration
	Heartbeat time.Duration
	Event     time.Duration
}

// DefaultTimeouts は、既定の期限。
func DefaultTimeouts() Timeouts {
	return Timeouts{
		Verify:    DefaultVerifyTimeout,
		Provision: DefaultProvisionTimeout,
		Heartbeat: DefaultHeartbeatTimeout,
		Event:     DefaultEventTimeout,
	}
}

func (t Timeouts) normalized() (Timeouts, error) {
	defaults := DefaultTimeouts()
	fields := []struct {
		value    *time.Duration
		fallback time.Duration
	}{
		{&t.Verify, defaults.Verify},
		{&t.Provision, defaults.Provision},
		{&t.Heartbeat, defaults.Heartbeat},
		{&t.Event, defaults.Event},
	}
	for _, field := range fields {
		switch {
		case *field.value < 0:
			return Timeouts{}, fmt.Errorf("%w: a timeout is negative", ErrInvalidConfig)
		case *field.value == 0:
			*field.value = field.fallback
		}
	}
	return t, nil
}

// Config は、Client の設定。
type Config struct {
	// BaseURL は、内部通信の接続先（環境変数 BACKEND_INTERNAL_URL。例 http://backend:3101）。http か https で、パス・クエリ・
	// ユーザー情報を持たない。
	BaseURL string
	// Secret は、共有の秘密値（環境変数 RELAY_SHARED_SECRET）。
	Secret Secret
	// HTTPClient は、HTTP クライアント。nil なら、環境のプロキシを使わない既定のもの。どちらでも、リダイレクトは追わない。
	HTTPClient *http.Client
	// Timeouts は、呼び出しごとの期限。
	Timeouts Timeouts
}

// Client は、アプリケーションの内部通信の口のクライアント。ゴルーチンから並行に呼んでよい。
type Client struct {
	base       string
	secret     Secret
	httpClient *http.Client
	timeouts   Timeouts
}

// NewClient は、設定を検査して Client を作る。不正なら ErrInvalidConfig（文言は、URL・秘密値を含まない）。
func NewClient(cfg Config) (*Client, error) {
	base, err := normalizeBaseURL(cfg.BaseURL)
	if err != nil {
		return nil, err
	}
	if err := checkSecret(cfg.Secret); err != nil {
		return nil, err
	}
	timeouts, err := cfg.Timeouts.normalized()
	if err != nil {
		return nil, err
	}
	return &Client{base: base, secret: cfg.Secret, httpClient: newHTTPClient(cfg.HTTPClient), timeouts: timeouts}, nil
}

// normalizeBaseURL は、接続先を「スキーム://ホスト[:ポート]」にそろえる。
func normalizeBaseURL(raw string) (string, error) {
	parsed, err := url.Parse(raw)
	switch {
	case err != nil,
		parsed.Scheme != "http" && parsed.Scheme != "https",
		parsed.Host == "",
		parsed.Opaque != "",
		parsed.User != nil,
		parsed.RawQuery != "" || parsed.ForceQuery || parsed.Fragment != "",
		parsed.Path != "" && parsed.Path != "/":
		return "", fmt.Errorf("%w: the internal URL must be an http(s) URL without a path, query, fragment or user information", ErrInvalidConfig)
	}
	return parsed.Scheme + "://" + parsed.Host, nil
}

// checkSecret は、共有の秘密値が、HTTP のヘッダに載せられる形かを検査する（空・長すぎる・空白や制御文字や非 ASCII を含む、は不可）。
func checkSecret(secret Secret) error {
	raw := secret.reveal()
	if raw == "" || len(raw) > maxSecretBytes {
		return fmt.Errorf("%w: the shared secret is empty or too long", ErrInvalidConfig)
	}
	for i := 0; i < len(raw); i++ {
		if raw[i] < firstPrintable || raw[i] > lastPrintable {
			return fmt.Errorf("%w: the shared secret contains a character that cannot be sent in a header", ErrInvalidConfig)
		}
	}
	return nil
}

// newHTTPClient は、リダイレクトを追わない HTTP クライアントを作る。custom があれば、それを写して使う（リダイレクトの規則だけ上書き）。
func newHTTPClient(custom *http.Client) *http.Client {
	var client http.Client
	if custom != nil {
		client = *custom
	} else {
		client = http.Client{Transport: &http.Transport{
			// 内部通信は、環境のプロキシを経由しない（内部の口へ、秘密値つきの要求を、外のプロキシ経由で送らない）
			Proxy:               nil,
			DialContext:         (&net.Dialer{Timeout: dialTimeout, KeepAlive: dialKeepAlive}).DialContext,
			MaxIdleConns:        maxIdleConns,
			MaxIdleConnsPerHost: maxIdlePerHost,
			IdleConnTimeout:     idleConnTimeout,
		}}
	}
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &client
}

// CloseIdleConnections は、再利用のために保っている、使っていない接続を閉じる（中継の停止の手順で呼ぶ。接続のゴルーチンを残さない）。
func (c *Client) CloseIdleConnections() { c.httpClient.CloseIdleConnections() }

// ---- 呼び出し ----

// Verify は、照合（POST /internal/v1/verify）。接続チケットを 1 回限りで消費し、送出世代を 1 進める（冪等ではない）。
// 失敗は、ErrTicketInvalid（未知・失効・使用済み）・ErrBroadcastNotAttachable（終了済み・状態が不適）・ErrUnavailable（到達できない・5xx）など。
func (c *Client) Verify(ctx context.Context, ticket Ticket) (VerifyResult, error) {
	var wire verifyWire
	body := struct {
		Ticket string `json:"ticket"`
	}{Ticket: ticket.reveal()}
	err := c.post(ctx, call{kind: contract.InternalCallVerify, path: pathVerify, timeout: c.timeouts.Verify, success: statusOK}, body, &wire)
	if err != nil {
		return VerifyResult{}, err
	}
	return wire.result()
}

// Provision は、準備（POST /internal/v1/broadcasts/:id/provision）。取り込み先と配信キーを得る（冪等）。数十秒かかり得る。
// 失敗は、ErrStaleEpoch・ErrBroadcastEnded・ErrPriorUnsettled・ErrPrepareFailed・ErrAuthorizationRevoked・ErrLiveNotEnabled
// （*APIError の EndReason に、配信の終了理由）など。引数が不正なら、要求を送らずに ErrInvalidArgument。
func (c *Client) Provision(ctx context.Context, broadcastID string, epoch int, profile contract.Profile) (ProvisionResult, error) {
	if !isUUID(broadcastID) {
		return ProvisionResult{}, invalidArgument("provision: broadcast id is not a UUID")
	}
	if epoch < 1 {
		return ProvisionResult{}, invalidArgument("provision: epoch is not positive")
	}
	if !profile.Valid() {
		return ProvisionResult{}, invalidArgument("provision: unknown profile")
	}
	var result ProvisionResult
	err := c.post(ctx, call{kind: contract.InternalCallProvision, path: pathBcasts + broadcastID + suffixProv, timeout: c.timeouts.Provision, success: statusOK},
		provisionRequest{Epoch: epoch, Profile: profile}, &result)
	if err != nil {
		return ProvisionResult{}, err
	}
	if err := result.validate(); err != nil {
		return ProvisionResult{}, err
	}
	return result, nil
}

// Heartbeat は、心拍（POST /internal/v1/broadcasts/:id/heartbeat）。応答を得られなかった心拍は、同じ Seq・同じ内容で再送する（冪等）。
func (c *Client) Heartbeat(ctx context.Context, broadcastID string, request HeartbeatRequest) (HeartbeatResponse, error) {
	if !isUUID(broadcastID) {
		return HeartbeatResponse{}, invalidArgument("heartbeat: broadcast id is not a UUID")
	}
	var wire heartbeatWire
	err := c.post(ctx, call{kind: contract.InternalCallHeartbeat, path: pathBcasts + broadcastID + suffixBeat, timeout: c.timeouts.Heartbeat, success: statusOK},
		request, &wire)
	if err != nil {
		return HeartbeatResponse{}, err
	}
	return wire.response()
}

// Event は、事象（POST /internal/v1/broadcasts/:id/events）を 1 回送る（冪等）。保持と再送は EventQueue。
// 古い送出世代の事象・終了済みの配信の事象も、アプリケーションは 204 で受ける。未知の配信は ErrNotFound。
func (c *Client) Event(ctx context.Context, broadcastID string, event EventRequest) error {
	if !isUUID(broadcastID) {
		return invalidArgument("event: broadcast id is not a UUID")
	}
	if err := event.validate(); err != nil {
		return err
	}
	return c.post(ctx, call{kind: contract.InternalCallEvent, path: pathBcasts + broadcastID + suffixEvents, timeout: c.timeouts.Event, success: status2xx}, event, nil)
}

// ---- 通信 ----

// call は、1 回の呼び出しの仕様。
type call struct {
	kind    contract.InternalCall
	path    string
	timeout time.Duration
	success func(status int) bool
}

func statusOK(status int) bool { return status == http.StatusOK }

func status2xx(status int) bool { return status >= 200 && status < 300 }

// post は、JSON の要求を送り、成功なら応答を out へ読む（out が nil なら、本文は読まない）。失敗は、型付きのエラー。
func (c *Client) post(ctx context.Context, spec call, requestBody any, out any) error {
	payload, err := json.Marshal(requestBody)
	if err != nil {
		return invalidArgument(string(spec.kind) + ": the request cannot be encoded")
	}
	callCtx, cancel := context.WithTimeout(ctx, spec.timeout)
	defer cancel()
	request, err := http.NewRequestWithContext(callCtx, http.MethodPost, c.base+spec.path, bytes.NewReader(payload))
	if err != nil {
		return invalidArgument(string(spec.kind) + ": the request cannot be built")
	}
	request.Header.Set(headerSecret, c.secret.reveal())
	request.Header.Set(headerContentType, contentTypeJSON)
	request.Header.Set(headerAccept, acceptJSON)

	response, err := c.httpClient.Do(request)
	if err != nil {
		return transportError(spec, ctx, callCtx, err)
	}
	defer response.Body.Close()

	body, tooLarge := readLimited(response.Body)
	if !spec.success(response.StatusCode) {
		return apiError(spec.kind, response.StatusCode, body, tooLarge)
	}
	if out == nil {
		return nil
	}
	if tooLarge {
		return invalidResponse(string(spec.kind) + ": the response is too large")
	}
	if err := json.Unmarshal(body, out); err != nil {
		return invalidResponse(string(spec.kind) + ": the response is not the expected JSON")
	}
	return nil
}

// readLimited は、本文を maxResponseBytes まで読む。超えていたら、tooLarge。読み残しは捨てる（接続を再利用するため）。
func readLimited(body io.Reader) (data []byte, tooLarge bool) {
	data, _ = io.ReadAll(io.LimitReader(body, maxResponseBytes+1))
	if len(data) > maxResponseBytes {
		_, _ = io.Copy(io.Discard, io.LimitReader(body, maxResponseBytes))
		return nil, true
	}
	return data, false
}

// transportError は、通信の失敗を分類する。呼び出し側の取り消し・期限は、そのまま（再送の対象にしない）。
// この呼び出しの期限切れと、接続の失敗は、ErrUnavailable。
func transportError(spec call, caller, callCtx context.Context, cause error) error {
	if callerErr := caller.Err(); callerErr != nil {
		return fmt.Errorf("backend: %s: %w", spec.kind, callerErr)
	}
	if errors.Is(callCtx.Err(), context.DeadlineExceeded) {
		return fmt.Errorf("%w: %s: %w", ErrUnavailable, spec.kind, context.DeadlineExceeded)
	}
	return fmt.Errorf("%w: %s: %w", ErrUnavailable, spec.kind, cause)
}

// errorEnvelope は、エラーの本文 {"error":{"code":"…","details":{…}}}。
type errorEnvelope struct {
	Error struct {
		Code    string `json:"code"`
		Details struct {
			EndReason string `json:"end_reason"`
		} `json:"details"`
	} `json:"error"`
}

// apiError は、成功ではない応答から、*APIError を作る。符号は、契約の語彙で、契約のステータスと合うものだけを採る
// （応答の本文を、エラーの文言・フィールドへ写さない）。
func apiError(kind contract.InternalCall, status int, body []byte, tooLarge bool) error {
	var envelope errorEnvelope
	if tooLarge || json.Unmarshal(body, &envelope) != nil {
		return buildAPIError(kind, status, "", "")
	}
	return buildAPIError(kind, status, envelope.Error.Code, contract.EndReason(envelope.Error.Details.EndReason))
}
