package wsapi

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/session"
)

// Handler（GET /ws）の試験。実際の WebSocket のクライアント（gorilla）と、疑似のセッションの接続・時計を使う。

type handlerEnv struct {
	clock    *fakeClock
	acceptor *fakeAcceptor
	handler  *Handler
	server   *httptest.Server
	logs     *syncBuffer
}

func newHandlerEnv(t *testing.T, mutate ...func(*Options)) *handlerEnv {
	t.Helper()
	logs := &syncBuffer{}
	clock := newFakeClock()
	opts := Options{Clock: clock, Logger: slog.New(slog.NewJSONHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug}))}
	for _, m := range mutate {
		m(&opts)
	}
	acceptor := newFakeAcceptor()
	handler, err := NewHandler(acceptor, opts)
	if err != nil {
		t.Fatalf("NewHandler: %v", err)
	}
	server := httptest.NewServer(handler)
	env := &handlerEnv{clock: clock, acceptor: acceptor, handler: handler, server: server, logs: logs}
	// 登録の逆順に実行される：残っている接続を閉じる → サーバーを止める → ゴルーチンの残りを調べる
	t.Cleanup(func() { assertNoLeftoverGoroutines(t) })
	t.Cleanup(server.Close)
	t.Cleanup(func() {
		handler.BeginDrain()
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = handler.Wait(ctx)
	})
	t.Cleanup(func() {
		if t.Failed() {
			t.Logf("wsapi logs:\n%s", logs.String())
		}
	})
	return env
}

func (e *handlerEnv) url() string { return "ws" + strings.TrimPrefix(e.server.URL, "http") }

func (e *handlerEnv) dial(t *testing.T) *websocket.Conn {
	t.Helper()
	return e.dialWith(t, websocket.DefaultDialer, nil)
}

func (e *handlerEnv) dialWith(t *testing.T, dialer *websocket.Dialer, header http.Header) *websocket.Conn {
	t.Helper()
	conn, response, err := dialer.Dial(e.url(), header)
	if err != nil {
		status := 0
		if response != nil {
			status = response.StatusCode
		}
		t.Fatalf("dial: %v (HTTP status %d)", err, status)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

// readBinary は、サーバーから届く次のメッセージ（バイナリ）を返す。
func readBinary(t *testing.T, conn *websocket.Conn) []byte {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	kind, data, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if kind != websocket.BinaryMessage {
		t.Fatalf("message type = %d; want binary", kind)
	}
	return data
}

// expectCloseCode は、サーバーが Close フレームを送ってくること（コードが want）を確かめる。
func expectCloseCode(t *testing.T, conn *websocket.Conn, want int) {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			var closeErr *websocket.CloseError
			if !errors.As(err, &closeErr) {
				t.Fatalf("read error = %v; want a close frame with code %d", err, want)
			}
			if closeErr.Code != want {
				t.Fatalf("close code = %d; want %d", closeErr.Code, want)
			}
			return
		}
	}
}

// expectGone は、接続が（サーバーに）閉じられていること（読み取りが失敗すること）を確かめる。
func expectGone(t *testing.T, conn *websocket.Conn) {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			return
		}
	}
}

// backgroundReader は、クライアントの読み取りを続ける（ping に pong で答えるには、読み続けている必要がある）。
func backgroundReader(conn *websocket.Conn) {
	go func() {
		for {
			if _, _, err := conn.NextReader(); err != nil {
				return
			}
		}
	}()
}

func TestAnyOriginMayConnect(t *testing.T) {
	// Cookie を使わず、接続チケットで認可するため、接続元の Origin を検査しない（handler.go の CheckOrigin のコメント）
	env := newHandlerEnv(t)
	for _, origin := range []string{"", "https://frontend.example", "https://evil.example", "null", "http://localhost:3000"} {
		t.Run("Origin="+origin, func(t *testing.T) {
			header := http.Header{}
			if origin != "" {
				header.Set("Origin", origin)
			}
			conn, response, err := websocket.DefaultDialer.Dial(env.url(), header)
			if err != nil {
				t.Fatalf("dial with Origin %q: %v", origin, err)
			}
			defer conn.Close()
			if response.StatusCode != http.StatusSwitchingProtocols {
				t.Fatalf("status = %d; want 101", response.StatusCode)
			}
			env.acceptor.nextConn(t)
		})
	}
}

func TestARequestThatIsNotAWebSocketUpgradeIsRefused(t *testing.T) {
	env := newHandlerEnv(t)
	response, err := http.Get(env.server.URL)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d; want 400", response.StatusCode)
	}
	select {
	case <-env.acceptor.accept:
		t.Fatal("a session connection was created for a request that is not a WebSocket upgrade")
	default:
	}
}

func TestBinaryMessagesReachTheSessionUnchangedAndInOrder(t *testing.T) {
	env := newHandlerEnv(t)
	conn := env.dial(t)
	fake := env.acceptor.nextConn(t)
	sizes := []int{0, 1, 17, 1000, 40_000, 300_000}
	var want [][]byte
	for i, size := range sizes {
		message := bytes.Repeat([]byte{byte(i + 1)}, size)
		want = append(want, message)
		if err := conn.WriteMessage(websocket.BinaryMessage, message); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	eventually(t, "all messages handed over", func() bool { n, _, _, _ := fake.counts(); return n == len(sizes) })
	got := fake.received()
	for i := range want {
		if !bytes.Equal(got[i], want[i]) {
			t.Errorf("message %d: got %d bytes, want %d bytes (content must be identical)", i, len(got[i]), len(want[i]))
		}
	}
	if _, texts, oversizes, _ := fake.counts(); texts != 0 || oversizes != 0 {
		t.Errorf("texts = %d, oversizes = %d; want none", texts, oversizes)
	}
}

func TestEachMessageIsHandedOverInItsOwnBuffer(t *testing.T) {
	// 受け取った message の所有は接続に移る（非同期に処理する）。次のメッセージの読み取りが、前のバッファを書き換えない
	env := newHandlerEnv(t)
	conn := env.dial(t)
	fake := env.acceptor.nextConn(t)
	for i := 0; i < 50; i++ {
		if err := conn.WriteMessage(websocket.BinaryMessage, bytes.Repeat([]byte{byte(i)}, 64)); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	eventually(t, "all handed over", func() bool { n, _, _, _ := fake.counts(); return n == 50 })
	for i, message := range fake.received() {
		if !bytes.Equal(message, bytes.Repeat([]byte{byte(i)}, 64)) {
			t.Fatalf("message %d was overwritten after it was handed over", i)
		}
	}
}

func TestTheMessageSizeLimitIsInclusive(t *testing.T) {
	const limit = 1024
	env := newHandlerEnv(t, func(o *Options) { o.MaxMessageBytes = limit })
	conn := env.dial(t)
	fake := env.acceptor.nextConn(t)
	fake.onOversize = func() {
		_ = fake.sessionLink().Send(fatalMessage(t, "message_too_large"))
		fake.sessionLink().Close(session.CloseMessageTooBig)
	}

	if err := conn.WriteMessage(websocket.BinaryMessage, bytes.Repeat([]byte{7}, limit)); err != nil {
		t.Fatalf("write: %v", err)
	}
	eventually(t, "the message at the limit was handed over", func() bool { n, _, _, _ := fake.counts(); return n == 1 })
	if _, _, oversizes, _ := fake.counts(); oversizes != 0 {
		t.Fatalf("oversizes = %d after a message exactly at the limit; want 0", oversizes)
	}

	if err := conn.WriteMessage(websocket.BinaryMessage, bytes.Repeat([]byte{8}, limit+1)); err != nil {
		t.Fatalf("write: %v", err)
	}
	eventually(t, "oversize was reported", func() bool { _, _, oversizes, _ := fake.counts(); return oversizes == 1 })
	if n, _, _, _ := fake.counts(); n != 1 {
		t.Fatalf("%d messages were handed over; want only the one within the limit", n)
	}
}

// 2 MB 超は、本文を読み切る前に（上限 + 1 バイトを読んだ時点で）切る。fatal(message_too_large) を先に送り、Close コード 1009 で閉じる
func TestAnOversizeMessageIsReportedBeforeItIsFullyReceivedAndTheFatalComesFirst(t *testing.T) {
	const limit = 1024
	env := newHandlerEnv(t, func(o *Options) { o.MaxMessageBytes = limit })
	fatal := fatalMessage(t, "message_too_large")
	env.acceptor.setup = func(c *fakeConn) {
		c.onOversize = func() {
			_ = c.sessionLink().Send(fatal)
			c.sessionLink().Close(session.CloseMessageTooBig)
		}
	}
	// 書き込みの緩衝を小さくして、フレームを細かく送る。メッセージは、終わらせない（最後のフレームを送らない）
	dialer := &websocket.Dialer{WriteBufferSize: 512}
	conn := env.dialWith(t, dialer, nil)
	fake := env.acceptor.nextConn(t)

	writer, err := conn.NextWriter(websocket.BinaryMessage)
	if err != nil {
		t.Fatalf("NextWriter: %v", err)
	}
	if _, err := writer.Write(make([]byte, 4*limit)); err != nil {
		t.Fatalf("write: %v", err)
	}
	// （writer.Close は呼ばない。サーバーは、メッセージの終わりを待たずに、超過を判定する）
	eventually(t, "oversize was reported", func() bool { _, _, oversizes, _ := fake.counts(); return oversizes == 1 })

	got := readBinary(t, conn)
	if !bytes.Equal(got, fatal) {
		t.Fatalf("first message = %s; want the fatal", describeMessage(got))
	}
	expectCloseCode(t, conn, 1009)
	eventually(t, "disconnected", func() bool { _, _, _, d := fake.counts(); return d == 1 })
	if n, _, _, _ := fake.counts(); n != 0 {
		t.Errorf("%d messages were handed over; want none", n)
	}
}

func TestATextMessageIsReportedAndNeverHandedOverAsData(t *testing.T) {
	env := newHandlerEnv(t)
	fatal := fatalMessage(t, "protocol_violation")
	env.acceptor.setup = func(c *fakeConn) {
		c.onText = func() {
			_ = c.sessionLink().Send(fatal)
			c.sessionLink().Close(session.CloseNormal)
		}
	}
	conn := env.dial(t)
	fake := env.acceptor.nextConn(t)
	if err := conn.WriteMessage(websocket.TextMessage, []byte("hello")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if got := readBinary(t, conn); !bytes.Equal(got, fatal) {
		t.Fatalf("first message = %s; want the fatal", describeMessage(got))
	}
	expectCloseCode(t, conn, 1000)
	eventually(t, "disconnected", func() bool { _, _, _, d := fake.counts(); return d == 1 })
	if n, texts, _, _ := fake.counts(); n != 0 || texts != 1 {
		t.Errorf("messages = %d, texts = %d; want 0 and 1", n, texts)
	}
}

func TestMessagesAfterTheLinkStartedClosingAreNotHandedOver(t *testing.T) {
	env := newHandlerEnv(t)
	env.acceptor.setup = func(c *fakeConn) {
		c.onMessage = func(n int, _ []byte) {
			if n == 1 {
				c.sessionLink().Close(session.CloseNormal)
			}
		}
	}
	conn := env.dial(t)
	fake := env.acceptor.nextConn(t)
	if err := conn.WriteMessage(websocket.BinaryMessage, []byte("first")); err != nil {
		t.Fatalf("write: %v", err)
	}
	// 閉じ始めたあとに届くメッセージ（相手が Close フレームに答えるまでの間）は、セッションへ渡さない
	eventually(t, "the link is closing", func() bool { return fake.sessionLink().(*link).closing() })
	for i := 0; i < 5; i++ {
		if err := conn.WriteMessage(websocket.BinaryMessage, []byte("late")); err != nil {
			break
		}
	}
	expectCloseCode(t, conn, 1000)
	eventually(t, "disconnected", func() bool { _, _, _, d := fake.counts(); return d == 1 })
	if n, _, _, _ := fake.counts(); n != 1 {
		t.Fatalf("%d messages were handed over; want only the first", n)
	}
}

func TestACleanCloseByThePeerNotifiesTheSessionOnce(t *testing.T) {
	env := newHandlerEnv(t)
	conn := env.dial(t)
	fake := env.acceptor.nextConn(t)
	if got := env.handler.Active(); got != 1 {
		t.Fatalf("Active() = %d; want 1", got)
	}
	_ = conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), time.Now().Add(time.Second))
	expectGone(t, conn)
	eventually(t, "disconnected", func() bool { _, _, _, d := fake.counts(); return d == 1 })
	eventually(t, "the connection was released", func() bool { return env.handler.Active() == 0 })
}

func TestAnAbruptCloseByThePeerNotifiesTheSessionOnce(t *testing.T) {
	env := newHandlerEnv(t)
	conn := env.dial(t)
	fake := env.acceptor.nextConn(t)
	_ = conn.UnderlyingConn().Close()
	eventually(t, "disconnected", func() bool { _, _, _, d := fake.counts(); return d == 1 })
	eventually(t, "the connection was released", func() bool { return env.handler.Active() == 0 })
	time.Sleep(20 * time.Millisecond)
	if _, _, _, d := fake.counts(); d != 1 {
		t.Fatalf("Disconnected was called %d times; want exactly once", d)
	}
}

func TestMessagesFromTheSessionReachThePeerInOrder(t *testing.T) {
	env := newHandlerEnv(t)
	conn := env.dial(t)
	fake := env.acceptor.nextConn(t)
	link := fake.sessionLink()
	want := [][]byte{
		controlMessage(t, contract.FrameTypeAccepted, `{"state":"reserved","resume":false,"profile":null,"limits":{"time_limit_seconds":3600}}`),
		statusMessage(t, "awaiting_media"),
		statusMessage(t, "confirming"),
		controlMessage(t, contract.FrameTypeKeyframeRequest, ""),
	}
	for _, message := range want {
		if err := link.Send(message); err != nil {
			t.Fatalf("Send: %v", err)
		}
	}
	for i := range want {
		if got := readBinary(t, conn); !bytes.Equal(got, want[i]) {
			t.Fatalf("message %d = %s; want %s", i, describeMessage(got), describeMessage(want[i]))
		}
	}
	link.Close(session.CloseNormal)
	expectCloseCode(t, conn, 1000)
}

func TestTheNumberOfConnectionsIsLimited(t *testing.T) {
	env := newHandlerEnv(t, func(o *Options) { o.MaxConnections = 2 })
	first := env.dial(t)
	env.acceptor.nextConn(t)
	env.dial(t)
	env.acceptor.nextConn(t)

	_, response, err := websocket.DefaultDialer.Dial(env.url(), nil)
	if err == nil {
		t.Fatal("a third connection was accepted; want it refused")
	}
	if response == nil || response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("response = %v; want HTTP 503", response)
	}
	select {
	case <-env.acceptor.accept:
		t.Fatal("a session connection was created for a refused request")
	default:
	}

	_ = first.UnderlyingConn().Close()
	eventually(t, "a slot was released", func() bool { return env.handler.Active() == 1 })
	env.dial(t)
	env.acceptor.nextConn(t)
}

func TestNewConnectionsAreRefusedWhileDrainingAndExistingOnesKeepWorking(t *testing.T) {
	env := newHandlerEnv(t)
	conn := env.dial(t)
	fake := env.acceptor.nextConn(t)

	env.handler.BeginDrain()
	_, response, err := websocket.DefaultDialer.Dial(env.url(), nil)
	if err == nil {
		t.Fatal("a connection was accepted while draining")
	}
	if response == nil || response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("response = %v; want HTTP 503", response)
	}

	if err := conn.WriteMessage(websocket.BinaryMessage, []byte("still-works")); err != nil {
		t.Fatalf("write: %v", err)
	}
	eventually(t, "the existing connection still works", func() bool { n, _, _, _ := fake.counts(); return n == 1 })
}

func TestARefusedSessionConnectionIsClosedAsGoingAway(t *testing.T) {
	env := newHandlerEnv(t)
	env.acceptor.failWith(session.ErrShuttingDown)
	conn := env.dial(t)
	expectCloseCode(t, conn, websocket.CloseGoingAway)
	eventually(t, "the connection was released", func() bool { return env.handler.Active() == 0 })
}

func TestWaitReturnsOnceEveryConnectionHasEnded(t *testing.T) {
	env := newHandlerEnv(t)
	conn := env.dial(t)
	env.acceptor.nextConn(t)
	env.handler.BeginDrain()
	_ = conn.UnderlyingConn().Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := env.handler.Wait(ctx); err != nil {
		t.Fatalf("Wait() error = %v; want nil", err)
	}
	if got := env.handler.Active(); got != 0 {
		t.Fatalf("Active() = %d; want 0", got)
	}
}

func TestWaitClosesTheConnectionsByForceWhenTheContextExpires(t *testing.T) {
	env := newHandlerEnv(t)
	conn := env.dial(t)
	fake := env.acceptor.nextConn(t)
	env.handler.BeginDrain()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	err := env.handler.Wait(ctx)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Wait() error = %v; want context.DeadlineExceeded", err)
	}
	expectGone(t, conn)
	if got := env.handler.Active(); got != 0 {
		t.Fatalf("Active() = %d after the forced close; want 0", got)
	}
	if _, _, _, d := fake.counts(); d != 1 {
		t.Fatalf("Disconnected was called %d times; want once", d)
	}
}

// セッション側の panic は、その接続だけを閉じる。ログに panic の値（秘密値が入り得る）を写さない
func TestAPanicInTheSessionClosesOnlyThatConnectionAndIsNotLoggedWithItsValue(t *testing.T) {
	env := newHandlerEnv(t)
	env.acceptor.setup = func(c *fakeConn) { c.panicOnData = true }
	broken := env.dial(t)
	fake := env.acceptor.nextConn(t)
	if err := broken.WriteMessage(websocket.BinaryMessage, []byte("x")); err != nil {
		t.Fatalf("write: %v", err)
	}
	expectGone(t, broken)
	eventually(t, "disconnected", func() bool { _, _, _, d := fake.counts(); return d == 1 })

	text := env.logs.String()
	if !strings.Contains(text, "panic_type") {
		t.Errorf("the panic was not logged with its type: %s", text)
	}
	for _, leaked := range []string{"dummy-ticket", "SECRET", "simulated"} {
		if strings.Contains(text, leaked) {
			t.Errorf("the log contains %q: %s", leaked, text)
		}
	}

	env.acceptor.setup = nil
	healthy := env.dial(t) // 別の接続は、影響を受けない
	other := env.acceptor.nextConn(t)
	if err := healthy.WriteMessage(websocket.BinaryMessage, []byte("ok")); err != nil {
		t.Fatalf("write: %v", err)
	}
	eventually(t, "the other connection works", func() bool { n, _, _, _ := other.counts(); return n == 1 })
}

// 相手が pong で答える（読み続けている）かぎり、無通信の期限を過ぎても切らない
func TestPongsKeepAnIdleConnectionAlive(t *testing.T) {
	env := newHandlerEnv(t)
	conn := env.dial(t)
	fake := env.acceptor.nextConn(t)
	backgroundReader(conn)
	sessionLink := fake.sessionLink().(*link)
	for i := 0; i < 30; i++ { // 150 秒（無通信の期限 15 秒の 10 倍）
		env.clock.Advance(DefaultPingInterval)
		now := env.clock.Now()
		eventually(t, "the pong was received", func() bool { return sessionLink.lastActivity().Equal(now) })
	}
	if sessionLink.closing() {
		t.Fatal("an idle but responsive connection was dropped")
	}
	if err := conn.WriteMessage(websocket.BinaryMessage, []byte("still alive")); err != nil {
		t.Fatalf("write: %v", err)
	}
	eventually(t, "the message arrived", func() bool { n, _, _, _ := fake.counts(); return n == 1 })
}

// 相手が何も返さない（pong も、データも）接続は、無通信の期限（15 秒）で切る
func TestASilentPeerIsClosedAfterTheIdleTimeout(t *testing.T) {
	env := newHandlerEnv(t)
	conn := env.dial(t)
	fake := env.acceptor.nextConn(t)
	// クライアントは読まない：ping に pong が返らない
	for i := 0; i < 3; i++ {
		env.clock.Advance(DefaultPingInterval)
	}
	eventually(t, "disconnected", func() bool { _, _, _, d := fake.counts(); return d == 1 })
	expectGone(t, conn)
	eventually(t, "the connection was released", func() bool { return env.handler.Active() == 0 })
	if !strings.Contains(env.logs.String(), "idle_timeout") {
		t.Errorf("the drop was not logged with its reason: %s", env.logs.String())
	}
}

func TestTheHandlerShowsNoDetailsWhenFormatted(t *testing.T) {
	env := newHandlerEnv(t)
	env.dial(t)
	env.acceptor.nextConn(t)
	for _, verb := range []string{"%v", "%+v", "%#v", "%s"} {
		text := fmt.Sprintf(verb, env.handler)
		if strings.Contains(text, "127.0.0.1") {
			t.Errorf("%s of the handler shows an address: %s", verb, text)
		}
	}
}

func TestAcceptedCountsEveryConnectionThatReachedTheSessionRegistry(t *testing.T) {
	env := newHandlerEnv(t)
	if got := env.handler.Accepted(); got != 0 {
		t.Fatalf("Accepted() = %d before any connection; want 0", got)
	}
	for i := 1; i <= 3; i++ {
		env.dial(t)
		eventually(t, fmt.Sprintf("connection %d reached the registry", i), func() bool { return env.handler.Accepted() == i })
	}
	// 受け付けられなかった接続（停止の手順）も、台帳まで届いたものとして数える。切り替えに失敗したものは、数えない
	env.acceptor.failWith(session.ErrShuttingDown)
	env.dial(t)
	eventually(t, "the refused connection was counted", func() bool { return env.handler.Accepted() == 4 })
	if response, err := http.Get(env.server.URL); err == nil {
		response.Body.Close()
	}
	time.Sleep(20 * time.Millisecond)
	if got := env.handler.Accepted(); got != 4 {
		t.Fatalf("Accepted() = %d after a request that was not an upgrade; want 4", got)
	}
}

func TestNewHandlerRequiresItsDependencies(t *testing.T) {
	if _, err := NewHandler(nil, testOptions(newFakeClock())); !errors.Is(err, ErrInvalidDeps) {
		t.Errorf("NewHandler(nil acceptor) error = %v; want ErrInvalidDeps", err)
	}
	if _, err := NewHandler(newFakeAcceptor(), Options{}); !errors.Is(err, ErrInvalidDeps) {
		t.Errorf("NewHandler(no clock) error = %v; want ErrInvalidDeps", err)
	}
	if _, err := NewHandler(newFakeAcceptor(), Options{Clock: newFakeClock(), MaxConnections: -1}); !errors.Is(err, ErrInvalidOptions) {
		t.Errorf("NewHandler(bad options) error = %v; want ErrInvalidOptions", err)
	}
}

func TestOnlyGetIsServed(t *testing.T) {
	env := newHandlerEnv(t)
	response, err := http.Post(env.server.URL, "text/plain", strings.NewReader("x"))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d; want 405", response.StatusCode)
	}
}

// 実時間の時計（session.SystemClock）でも、ping・無通信の期限・書き込みの期限のタイマーが動く
// （タイマーを Reset して使い回すので、鳴った後の Reset・Stop が正しく動くことの確認）
func TestPingAndIdleDropWorkWithTheRealClock(t *testing.T) {
	logs := &syncBuffer{}
	acceptor := newFakeAcceptor()
	handler, err := NewHandler(acceptor, Options{
		Clock: session.SystemClock{}, Logger: slog.New(slog.NewJSONHandler(logs, nil)),
		PingInterval: 20 * time.Millisecond, IdleTimeout: 80 * time.Millisecond, WriteTimeout: time.Second, LingerTimeout: 200 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("NewHandler: %v", err)
	}
	server := httptest.NewServer(handler)
	t.Cleanup(func() { assertNoLeftoverGoroutines(t) })
	t.Cleanup(server.Close)
	t.Cleanup(func() {
		handler.BeginDrain()
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = handler.Wait(ctx)
	})
	url := "ws" + strings.TrimPrefix(server.URL, "http")

	// 読み続けるクライアントは、ping に pong で答えるので、無通信の期限（80 ミリ秒）の何倍たっても、切られない
	responsive, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = responsive.Close() })
	backgroundReader(responsive)
	alive := acceptor.nextConn(t)

	// 読まないクライアントは、pong を返せないので、無通信の期限で切られる
	silent, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = silent.Close() })
	dropped := acceptor.nextConn(t)

	eventually(t, "the silent peer was dropped", func() bool { _, _, _, d := dropped.counts(); return d == 1 })
	time.Sleep(400 * time.Millisecond)
	if _, _, _, d := alive.counts(); d != 0 {
		t.Fatalf("the responsive peer was dropped (Disconnected %d times)", d)
	}
	if err := responsive.WriteMessage(websocket.BinaryMessage, []byte("still here")); err != nil {
		t.Fatalf("write: %v", err)
	}
	eventually(t, "the responsive peer still works", func() bool { n, _, _, _ := alive.counts(); return n == 1 })
	if !strings.Contains(logs.String(), "idle_timeout") {
		t.Errorf("the drop was not logged with its reason: %s", logs.String())
	}
}
