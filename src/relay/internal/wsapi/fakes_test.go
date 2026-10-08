package wsapi

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/frame"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/session"
)

// 単体の試験の疑似の境界（時計・WebSocket の接続・セッションの接続）。時計は注入し、実時間を待たない。

// ---- 時計 ----

type fakeClock struct {
	mu     sync.Mutex
	now    time.Time
	timers map[*fakeTimer]struct{}
}

type fakeTimer struct {
	clock  *fakeClock
	when   time.Time
	fn     func()
	active bool
}

func newFakeClock() *fakeClock {
	return &fakeClock{now: time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC), timers: map[*fakeTimer]struct{}{}}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) AfterFunc(d time.Duration, f func()) session.Timer {
	c.mu.Lock()
	defer c.mu.Unlock()
	timer := &fakeTimer{clock: c, when: c.now.Add(d), fn: f, active: true}
	c.timers[timer] = struct{}{}
	return timer
}

// Advance は、時刻を d 進めてから、期限の来たタイマーを、期限の順に（呼び出し元のゴルーチンで）鳴らす。
// 時刻を先に最後まで進める（鳴らされた側が読む時刻が、いつも進めたあとの値になり、試験が決定的になる）。
func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	var due []*fakeTimer
	for timer := range c.timers {
		if timer.active && !timer.when.After(c.now) {
			timer.active = false
			delete(c.timers, timer)
			due = append(due, timer)
		}
	}
	c.mu.Unlock()
	sort.Slice(due, func(i, j int) bool { return due[i].when.Before(due[j].when) })
	for _, timer := range due {
		timer.fn()
	}
}

func (c *fakeClock) activeTimers() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.timers)
}

func (t *fakeTimer) Stop() bool {
	t.clock.mu.Lock()
	defer t.clock.mu.Unlock()
	was := t.active
	t.active = false
	delete(t.clock.timers, t)
	return was
}

func (t *fakeTimer) Reset(d time.Duration) bool {
	t.clock.mu.Lock()
	defer t.clock.mu.Unlock()
	was := t.active
	t.active = true
	t.when = t.clock.now.Add(d)
	t.clock.timers[t] = struct{}{}
	return was
}

// ---- 試験用の構成 ----

// testOptions は、試験用の設定（時計を注入し、ログは捨てる）。
func testOptions(clock session.Clock) Options {
	return Options{Clock: clock, Logger: slog.New(slog.DiscardHandler)}
}

// ---- WebSocket の接続（疑似） ----

var errFakeClosed = errors.New("fake socket: closed")

// fakeSocket は、link が使う接続の疑似。書き込みを記録し、止めたり、失敗させたりできる。
type fakeSocket struct {
	mu        sync.Mutex
	events    []string // "binary"・"ping"・"close:<コード>"・"closewrite"・"closed"
	binaries  [][]byte
	pings     int
	closes    []int
	closed    bool
	closedCh  chan struct{}
	closeOnce sync.Once

	gate         chan struct{} // 非 nil なら、書き込みは、1 回ごとに gate への送信か Close を待つ
	writeEntered chan struct{} // 書き込みが始まるたびに送る
	writeErr     error
	panicOnWrite bool
	closeWriteN  int
}

func newFakeSocket() *fakeSocket {
	return &fakeSocket{closedCh: make(chan struct{}), writeEntered: make(chan struct{}, 4096)}
}

// stallWrites は、以後の書き込みを、releaseOne が呼ばれるまで止める。
func (s *fakeSocket) stallWrites() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.gate = make(chan struct{})
}

// releaseOne は、止まっている書き込みを 1 つ進める。
func (s *fakeSocket) releaseOne() {
	s.mu.Lock()
	gate := s.gate
	s.mu.Unlock()
	select {
	case gate <- struct{}{}:
	case <-s.closedCh:
	}
}

// resumeWrites は、止めるのをやめる。
func (s *fakeSocket) resumeWrites() {
	s.mu.Lock()
	gate := s.gate
	s.gate = nil
	s.mu.Unlock()
	if gate != nil {
		close(gate)
	}
}

func (s *fakeSocket) WriteMessage(messageType int, data []byte) error {
	s.mu.Lock()
	gate := s.gate
	closed := s.closed
	failure := s.writeErr
	shouldPanic := s.panicOnWrite
	s.mu.Unlock()
	if shouldPanic {
		panic("fake socket: simulated panic")
	}
	if closed {
		return errFakeClosed
	}
	select {
	case s.writeEntered <- struct{}{}:
	default:
	}
	if gate != nil {
		select {
		case <-gate:
		case <-s.closedCh:
			return errFakeClosed
		}
	}
	if failure != nil {
		return failure
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errFakeClosed
	}
	s.binaries = append(s.binaries, append([]byte(nil), data...))
	s.events = append(s.events, "binary")
	return nil
}

func (s *fakeSocket) WriteControl(messageType int, data []byte, deadline time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errFakeClosed
	}
	switch messageType {
	case 9: // ping
		s.pings++
		s.events = append(s.events, "ping")
	case 8: // close
		code := 0
		if len(data) >= 2 {
			code = int(binary.BigEndian.Uint16(data))
		}
		s.closes = append(s.closes, code)
		s.events = append(s.events, fmt.Sprintf("close:%d", code))
	}
	return nil
}

func (s *fakeSocket) CloseWrite() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closeWriteN++
	s.events = append(s.events, "closewrite")
	return nil
}

func (s *fakeSocket) Close() error {
	s.closeOnce.Do(func() {
		s.mu.Lock()
		s.closed = true
		s.events = append(s.events, "closed")
		s.mu.Unlock()
		close(s.closedCh)
	})
	return nil
}

func (s *fakeSocket) NextReader() (int, io.Reader, error) {
	<-s.closedCh
	return 0, nil, errFakeClosed
}

func (s *fakeSocket) isClosed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closed
}

func (s *fakeSocket) writtenMessages() [][]byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([][]byte(nil), s.binaries...)
}

func (s *fakeSocket) eventLog() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.events...)
}

func (s *fakeSocket) pingCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.pings
}

func (s *fakeSocket) closeCodes() []int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]int(nil), s.closes...)
}

// waitWriteStarted は、書き込みが始まるのを待つ。
func (s *fakeSocket) waitWriteStarted(t testing.TB) {
	t.Helper()
	select {
	case <-s.writeEntered:
	case <-time.After(5 * time.Second):
		t.Fatal("the writer did not start a write")
	}
}

// ---- 制御メッセージ ----

func controlMessage(t testing.TB, kind contract.FrameType, body string) []byte {
	t.Helper()
	message, err := frame.EncodeControl(kind, []byte(body))
	if err != nil {
		t.Fatalf("EncodeControl: %v", err)
	}
	return message
}

func statusMessage(t testing.TB, state string) []byte {
	t.Helper()
	return controlMessage(t, contract.FrameTypeStatus, `{"state":"`+state+`"}`)
}

func ackMessage(t testing.TB, videoUs, audioUs int) []byte {
	t.Helper()
	return controlMessage(t, contract.FrameTypeAck, fmt.Sprintf(`{"video_us":%d,"audio_us":%d}`, videoUs, audioUs))
}

func throttleMessage(t testing.TB, kbps int) []byte {
	t.Helper()
	return controlMessage(t, contract.FrameTypeThrottle, fmt.Sprintf(`{"target_kbps":%d}`, kbps))
}

func fatalMessage(t testing.TB, code string) []byte {
	t.Helper()
	return controlMessage(t, contract.FrameTypeFatal, `{"code":"`+code+`"}`)
}

// describeMessage は、制御メッセージを、短い文字列にする（順序の確認用）。
func describeMessage(message []byte) string {
	if len(message) < contract.WSFrameHeaderBytes {
		return "short"
	}
	body := string(message[contract.WSFrameHeaderBytes:])
	switch contract.FrameType(message[contract.WSFrameHeaderFieldsTypeOffset]) {
	case contract.FrameTypeAck:
		return "ack" + body
	case contract.FrameTypeThrottle:
		return "throttle" + body
	case contract.FrameTypeStatus:
		return "status" + body
	case contract.FrameTypeFatal:
		return "fatal" + body
	case contract.FrameTypeAccepted:
		return "accepted"
	case contract.FrameTypeKeyframeRequest:
		return "keyframe_request"
	case contract.FrameTypeProbeResult:
		return "probe_result"
	}
	return fmt.Sprintf("type:%#x", message[contract.WSFrameHeaderFieldsTypeOffset])
}

func describeAll(messages [][]byte) []string {
	out := make([]string, 0, len(messages))
	for _, message := range messages {
		out = append(out, describeMessage(message))
	}
	return out
}

// ---- セッションの接続（疑似） ----

// fakeConn は、wsapi.Connection の疑似。受け取ったものを記録し、挙動を差し替えられる。
type fakeConn struct {
	mu          sync.Mutex
	link        session.BrowserLink
	messages    [][]byte
	texts       int
	oversizes   int
	disconnects int
	onMessage   func(n int, message []byte)
	onText      func()
	onOversize  func()
	panicOnData bool
}

func (c *fakeConn) Handle(message []byte) {
	c.mu.Lock()
	c.messages = append(c.messages, message)
	n := len(c.messages)
	hook := c.onMessage
	shouldPanic := c.panicOnData
	c.mu.Unlock()
	if shouldPanic {
		panic("fake connection: simulated panic with a secret-looking value dummy-ticket-SECRET")
	}
	if hook != nil {
		hook(n, message)
	}
}

func (c *fakeConn) HandleText() {
	c.mu.Lock()
	c.texts++
	hook := c.onText
	c.mu.Unlock()
	if hook != nil {
		hook()
	}
}

func (c *fakeConn) HandleOversize() {
	c.mu.Lock()
	c.oversizes++
	hook := c.onOversize
	c.mu.Unlock()
	if hook != nil {
		hook()
	}
}

func (c *fakeConn) Disconnected() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.disconnects++
}

func (c *fakeConn) counts() (messages, texts, oversizes, disconnects int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.messages), c.texts, c.oversizes, c.disconnects
}

func (c *fakeConn) received() [][]byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([][]byte(nil), c.messages...)
}

func (c *fakeConn) sessionLink() session.BrowserLink {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.link
}

// fakeAcceptor は、Acceptor の疑似。接続ごとに fakeConn を作る。
type fakeAcceptor struct {
	mu     sync.Mutex
	conns  []*fakeConn
	err    error
	setup  func(c *fakeConn)
	accept chan *fakeConn
}

func newFakeAcceptor() *fakeAcceptor {
	return &fakeAcceptor{accept: make(chan *fakeConn, 1024)}
}

func (a *fakeAcceptor) Accept(link session.BrowserLink) (Connection, error) {
	a.mu.Lock()
	err := a.err
	setup := a.setup
	a.mu.Unlock()
	if err != nil {
		return nil, err
	}
	conn := &fakeConn{link: link}
	if setup != nil {
		setup(conn)
	}
	a.mu.Lock()
	a.conns = append(a.conns, conn)
	a.mu.Unlock()
	a.accept <- conn
	return conn, nil
}

func (a *fakeAcceptor) failWith(err error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.err = err
}

// nextConn は、次に受け付けた接続を返す（来るまで待つ）。
func (a *fakeAcceptor) nextConn(t testing.TB) *fakeConn {
	t.Helper()
	select {
	case conn := <-a.accept:
		return conn
	case <-time.After(5 * time.Second):
		t.Fatal("no connection was accepted")
		return nil
	}
}

// ---- ログ ----

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

// ---- 待つ ----

// eventually は、条件が満たされるのを、実時間で最大 5 秒待つ（非同期の結果を待つ。時計は進めない）。
func eventually(t testing.TB, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for: %s", what)
		}
		runtime.Gosched()
		time.Sleep(time.Millisecond)
	}
}

// ---- メモリ ----

// runtimeMemory は、確保した量の累計（バイト）の読み取り。
type runtimeMemory struct{ totalAlloc uint64 }

func (m *runtimeMemory) read() {
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	m.totalAlloc = stats.TotalAlloc
}

// ---- ゴルーチンの残り ----

// ownSourcePattern は、このパッケージ（と、結線した層）の、本番のソースのファイルを指すスタックの行（_test.go は除く）。
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

// leftoverGoroutines は、このパッケージ（と、結線した層）の本番のコードで動いているゴルーチン。試験のコードの中だけで
// 動いているもの（_test.go のファイルの行だけのスタック）は、数えない。
func leftoverGoroutines() []string {
	var found []string
	for _, block := range goroutineBlocks() {
		if strings.Contains(block, "leftoverGoroutines") {
			continue // 検査している自分
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

// assertNoLeftoverGoroutines は、閉じたあとに、ゴルーチンが残らないことを確かめる（終わるのを最大 10 秒待つ）。
func assertNoLeftoverGoroutines(t testing.TB) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		found := leftoverGoroutines()
		if len(found) == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("goroutines remain:\n%s", strings.Join(found, "\n---\n"))
		}
		runtime.Gosched()
		time.Sleep(time.Millisecond)
	}
}
