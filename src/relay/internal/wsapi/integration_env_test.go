package wsapi_test

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http/httptest"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/frame"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/appenv"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/config"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/server"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/session"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/wsapi"
)

// 結合試験の土台。実際の WebSocket のクライアント（gorilla）が、実際の HTTP サーバー（Gin のルーター）の GET /ws へ接続し、
// 中継（結線済みの server.App）が、疑似のアプリケーション・疑似の RTMP の受け口（TLS・自己署名）と、実際に通信する。
// 時計だけを注入する（実時間を待たない）。非同期の結果は、観測できるもの（受け取ったメッセージ・受け口に届いたタグ・
// アプリケーションに届いた呼び出し・取り込みセッションの状態）で待つ。

// ---- 時計 ----

type testClock struct {
	mu     sync.Mutex
	now    time.Time
	timers map[*testTimer]struct{}
}

type testTimer struct {
	clock  *testClock
	when   time.Time
	fn     func()
	active bool
}

func newTestClock() *testClock {
	return &testClock{now: time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC), timers: map[*testTimer]struct{}{}}
}

func (c *testClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *testClock) AfterFunc(d time.Duration, f func()) session.Timer {
	c.mu.Lock()
	defer c.mu.Unlock()
	timer := &testTimer{clock: c, when: c.now.Add(d), fn: f, active: true}
	c.timers[timer] = struct{}{}
	return timer
}

// Advance は、時刻を d 進めてから、期限の来たタイマーを、期限の順に（呼び出し元のゴルーチンで）鳴らす。
func (c *testClock) Advance(d time.Duration) {
	type due struct {
		when time.Time
		fn   func()
	}
	c.mu.Lock()
	c.now = c.now.Add(d)
	var fire []due
	for timer := range c.timers {
		if timer.active && !timer.when.After(c.now) {
			timer.active = false
			delete(c.timers, timer)
			fire = append(fire, due{when: timer.when, fn: timer.fn})
		}
	}
	c.mu.Unlock()
	sort.Slice(fire, func(i, j int) bool { return fire[i].when.Before(fire[j].when) })
	for _, item := range fire {
		item.fn()
	}
}

func (c *testClock) activeTimers() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.timers)
}

func (t *testTimer) Stop() bool {
	t.clock.mu.Lock()
	defer t.clock.mu.Unlock()
	was := t.active
	t.active = false
	delete(t.clock.timers, t)
	return was
}

func (t *testTimer) Reset(d time.Duration) bool {
	t.clock.mu.Lock()
	defer t.clock.mu.Unlock()
	was := t.active
	t.active = true
	t.when = t.clock.now.Add(d)
	t.clock.timers[t] = struct{}{}
	return was
}

// ---- 待つ ----

// eventually は、条件が満たされるのを、実時間で最大 10 秒待つ（非同期の結果を待つ。時計は進めない）。
func eventually(t testing.TB, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for: %s", what)
		}
		runtime.Gosched()
		time.Sleep(time.Millisecond)
	}
}

// ---- ゴルーチンの残り ----

var ownSourcePattern = regexp.MustCompile(`/internal/(wsapi|session|backend|rtmps|flv|server)/[A-Za-z0-9_]+\.go:`)

func goroutineBlocks() []string {
	buffer := make([]byte, 1<<20)
	for {
		n := runtime.Stack(buffer, true)
		if n < len(buffer) {
			buffer = buffer[:n]
			break
		}
		buffer = make([]byte, 2*len(buffer))
	}
	return strings.Split(string(buffer), "\n\n")
}

// leftoverGoroutines は、中継の本番のコード（wsapi・session・backend・rtmps・flv・server）で動いているゴルーチン。
func leftoverGoroutines() []string {
	var found []string
	for _, block := range goroutineBlocks() {
		if strings.Contains(block, "leftoverGoroutines") {
			continue
		}
		for _, line := range strings.Split(block, "\n") {
			if ownSourcePattern.MatchString(line) && !strings.Contains(line, "_test.go:") {
				found = append(found, block)
				break
			}
		}
	}
	return found
}

func countRelayGoroutines() int { return len(leftoverGoroutines()) }

func assertNoLeftoverGoroutines(t testing.TB) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		found := leftoverGoroutines()
		if len(found) == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("goroutines remain after the relay was stopped:\n%s", strings.Join(found, "\n---\n"))
		}
		runtime.Gosched()
		time.Sleep(time.Millisecond)
	}
}

// ---- 同期するバッファ ----

type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// ---- 中継の環境 ----

type relayEnv struct {
	t      *testing.T
	clock  *testClock
	app    *fakeApp
	rtmp   *rtmpServer
	waiter *fakeWaiter
	relay  *server.App
	http   *httptest.Server
	logs   *syncBuffer
	access *syncBuffer
	errors *syncBuffer
	// wsURLOverride が空でなければ、クライアントは、httptest のサーバーではなく、ここ（ws://…/ws）へ接続する
	wsURLOverride string
}

// newRelayEnv は、疑似のアプリケーション・疑似の RTMP の受け口・時計を用意し、実際の結線（server.NewApp）の中継を、
// 実際の HTTP サーバーで公開する。WebSocket の死活の確認（ping・無通信の期限）は、別の試験で調べるので、ここでは鳴らない長さにする。
func newRelayEnv(t *testing.T, mutate ...func(*server.Deps)) *relayEnv {
	t.Helper()
	// 登録の逆順に実行される。ゴルーチンの残りの検査は、最後に行う
	t.Cleanup(func() { assertNoLeftoverGoroutines(t) })

	app := newFakeApp(t)
	rtmpSrv := newRTMPServer(t)
	app.setRTMPURL(rtmpSrv.URL())
	policy, err := rtmps.NewPolicy(rtmps.Target{Host: rtmpHost, Port: rtmpSrv.port})
	if err != nil {
		t.Fatalf("NewPolicy: %v", err)
	}
	clock := newTestClock()
	waiter := &fakeWaiter{}
	logs, access, errs := &syncBuffer{}, &syncBuffer{}, &syncBuffer{}
	logger := slog.New(slog.NewJSONHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	restoreLogs := server.RedirectThirdPartyLogs(logger)
	t.Cleanup(restoreLogs)

	deps := server.Deps{
		Logger: logger, AccessLog: access, ErrorLog: errs, Clock: clock, Waiter: waiter, Policy: &policy,
		RTMPS:     rtmps.Config{RootCAs: rtmpSrv.roots},
		WebSocket: wsapi.Options{PingInterval: 24 * time.Hour, IdleTimeout: 48 * time.Hour},
	}
	for _, m := range mutate {
		m(&deps)
	}
	cfg := config.Config{Environment: appenv.Test, ListenAddr: ":0", BackendInternalURL: app.URL(), SharedSecret: backend.Secret(appSecret)}
	relay, err := server.NewApp(cfg, deps)
	if err != nil {
		t.Fatalf("NewApp: %v", err)
	}
	httpServer := httptest.NewServer(relay.Handler())
	env := &relayEnv{t: t, clock: clock, app: app, rtmp: rtmpSrv, waiter: waiter, relay: relay, http: httpServer, logs: logs, access: access, errors: errs}

	t.Cleanup(httpServer.Close)
	t.Cleanup(func() {
		if t.Failed() {
			t.Logf("relay logs:\n%s", logs.String())
		}
	})
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if err := relay.Shutdown(ctx); err != nil && !t.Failed() {
			t.Errorf("Shutdown at the end of the test: %v", err)
		}
		if n := clock.activeTimers(); n != 0 && !t.Failed() {
			t.Errorf("%d timers are still active after Shutdown", n)
		}
	})
	return env
}

// assertNoSecretsLogged は、中継のすべての出力（記録・アクセスログ・パニックの記録。go-rtmp の記録を含む）に、接続チケット・配信キー・
// 取り込み先・共有の秘密値が無いことを確かめる。記録が空だと、確かめたことにならないので、空なら失敗にする。
func (e *relayEnv) assertNoSecretsLogged() {
	e.t.Helper()
	if strings.TrimSpace(e.logs.String()) == "" {
		e.t.Fatal("nothing was logged, so the check for secrets would pass vacuously")
	}
	outputs := map[string]string{"relay log": e.logs.String(), "access log": e.access.String(), "error log": e.errors.String()}
	secrets := []string{"SECRET", "dummy-ticket", secretStreamID, appSecret, e.rtmp.URL(), "live2"}
	for name, text := range outputs {
		for _, secret := range secrets {
			if strings.Contains(text, secret) {
				e.t.Errorf("the %s contains %q:\n%s", name, secret, text)
			}
		}
	}
}

func (e *relayEnv) wsURL() string {
	if e.wsURLOverride != "" {
		return e.wsURLOverride
	}
	return "ws" + strings.TrimPrefix(e.http.URL, "http") + "/ws"
}

// session は、配信の取り込みセッション（まだ無ければ、作られるまで待つ）。
func (e *relayEnv) session(broadcastID string) *session.IngestSession {
	e.t.Helper()
	var found *session.IngestSession
	eventually(e.t, "the ingest session exists", func() bool {
		s, ok := e.relay.Registry().Find(broadcastID)
		found = s
		return ok
	})
	return found
}

func (e *relayEnv) waitState(broadcastID string, want session.State) {
	e.t.Helper()
	s := e.session(broadcastID)
	eventually(e.t, fmt.Sprintf("the session state becomes %s (now %s)", want, s.State()), func() bool { return s.State() == want })
}

// accountKey は、n 番目のアカウントの、不透明な値（64 文字の小文字の 16 進数）。
func accountKey(n int) string { return fmt.Sprintf("%064x", n+1) }

// broadcastID は、n 番目の配信の識別子（UUID）。
func broadcastID(n int) string { return fmt.Sprintf("00000000-0000-4000-8000-%012d", n) }

// ---- WebSocket のクライアント ----

type clientFrame struct {
	typ  contract.FrameType
	body []byte
}

func (f clientFrame) json() map[string]any {
	out := map[string]any{}
	if len(f.body) > 0 {
		_ = json.Unmarshal(f.body, &out)
	}
	return out
}

func (f clientFrame) String() string {
	name := "unknown"
	if kind, ok := f.typ.MessageType(); ok {
		name = string(kind)
	}
	return name + string(f.body)
}

type wsClient struct {
	t    *testing.T
	conn *websocket.Conn

	mu       sync.Mutex
	frames   []clientFrame
	cursor   int
	closeErr error
	finished chan struct{}
	changed  chan struct{}
}

func (e *relayEnv) dial() *wsClient {
	e.t.Helper()
	before := e.relay.WebSocket().Accepted()
	dialer := &websocket.Dialer{HandshakeTimeout: 5 * time.Second, WriteBufferSize: 1 << 18}
	conn, response, err := dialer.Dial(e.wsURL(), nil)
	if err != nil {
		status := 0
		if response != nil {
			status = response.StatusCode
		}
		e.t.Fatalf("dial: %v (HTTP status %d)", err, status)
	}
	c := &wsClient{t: e.t, conn: conn, finished: make(chan struct{}), changed: make(chan struct{}, 1)}
	go c.readLoop()
	e.t.Cleanup(func() { c.close() })
	// 中継が、この接続をセッションの台帳へ渡す（接続通知の期限のタイマーが始まる）のを待つ。時計を進める試験が、タイマーより先に進めない
	eventually(e.t, "the relay registered the connection", func() bool { return e.relay.WebSocket().Accepted() == before+1 })
	return c
}

func (c *wsClient) signal() {
	select {
	case c.changed <- struct{}{}:
	default:
	}
}

func (c *wsClient) readLoop() {
	defer close(c.finished)
	for {
		kind, data, err := c.conn.ReadMessage()
		if err != nil {
			c.mu.Lock()
			c.closeErr = err
			c.mu.Unlock()
			c.signal()
			return
		}
		if kind != websocket.BinaryMessage || len(data) < contract.WSFrameHeaderBytes {
			continue
		}
		c.mu.Lock()
		c.frames = append(c.frames, clientFrame{typ: contract.FrameType(data[contract.WSFrameHeaderFieldsTypeOffset]), body: append([]byte(nil), data[contract.WSFrameHeaderBytes:]...)})
		c.mu.Unlock()
		c.signal()
	}
}

func (c *wsClient) close() { _ = c.conn.UnderlyingConn().Close() }

// send は、フレームを 1 つ送る。
func (c *wsClient) send(typ contract.FrameType, keyframe bool, timestampUs uint64, body []byte) {
	c.t.Helper()
	message, err := frame.Encode(frame.Frame{Type: typ, Keyframe: keyframe, TimestampUs: timestampUs, Body: body})
	if err != nil {
		c.t.Fatalf("Encode: %v", err)
	}
	c.sendRaw(message)
}

func (c *wsClient) sendRaw(message []byte) {
	c.t.Helper()
	if err := c.conn.WriteMessage(websocket.BinaryMessage, message); err != nil {
		c.t.Fatalf("write: %v", err)
	}
}

// tryRaw は、メッセージを送る。失敗（接続が閉じられている）は、エラーとして返す。
func (c *wsClient) tryRaw(message []byte) error {
	return c.conn.WriteMessage(websocket.BinaryMessage, message)
}

func (c *wsClient) hello(ticket string) {
	c.t.Helper()
	c.send(contract.FrameTypeHello, false, 0, []byte(ticket))
}

// snapshot は、受け取ったフレームすべて（消費せずに）。
func (c *wsClient) snapshot() []clientFrame {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]clientFrame(nil), c.frames...)
}

func (c *wsClient) ofType(typ contract.FrameType) []clientFrame {
	var out []clientFrame
	for _, f := range c.snapshot() {
		if f.typ == typ {
			out = append(out, f)
		}
	}
	return out
}

// describe は、受け取ったフレームを、順に並べた文字列にする（ack は数が多いので除く）。
func (c *wsClient) describe() []string {
	var out []string
	for _, f := range c.snapshot() {
		if f.typ == contract.FrameTypeAck {
			continue
		}
		out = append(out, f.String())
	}
	return out
}

// waitFor は、まだ見ていないフレームのうち、種別が typ で、accept を満たす（nil なら何でも）最初のものを返す（最大 10 秒待つ）。
// 見たものは、消費する（前の、種別の違うフレームも、読み飛ばす）。
func (c *wsClient) waitFor(typ contract.FrameType, accept func(map[string]any) bool) clientFrame {
	c.t.Helper()
	deadline := time.After(10 * time.Second)
	for {
		c.mu.Lock()
		for c.cursor < len(c.frames) {
			f := c.frames[c.cursor]
			c.cursor++
			if f.typ == typ && (accept == nil || accept(f.json())) {
				c.mu.Unlock()
				return f
			}
		}
		closed := c.closeErr
		c.mu.Unlock()
		if closed != nil {
			c.t.Fatalf("the connection ended (%v) before the expected frame %v arrived; received so far: %v", closed, typ, c.describe())
		}
		select {
		case <-c.changed:
		case <-deadline:
			c.t.Fatalf("timed out waiting for the frame %v; received so far: %v", typ, c.describe())
		}
	}
}

// tryWaitFor は、waitFor と同じだが、timeout（実時間）までに見つからなければ、失敗にせず false を返す。
func (c *wsClient) tryWaitFor(typ contract.FrameType, accept func(map[string]any) bool, timeout time.Duration) (clientFrame, bool) {
	deadline := time.After(timeout)
	for {
		c.mu.Lock()
		for c.cursor < len(c.frames) {
			f := c.frames[c.cursor]
			c.cursor++
			if f.typ == typ && (accept == nil || accept(f.json())) {
				c.mu.Unlock()
				return f, true
			}
		}
		closed := c.closeErr
		c.mu.Unlock()
		if closed != nil {
			return clientFrame{}, false
		}
		select {
		case <-c.changed:
		case <-deadline:
			return clientFrame{}, false
		}
	}
}

// statusIs は、status の state が want であることを調べる述語。
func statusIs(want string) func(map[string]any) bool {
	return func(body map[string]any) bool { state, _ := body["state"].(string); return state == want }
}

// waitClosed は、接続が閉じられるのを待ち、Close コードを返す（Close フレームが無い切断は -1）。
func (c *wsClient) waitClosed() int {
	c.t.Helper()
	select {
	case <-c.finished:
	case <-time.After(10 * time.Second):
		c.t.Fatalf("the connection was not closed; received so far: %v", c.describe())
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	var closeErr *websocket.CloseError
	if errors.As(c.closeErr, &closeErr) {
		return closeErr.Code
	}
	return -1
}

// fatals は、受け取った致命通知の符号を、順に返す。
func (c *wsClient) fatals() []string {
	var out []string
	for _, f := range c.ofType(contract.FrameTypeFatal) {
		code, _ := f.json()["code"].(string)
		out = append(out, code)
	}
	return out
}

// ---- 開始通知・メディア ----

const (
	sampleVideoDescription = "AU1AH//hAA9nTUAfllQFAe2AoEA8IhEBAARo7jyA" // 契約 ws-protocol.md の 5.3 の例（AVCDecoderConfigurationRecord）
	sampleAudioDescription = "EhA="                                     // AudioSpecificConfig（AAC-LC・44.1 kHz・2 ch）
)

func startBody(profile string) []byte {
	width, height, bitrate := 1280, 720, 4500
	if profile == "480p" {
		width, height, bitrate = 854, 480, 1500
	}
	return []byte(fmt.Sprintf(
		`{"profile":%q,"video":{"codec":"avc1.4D401F","width":%d,"height":%d,"framerate":30,"bitrate_kbps":%d,"description_b64":%q},`+
			`"audio":{"codec":"mp4a.40.2","sample_rate":44100,"channels":2,"bitrate_kbps":128,"description_b64":%q}}`,
		profile, width, height, bitrate, sampleVideoDescription, sampleAudioDescription))
}

// videoTimeUs・audioTimeUs は、契約（ws-protocol.md の 6 章）どおり、番号から時刻を算出する（整数の四捨五入。差分の積み上げをしない）。
func videoTimeUs(frameNumber int) uint64 { return roundDiv(uint64(frameNumber)*1_000_000, 30) }

func audioTimeUs(frameNumber int) uint64 {
	return roundDiv(uint64(frameNumber)*1024*1_000_000, 44100)
}

func roundDiv(numerator, denominator uint64) uint64 {
	return (2*numerator + denominator) / (2 * denominator)
}

// videoPayload は、AVCC の NAL 列の形（4 バイトの長さ + 中身）の映像データ。中身は、番号で変える（取り違えを検知する）。
func videoPayload(frameNumber, size int) []byte {
	payload := make([]byte, size)
	binary.BigEndian.PutUint32(payload, uint32(size-4))
	for i := 4; i < size; i++ {
		payload[i] = byte(frameNumber + i)
	}
	return payload
}

func audioPayload(frameNumber, size int) []byte {
	payload := make([]byte, size)
	for i := range payload {
		payload[i] = byte(frameNumber*3 + i)
	}
	return payload
}

// ---- 配信 1 本（送出中） ----

// live は、送出中の配信 1 本（WebSocket の接続・RTMPS の受け口の接続・メディアの送り方の状態）。
type live struct {
	env      *relayEnv
	client   *wsClient
	bid      string
	account  int
	key      string
	peer     *rtmpPeer
	originUs uint64 // この接続のメディアクロックの起点（ブラウザのクロックは、0 から始まるとは限らない）

	videoSent, audioSent int
}

// prepareBroadcast は、新規の配信を、準備と RTMPS の接続まで進める（時計は進めない）。
// ticket → hello → accepted → start → status(awaiting_media) → 受け口の接続と設定のタグ（メタデータ・映像設定・音声設定）。
func (e *relayEnv) prepareBroadcast(n int) *live {
	e.t.Helper()
	l := &live{env: e, bid: broadcastID(n), account: n, key: streamKeyOf(broadcastID(n)), originUs: 7_000_000}
	ticket := fmt.Sprintf("dummy-ticket-%d-SECRET", n)
	e.app.addTicket(ticket, l.bid, "reserved", accountKey(n))
	l.client = e.dial()
	l.client.hello(ticket)
	l.client.waitFor(contract.FrameTypeAccepted, nil)
	l.client.send(contract.FrameTypeStart, false, 0, startBody("720p"))
	l.client.waitFor(contract.FrameTypeStatus, statusIs("awaiting_media"))
	eventually(e.t, "the relay connected to the RTMP receiver", func() bool { return e.rtmp.peerByKey(l.key) != nil })
	l.peer = e.rtmp.peerByKey(l.key)
	eventually(e.t, "the metadata and both decoder configurations arrived", func() bool { return l.peer.count() >= 3 })
	// アプリケーションは、ライブになったことを、最初の心拍の応答で伝える（本番の流れ）。この通知がブラウザへ転送されたことは、
	// 最初の心拍の応答が処理され終わった印（以後、時計を進めると、次の心拍が確実に送られる）
	e.app.queueNotice(l.bid, map[string]any{"state": "live", "watch_url": watchURL, "warning": nil, "time_limit_notice_seconds": nil, "end_reason": nil})
	return l
}

// confirmBroadcast は、確認の窓（5 秒）が過ぎたあとの、status(confirming)・publish_started を待つ（時計は、呼び出し側が進めておく）。
func (e *relayEnv) confirmBroadcast(l *live) {
	e.t.Helper()
	l.client.waitFor(contract.FrameTypeStatus, statusIs("confirming"))
	l.client.waitFor(contract.FrameTypeStatus, statusIs("live"))
	eventually(e.t, "publish_started was reported", func() bool { return contains(e.app.eventKinds(l.bid), "publish_started") })
}

// startBroadcast は、新規の配信を、送出（status(confirming) を受け、映像・音声を送れる状態）まで進める。
// 準備 → 確認の窓（5 秒）→ status(confirming)・publish_started。複数の配信を同時に始めるときは、時計を進める前に、
// すべての配信を prepareBroadcast しておく（時計を進めるたびに、映像・音声の途絶の監視 5 秒が進む）。
func (e *relayEnv) startBroadcast(n int) *live {
	e.t.Helper()
	l := e.prepareBroadcast(n)
	e.clock.Advance(session.DefaultOptions().PublishConfirmWindow)
	e.confirmBroadcast(l)
	return l
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

// sendMedia は、映像 videoFrames 枚と、それに当たる長さの音声を送る（映像 30 fps、音声は 1024 サンプルごとの AAC のフレーム）。
// 最初のフレーム（映像の番号 0）は、キーフレーム。以後、30 枚ごとにキーフレーム。送ったあと、受け口にすべて届くのを待つ。
func (l *live) sendMedia(videoFrames int) {
	l.env.t.Helper()
	l.pushMedia(videoFrames)
	l.waitDelivered()
}

// pushMedia は、映像・音声を送る（届くのは待たない）。映像を先に、同じ時刻までの音声を続けて送る
// （復帰では、キーフレームが来るまで音声を破棄するので、映像のキーフレームを先に送る）。
func (l *live) pushMedia(videoFrames int) {
	l.env.t.Helper()
	for i := 0; i < videoFrames; i++ {
		number := l.videoSent
		timestamp := l.originUs + videoTimeUs(number)
		size := 300
		if number%30 == 0 {
			size = 2000
		}
		l.client.send(contract.FrameTypeVideo, number%30 == 0, timestamp, videoPayload(number, size))
		l.videoSent++
		for l.audioSent == 0 || l.originUs+audioTimeUs(l.audioSent) <= timestamp {
			l.client.send(contract.FrameTypeAudio, false, l.originUs+audioTimeUs(l.audioSent), audioPayload(l.audioSent, 40))
			l.audioSent++
		}
	}
}

// waitDelivered は、これまでに送ったすべてが、受け口に届くのを待つ（設定の 3 つ + 映像 + 音声）。
func (l *live) waitDelivered() {
	l.env.t.Helper()
	want := 3 + l.videoSent + l.audioSent
	eventually(l.env.t, fmt.Sprintf("all %d tags reached the RTMP receiver (now %d)", want, l.peer.count()), func() bool { return l.peer.count() >= want })
}

// waitAcked は、これまでに送ったすべてのフレームを示す受領応答が届くまで、時計を 0.5 秒ずつ進める（最大 8 回）。
// 送ったフレームが取り込みセッションに処理される前に時計を進めると、古い値の受領応答になるので、値が最新になるまで待つ。
func (l *live) waitAcked() {
	l.env.t.Helper()
	l.waitAckedAt(l.lastVideoUs(), l.lastAudioUs())
}

// waitAckedAt は、waitAcked と同じだが、最新のメディア時刻を指定する（pushMedia を通さずに送ったフレームがあるとき）。
func (l *live) waitAckedAt(wantVideo, wantAudio uint64) {
	l.env.t.Helper()
	for round := 0; round < 10; round++ {
		l.env.clock.Advance(500 * time.Millisecond)
		_, found := l.client.tryWaitFor(contract.FrameTypeAck, func(body map[string]any) bool {
			return uint64(intOf(l.env.t, body["video_us"])) == wantVideo && uint64(intOf(l.env.t, body["audio_us"])) == wantAudio
		}, 100*time.Millisecond)
		if found {
			return
		}
	}
	l.env.t.Fatalf("no ack with video_us %d and audio_us %d arrived", wantVideo, wantAudio)
}

// lastVideoUs・lastAudioUs は、これまでに送った、最新のメディア時刻（受領応答の値と比べる）。
func (l *live) lastVideoUs() uint64 { return l.originUs + videoTimeUs(l.videoSent-1) }
func (l *live) lastAudioUs() uint64 { return l.originUs + audioTimeUs(l.audioSent-1) }
