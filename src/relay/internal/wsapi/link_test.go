package wsapi

import (
	"bytes"
	"errors"
	"fmt"
	"log/slog"
	"reflect"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/session"
)

// link（session.BrowserLink の実装）の単体の試験。接続は疑似（書き込みを止める・失敗させる・記録する）、時計は注入する。

func newTestLink(t *testing.T, mutate ...func(*Options)) (*link, *fakeSocket, *fakeClock) {
	t.Helper()
	clock := newFakeClock()
	sock := newFakeSocket()
	opts := testOptions(clock)
	for _, m := range mutate {
		m(&opts)
	}
	normalized, err := opts.normalized()
	if err != nil {
		t.Fatalf("normalized: %v", err)
	}
	l := newLink(sock, clock, normalized, normalized.Logger)
	t.Cleanup(func() {
		l.finish()
		assertNoLeftoverGoroutines(t)
	})
	return l, sock, clock
}

// quietLiveness は、ping と無通信の監視を、試験の間は鳴らない長さにする（別の挙動を調べる試験で、邪魔にならないように）。
func quietLiveness(o *Options) {
	o.PingInterval = 24 * time.Hour
	o.IdleTimeout = 48 * time.Hour
}

func TestLinkSatisfiesTheSessionInterface(t *testing.T) {
	var _ session.BrowserLink = (*link)(nil)
}

func TestSendWritesBinaryMessagesInOrder(t *testing.T) {
	l, sock, _ := newTestLink(t, quietLiveness)
	want := [][]byte{
		controlMessage(t, contract.FrameTypeAccepted, `{"state":"reserved"}`),
		statusMessage(t, "awaiting_media"),
		controlMessage(t, contract.FrameTypeKeyframeRequest, ""),
		controlMessage(t, contract.FrameTypeProbeResult, `{"throughput_kbps":5200}`),
		statusMessage(t, "confirming"),
	}
	for _, message := range want {
		if err := l.Send(message); err != nil {
			t.Fatalf("Send() error = %v; want nil", err)
		}
	}
	eventually(t, "all messages written", func() bool { return len(sock.writtenMessages()) == len(want) })
	got := sock.writtenMessages()
	for i := range want {
		if !bytes.Equal(got[i], want[i]) {
			t.Errorf("message %d = %s; want %s", i, describeMessage(got[i]), describeMessage(want[i]))
		}
	}
}

func TestSendCopiesTheMessage(t *testing.T) {
	l, sock, _ := newTestLink(t, quietLiveness)
	sock.stallWrites()
	first := statusMessage(t, "first")
	if err := l.Send(first); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	sock.waitWriteStarted(t)
	message := statusMessage(t, "second")
	original := append([]byte(nil), message...)
	if err := l.Send(message); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	for i := range message { // 呼び出し元が、送ったあとで書き換えても、送る内容は変わらない
		message[i] = 0
	}
	sock.resumeWrites()
	eventually(t, "both written", func() bool { return len(sock.writtenMessages()) == 2 })
	if got := sock.writtenMessages()[1]; !bytes.Equal(got, original) {
		t.Fatalf("written message = %q; want the content at the time of Send (%q)", got, original)
	}
}

func TestAckAndThrottleAreSentAheadOfQueuedMessagesAndOnlyTheLatestIsKept(t *testing.T) {
	l, sock, _ := newTestLink(t, quietLiveness)
	sock.stallWrites()
	if err := l.Send(statusMessage(t, "first")); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	sock.waitWriteStarted(t) // 書き込み役は、最初の書き込みの中で止まっている
	for _, state := range []string{"second", "third"} {
		if err := l.Send(statusMessage(t, state)); err != nil {
			t.Fatalf("Send() error = %v", err)
		}
	}
	for i := 1; i <= 100; i++ { // 遅いブラウザの間に、受領応答と抑制指示が積み重なっても、最新の 1 つだけを残す
		if err := l.Send(ackMessage(t, i, i*2)); err != nil {
			t.Fatalf("Send(ack) error = %v", err)
		}
		if err := l.Send(throttleMessage(t, 1000+i)); err != nil {
			t.Fatalf("Send(throttle) error = %v", err)
		}
	}
	sock.resumeWrites()
	eventually(t, "five messages written", func() bool { return len(sock.writtenMessages()) == 5 })
	// 受領応答を先に（優先）。ただし、待っている重要なメッセージも、受領応答と交互に進む（飢えさせない）
	want := []string{
		`status{"state":"first"}`,
		`ack{"video_us":100,"audio_us":200}`,
		`status{"state":"second"}`,
		`throttle{"target_kbps":1100}`,
		`status{"state":"third"}`,
	}
	if got := describeAll(sock.writtenMessages()); !reflect.DeepEqual(got, want) {
		t.Fatalf("written = %q\nwant      %q", got, want)
	}
}

func TestFatalIsWrittenBeforeTheCloseFrameAndTheWriteSideIsShutAfterwards(t *testing.T) {
	l, sock, clock := newTestLink(t)
	if err := l.Send(fatalMessage(t, "message_too_large")); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	l.Close(session.CloseMessageTooBig)
	eventually(t, "the write side was shut", func() bool { return len(sock.eventLog()) >= 3 })
	if got, want := sock.eventLog(), []string{"binary", "close:1009", "closewrite"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("socket events = %v; want %v", got, want)
	}
	if got := describeAll(sock.writtenMessages()); !reflect.DeepEqual(got, []string{`fatal{"code":"message_too_large"}`}) {
		t.Fatalf("written = %q", got)
	}
	if sock.isClosed() {
		t.Fatal("the socket was closed at once; want it kept open so that the peer can finish the close handshake")
	}
	// 相手が閉じるのを待つ間は、ping を止め、待つ期限のタイマーだけが動く
	if n := clock.activeTimers(); n != 1 {
		t.Fatalf("%d timers are active while waiting for the peer to close; want only the linger timer", n)
	}
}

func TestCloseIsIdempotentAndOnlyTheFirstCodeIsSent(t *testing.T) {
	l, sock, _ := newTestLink(t, quietLiveness)
	l.Close(session.CloseNormal)
	l.Close(session.CloseMessageTooBig)
	l.Close(session.CloseNormal)
	eventually(t, "close frame", func() bool { return len(sock.closeCodes()) >= 1 })
	time.Sleep(20 * time.Millisecond)
	if got := sock.closeCodes(); !reflect.DeepEqual(got, []int{1000}) {
		t.Fatalf("close codes = %v; want exactly [1000]", got)
	}
}

func TestSendAfterCloseFails(t *testing.T) {
	l, sock, _ := newTestLink(t, quietLiveness)
	if err := l.Send(statusMessage(t, "before")); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	l.Close(session.CloseNormal)
	for _, message := range [][]byte{statusMessage(t, "after"), ackMessage(t, 1, 1), throttleMessage(t, 1)} {
		if err := l.Send(message); !errors.Is(err, session.ErrLinkClosed) {
			t.Errorf("Send() after Close error = %v; want session.ErrLinkClosed", err)
		}
	}
	eventually(t, "close frame", func() bool { return len(sock.closeCodes()) == 1 })
	if got := describeAll(sock.writtenMessages()); !reflect.DeepEqual(got, []string{`status{"state":"before"}`}) {
		t.Fatalf("written = %q; want only the message sent before Close", got)
	}
}

func TestPendingAckAndThrottleAreDroppedWhenClosing(t *testing.T) {
	l, sock, _ := newTestLink(t, quietLiveness)
	sock.stallWrites()
	if err := l.Send(statusMessage(t, "first")); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	sock.waitWriteStarted(t)
	if err := l.Send(ackMessage(t, 5, 5)); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	if err := l.Send(throttleMessage(t, 5)); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	if err := l.Send(fatalMessage(t, "internal_error")); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	l.Close(session.CloseNormal)
	sock.resumeWrites()
	eventually(t, "close frame", func() bool { return len(sock.closeCodes()) == 1 })
	want := []string{`status{"state":"first"}`, `fatal{"code":"internal_error"}`}
	if got := describeAll(sock.writtenMessages()); !reflect.DeepEqual(got, want) {
		t.Fatalf("written = %q; want %q (an ack after a fatal is pointless)", got, want)
	}
}

func TestTheLingerTimeoutClosesTheSocketWhenThePeerDoesNotFinishTheHandshake(t *testing.T) {
	l, sock, clock := newTestLink(t)
	l.Close(session.CloseNormal)
	eventually(t, "the write side was shut", func() bool { return len(sock.eventLog()) >= 2 })
	clock.Advance(l.opts.LingerTimeout - time.Millisecond)
	if sock.isClosed() {
		t.Fatal("the socket was closed before the linger timeout")
	}
	clock.Advance(time.Millisecond)
	eventually(t, "the socket was closed by the linger timeout", sock.isClosed)
}

func TestAStalledWriteDropsTheConnectionAfterTheWriteTimeout(t *testing.T) {
	var logs syncBuffer
	l, sock, clock := newTestLink(t, quietLiveness, func(o *Options) {
		o.Logger = slog.New(slog.NewJSONHandler(&logs, nil))
	})
	sock.stallWrites()
	if err := l.Send(statusMessage(t, "stuck")); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	sock.waitWriteStarted(t)
	clock.Advance(l.opts.WriteTimeout - time.Second)
	if sock.isClosed() {
		t.Fatal("the connection was dropped before the write timeout")
	}
	clock.Advance(time.Second)
	eventually(t, "the connection was dropped", sock.isClosed)
	if err := l.Send(statusMessage(t, "after")); !errors.Is(err, session.ErrLinkClosed) {
		t.Fatalf("Send() after the drop error = %v; want session.ErrLinkClosed", err)
	}
	if !strings.Contains(logs.String(), "write_timeout") {
		t.Errorf("the drop was not logged with its reason: %s", logs.String())
	}
}

func TestOnlyThePingTimerRunsWhileTheWriterIsIdle(t *testing.T) {
	l, sock, clock := newTestLink(t)
	for i := 0; i < 10; i++ {
		if err := l.Send(statusMessage(t, fmt.Sprintf("s%d", i))); err != nil {
			t.Fatalf("Send() error = %v", err)
		}
	}
	eventually(t, "all written", func() bool { return len(sock.writtenMessages()) == 10 })
	eventually(t, "the write timer is stopped", func() bool { return clock.activeTimers() == 1 })
}

func TestTheQueueOfImportantMessagesIsBounded(t *testing.T) {
	l, sock, _ := newTestLink(t, quietLiveness, func(o *Options) { o.SendQueueLimit = 4 })
	sock.stallWrites()
	if err := l.Send(statusMessage(t, "in-flight")); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	sock.waitWriteStarted(t)
	for i := 1; i <= 4; i++ {
		if err := l.Send(statusMessage(t, fmt.Sprintf("queued-%d", i))); err != nil {
			t.Fatalf("Send(%d) error = %v; want nil while the queue has room", i, err)
		}
	}
	if err := l.Send(statusMessage(t, "overflow")); !errors.Is(err, session.ErrLinkClosed) {
		t.Fatalf("Send() beyond the limit error = %v; want session.ErrLinkClosed", err)
	}
	eventually(t, "the slow connection was dropped", sock.isClosed)
	if err := l.Send(ackMessage(t, 1, 1)); !errors.Is(err, session.ErrLinkClosed) {
		t.Fatalf("Send() after the drop error = %v; want session.ErrLinkClosed", err)
	}
}

func TestAckAndThrottleNeverGrowTheQueue(t *testing.T) {
	l, sock, _ := newTestLink(t, quietLiveness, func(o *Options) { o.SendQueueLimit = 2 })
	sock.stallWrites()
	if err := l.Send(statusMessage(t, "in-flight")); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	sock.waitWriteStarted(t)
	for i := 0; i < 5000; i++ {
		if err := l.Send(ackMessage(t, i, i)); err != nil {
			t.Fatalf("Send(ack %d) error = %v; an ack must replace the previous one, not queue", i, err)
		}
		if err := l.Send(throttleMessage(t, i+1)); err != nil {
			t.Fatalf("Send(throttle %d) error = %v", i, err)
		}
	}
	l.mu.Lock()
	queued := len(l.queued)
	l.mu.Unlock()
	if queued != 0 {
		t.Fatalf("%d messages are queued; want none (the latest ack and throttle occupy their own slots)", queued)
	}
}

func TestPingsAreSentAtTheInterval(t *testing.T) {
	l, sock, clock := newTestLink(t)
	for i := 1; i <= 3; i++ {
		l.touch() // 相手は生きている
		clock.Advance(l.opts.PingInterval)
		eventually(t, fmt.Sprintf("ping %d", i), func() bool { return sock.pingCount() == i })
	}
	if sock.isClosed() {
		t.Fatal("the connection was dropped although the peer was active")
	}
}

func TestASilentPeerIsDroppedWhenTheIdleTimeoutPasses(t *testing.T) {
	var logs syncBuffer
	l, sock, clock := newTestLink(t, func(o *Options) {
		o.Logger = slog.New(slog.NewJSONHandler(&logs, nil))
	})
	// 既定：ping は 5 秒ごと、無通信の期限は 15 秒。5 秒・10 秒の拍で ping を送り、15 秒の拍で切る
	clock.Advance(l.opts.PingInterval)
	eventually(t, "first ping", func() bool { return sock.pingCount() == 1 })
	clock.Advance(l.opts.PingInterval)
	eventually(t, "second ping", func() bool { return sock.pingCount() == 2 })
	if sock.isClosed() {
		t.Fatal("the connection was dropped before the idle timeout")
	}
	clock.Advance(l.opts.PingInterval)
	eventually(t, "the silent peer was dropped", sock.isClosed)
	if !strings.Contains(logs.String(), "idle_timeout") {
		t.Errorf("the drop was not logged with its reason: %s", logs.String())
	}
}

func TestInboundTrafficKeepsTheLinkAlive(t *testing.T) {
	l, sock, clock := newTestLink(t)
	for i := 1; i <= 40; i++ { // 200 秒
		l.touch()
		clock.Advance(l.opts.PingInterval)
		eventually(t, fmt.Sprintf("ping %d", i), func() bool { return sock.pingCount() == i })
	}
	if sock.isClosed() {
		t.Fatal("an active connection was dropped")
	}
}

func TestFinishStopsTheWriterTheTimersAndTheSocket(t *testing.T) {
	l, sock, clock := newTestLink(t)
	if err := l.Send(statusMessage(t, "x")); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	l.Close(session.CloseNormal)
	l.finish()
	l.finish() // 何度呼んでもよい
	if !sock.isClosed() {
		t.Error("the socket is still open after finish")
	}
	if n := clock.activeTimers(); n != 0 {
		t.Errorf("%d timers are still active after finish", n)
	}
	if err := l.Send(statusMessage(t, "late")); !errors.Is(err, session.ErrLinkClosed) {
		t.Errorf("Send() after finish error = %v; want session.ErrLinkClosed", err)
	}
	assertNoLeftoverGoroutines(t)
}

func TestAWriteFailureDropsTheLink(t *testing.T) {
	l, sock, _ := newTestLink(t, quietLiveness)
	sock.mu.Lock()
	sock.writeErr = errors.New("broken pipe")
	sock.mu.Unlock()
	if err := l.Send(statusMessage(t, "x")); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	eventually(t, "the link was dropped", sock.isClosed)
	if err := l.Send(statusMessage(t, "y")); !errors.Is(err, session.ErrLinkClosed) {
		t.Fatalf("Send() after the failure error = %v; want session.ErrLinkClosed", err)
	}
}

// 書き込みのゴルーチンで panic が起きても、中継全体を落とさず、その接続だけを閉じる。ログに panic の値を写さない
func TestAPanicInTheWriterIsContainedAndNotLoggedWithItsValue(t *testing.T) {
	var logs syncBuffer
	l, sock, _ := newTestLink(t, quietLiveness, func(o *Options) {
		o.Logger = slog.New(slog.NewJSONHandler(&logs, nil))
	})
	sock.mu.Lock()
	sock.panicOnWrite = true
	sock.mu.Unlock()
	if err := l.Send(statusMessage(t, "x")); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	eventually(t, "the link was dropped", sock.isClosed)
	if err := l.Send(statusMessage(t, "y")); !errors.Is(err, session.ErrLinkClosed) {
		t.Fatalf("Send() after the panic error = %v; want session.ErrLinkClosed", err)
	}
	text := logs.String()
	if !strings.Contains(text, "panic") {
		t.Errorf("the panic was not logged: %s", text)
	}
	if strings.Contains(text, "simulated") {
		t.Errorf("the panic value was copied into the log: %s", text)
	}
}

func TestSendAndCloseAreSafeToCallConcurrently(t *testing.T) {
	l, sock, _ := newTestLink(t, quietLiveness, func(o *Options) { o.SendQueueLimit = 1 << 20 })
	statusMsg := statusMessage(t, "x")
	ack := ackMessage(t, 1, 1)
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 300; i++ {
				_ = l.Send(ack)
				_ = l.Send(statusMsg)
				runtime.Gosched()
			}
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		time.Sleep(2 * time.Millisecond)
		l.Close(session.CloseNormal)
		l.Close(session.CloseMessageTooBig)
	}()
	wg.Wait()
	eventually(t, "one close frame", func() bool { return len(sock.closeCodes()) == 1 })
	if got := sock.closeCodes(); !reflect.DeepEqual(got, []int{1000}) {
		t.Fatalf("close codes = %v; want [1000]", got)
	}
}

func TestOnlyAckAndThrottleKeepJustTheLatest(t *testing.T) {
	cases := []struct {
		name     string
		message  []byte
		wantSlot int
		wantOK   bool
	}{
		{"ack", ackMessage(t, 1, 1), slotAck, true},
		{"throttle", throttleMessage(t, 1), slotThrottle, true},
		{"status", statusMessage(t, "live"), 0, false},
		{"fatal", fatalMessage(t, "internal_error"), 0, false},
		{"accepted", controlMessage(t, contract.FrameTypeAccepted, `{}`), 0, false},
		{"probe_result", controlMessage(t, contract.FrameTypeProbeResult, `{}`), 0, false},
		{"keyframe_request", controlMessage(t, contract.FrameTypeKeyframeRequest, ""), 0, false},
		{"短すぎて種別が読めない", []byte{0x42, 0x4C}, 0, false},
		{"空", nil, 0, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			slot, ok := latestSlotOf(c.message)
			if ok != c.wantOK || (ok && slot != c.wantSlot) {
				t.Fatalf("latestSlotOf() = (%d, %t); want (%d, %t)", slot, ok, c.wantSlot, c.wantOK)
			}
		})
	}
}

// 書式化しても、メッセージの中身（待ち行列）を出さない
func TestFormattingTheLinkShowsNoMessages(t *testing.T) {
	l, sock, _ := newTestLink(t, quietLiveness)
	sock.stallWrites()
	if err := l.Send(statusMessage(t, "SECRET-looking-state")); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	sock.waitWriteStarted(t)
	if err := l.Send(statusMessage(t, "SECRET-queued-state")); err != nil {
		t.Fatalf("Send() error = %v", err)
	}
	for _, verb := range []string{"%v", "%+v", "%#v", "%s"} {
		if text := fmt.Sprintf(verb, l); strings.Contains(text, "SECRET") {
			t.Errorf("%s of the link shows a message: %s", verb, text)
		}
	}
	sock.resumeWrites()
}
