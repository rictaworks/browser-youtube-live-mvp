package session

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"runtime"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps"
)

// 外部との境界（Clock・Backend・EventSink・PublisherFactory・BrowserLink）の疑似の実装。
// 時計は注入し、実時間を待たない。実際のアプリケーション・YouTube・ネットワークは使わない。値は明らかなダミー。

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

func (c *fakeClock) AfterFunc(d time.Duration, f func()) Timer {
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
	n := 0
	for timer := range c.timers {
		if timer.active {
			n++
		}
	}
	return n
}

func (t *fakeTimer) Stop() bool {
	t.clock.mu.Lock()
	defer t.clock.mu.Unlock()
	was := t.active
	t.active = false
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

// ---- ブラウザとの接続 ----

type fakeLink struct {
	mu      sync.Mutex
	sent    [][]byte
	order   []string // 送った順に、"send" と "close:<コード>"
	closed  bool
	code    int
	closes  int
	sendErr error
}

func (l *fakeLink) Send(message []byte) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return ErrLinkClosed
	}
	if l.sendErr != nil {
		return l.sendErr
	}
	l.sent = append(l.sent, append([]byte(nil), message...))
	l.order = append(l.order, "send")
	return nil
}

func (l *fakeLink) Close(code int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.closes++
	if l.closed {
		return
	}
	l.closed = true
	l.code = code
	l.order = append(l.order, fmt.Sprintf("close:%d", code))
}

func (l *fakeLink) isClosed() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.closed
}

func (l *fakeLink) closeCode() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.code
}

func (l *fakeLink) failSends(err error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.sendErr = err
}

func (l *fakeLink) messages(t testing.TB) []controlMessage {
	t.Helper()
	l.mu.Lock()
	copied := append([][]byte(nil), l.sent...)
	l.mu.Unlock()
	out := make([]controlMessage, 0, len(copied))
	for _, message := range copied {
		out = append(out, parseControl(t, message))
	}
	return out
}

func (l *fakeLink) ofType(t testing.TB, kind contract.FrameType) []controlMessage {
	t.Helper()
	var out []controlMessage
	for _, m := range l.messages(t) {
		if m.Type == kind {
			out = append(out, m)
		}
	}
	return out
}

// describe は、制御メッセージを短い文字列にする（順序の確認用）。
func describe(t testing.TB, m controlMessage) string {
	t.Helper()
	switch m.Type {
	case contract.FrameTypeAccepted:
		return "accepted"
	case contract.FrameTypeProbeResult:
		return "probe_result"
	case contract.FrameTypeAck:
		return "ack"
	case contract.FrameTypeKeyframeRequest:
		return "keyframe_request"
	case contract.FrameTypeThrottle:
		return "throttle"
	case contract.FrameTypeStatus:
		var body struct {
			State string `json:"state"`
		}
		decodeJSON(t, m.Body, &body)
		return "status:" + body.State
	case contract.FrameTypeFatal:
		var body struct {
			Code string `json:"code"`
		}
		decodeJSON(t, m.Body, &body)
		return "fatal:" + body.Code
	}
	return fmt.Sprintf("type:%#x", uint8(m.Type))
}

// sequence は、送ったメッセージと切断を、順に並べた文字列にする。ack は、数が多いので除く。
func (l *fakeLink) sequence(t testing.TB) []string {
	t.Helper()
	l.mu.Lock()
	order := append([]string(nil), l.order...)
	sent := append([][]byte(nil), l.sent...)
	l.mu.Unlock()
	var out []string
	next := 0
	for _, entry := range order {
		if entry == "send" {
			description := describe(t, parseControl(t, sent[next]))
			next++
			if description == "ack" {
				continue
			}
			out = append(out, description)
			continue
		}
		out = append(out, entry)
	}
	return out
}

func (l *fakeLink) fatals(t testing.TB) []string {
	t.Helper()
	var out []string
	for _, m := range l.ofType(t, contract.FrameTypeFatal) {
		var body struct {
			Code string `json:"code"`
		}
		decodeJSON(t, m.Body, &body)
		out = append(out, body.Code)
	}
	return out
}

// ---- アプリケーション ----

type ticketOutcome struct {
	result backend.VerifyResult
	err    error
}

type provisionCall struct {
	broadcastID string
	epoch       int
	profile     contract.Profile
}

type fakeBackend struct {
	mu             sync.Mutex
	tickets        map[string]ticketOutcome
	verifyCalls    []string
	provisionCalls []provisionCall
	heartbeatCalls []backend.HeartbeatRequest

	provisionFn func(call provisionCall) (backend.ProvisionResult, error)
	heartbeatFn func(request backend.HeartbeatRequest) (backend.HeartbeatResponse, error)

	verifyGate       chan struct{}
	verifyEntered    chan struct{}
	provisionGate    chan struct{}
	provisionEntered chan struct{}
	heartbeatGate    chan struct{}
	heartbeatEntered chan struct{}
}

func newFakeBackend() *fakeBackend {
	return &fakeBackend{
		tickets:          map[string]ticketOutcome{},
		verifyEntered:    make(chan struct{}, 1024),
		provisionEntered: make(chan struct{}, 1024),
		heartbeatEntered: make(chan struct{}, 1024),
	}
}

const (
	dummyIngestURL = "rtmps://a.rtmps.youtube.com:443/live2"
	dummyStreamKey = "dummy-stream-key-SECRET-0042"
	dummyWatchURL  = "https://www.youtube.com/watch?v=dummyVideoId"
	dummyTicket    = "dummy-ticket-SECRET-0007-abcdefghijklmnopqrstuvwxyz"
	dummySecret    = "dummy-shared-secret-SECRET-0001"
)

func (b *fakeBackend) addTicket(ticket string, result backend.VerifyResult) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.tickets[ticket] = ticketOutcome{result: result}
}

func (b *fakeBackend) failTicket(ticket string, err error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.tickets[ticket] = ticketOutcome{err: err}
}

func (b *fakeBackend) Verify(ctx context.Context, ticket backend.Ticket) (backend.VerifyResult, error) {
	text := string(ticket)
	b.mu.Lock()
	b.verifyCalls = append(b.verifyCalls, text)
	gate := b.verifyGate
	b.mu.Unlock()
	if gate != nil {
		b.verifyEntered <- struct{}{}
		select {
		case <-gate:
		case <-ctx.Done():
			return backend.VerifyResult{}, ctx.Err()
		}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	outcome, ok := b.tickets[text]
	if !ok {
		return backend.VerifyResult{}, fmt.Errorf("%w: unknown ticket", backend.ErrTicketInvalid)
	}
	return outcome.result, outcome.err
}

func (b *fakeBackend) Provision(ctx context.Context, broadcastID string, epoch int, profile contract.Profile) (backend.ProvisionResult, error) {
	call := provisionCall{broadcastID: broadcastID, epoch: epoch, profile: profile}
	b.mu.Lock()
	b.provisionCalls = append(b.provisionCalls, call)
	gate := b.provisionGate
	fn := b.provisionFn
	b.mu.Unlock()
	if gate != nil {
		b.provisionEntered <- struct{}{}
		select {
		case <-gate:
		case <-ctx.Done():
			return backend.ProvisionResult{}, ctx.Err()
		}
	}
	if fn != nil {
		return fn(call)
	}
	return defaultProvisionResult(), nil
}

func defaultProvisionResult() backend.ProvisionResult {
	return backend.ProvisionResult{
		Ingest:   backend.Ingest{URL: dummyIngestURL, StreamKey: dummyStreamKey},
		WatchURL: dummyWatchURL,
		State:    contract.BroadcastStateAwaitingMedia,
	}
}

func (b *fakeBackend) Heartbeat(ctx context.Context, broadcastID string, request backend.HeartbeatRequest) (backend.HeartbeatResponse, error) {
	copied := request
	if request.Browser != nil {
		report := *request.Browser
		report.Events = append([]backend.BrowserEvent(nil), request.Browser.Events...)
		copied.Browser = &report
	}
	b.mu.Lock()
	b.heartbeatCalls = append(b.heartbeatCalls, copied)
	gate := b.heartbeatGate
	fn := b.heartbeatFn
	b.mu.Unlock()
	if gate != nil {
		b.heartbeatEntered <- struct{}{}
		select {
		case <-gate:
		case <-ctx.Done():
			return backend.HeartbeatResponse{}, ctx.Err()
		}
	}
	if fn != nil {
		return fn(copied)
	}
	return backend.HeartbeatResponse{Command: backend.CommandContinue}, nil
}

func (b *fakeBackend) setVerifyGate(gate chan struct{}) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.verifyGate = gate
}

func (b *fakeBackend) setHeartbeat(fn func(request backend.HeartbeatRequest) (backend.HeartbeatResponse, error)) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.heartbeatFn = fn
}

func (b *fakeBackend) setProvision(fn func(call provisionCall) (backend.ProvisionResult, error)) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.provisionFn = fn
}

func (b *fakeBackend) heartbeats() []backend.HeartbeatRequest {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]backend.HeartbeatRequest(nil), b.heartbeatCalls...)
}

func (b *fakeBackend) provisions() []provisionCall {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]provisionCall(nil), b.provisionCalls...)
}

func (b *fakeBackend) verifies() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]string(nil), b.verifyCalls...)
}

// rtmpsDisconnected は、受け口の側から切られた RTMPS の接続の終わり（rtmps.ErrDisconnected）。
func rtmpsDisconnected() error { return fmt.Errorf("%w: test", rtmps.ErrDisconnected) }

// rtmpsRejected は、publish の直後の切断（rtmps.ErrPublishRejected）。
func rtmpsRejected() error { return fmt.Errorf("%w: test", rtmps.ErrPublishRejected) }

// rtmpsOverflow は、送出待ちの上限への到達（rtmps.ErrBufferOverflow）。
func rtmpsOverflow() error { return fmt.Errorf("%w: test", rtmps.ErrBufferOverflow) }

// unreachable は、アプリケーションへ到達できない失敗。
func unreachable() error { return fmt.Errorf("%w: test", backend.ErrUnavailable) }

// ---- 事象 ----

type recordedEvent struct {
	id  string
	req backend.EventRequest
}

type fakeEvents struct {
	mu     sync.Mutex
	events []recordedEvent
}

func (f *fakeEvents) Enqueue(broadcastID string, event backend.EventRequest) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, recordedEvent{id: broadcastID, req: event})
}

func (f *fakeEvents) all() []recordedEvent {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]recordedEvent(nil), f.events...)
}

// kinds は、事象を「種類」または「種類:原因」の文字列にして、順に返す。
func (f *fakeEvents) kinds() []string {
	var out []string
	for _, e := range f.all() {
		text := string(e.req.Kind)
		if e.req.Cause != "" {
			text += ":" + string(e.req.Cause)
		}
		out = append(out, text)
	}
	return out
}

// ---- RTMPS の送出 ----

type publishedTag struct {
	kind    string // meta・video・audio
	ts      uint32
	payload []byte
}

type fakePublisher struct {
	mu         sync.Mutex
	writes     []publishedTag
	pendingMs  int
	sentBytes  uint64
	closed     chan struct{}
	closeOnce  sync.Once
	err        error
	closeCalls int
	abortCalls int
	order      []string
	writeErrs  []error // 次の書き込みから順に、失敗させる（nil は成功）
	closeGate  chan struct{}
	closeErr   error         // Close が返すエラー（終了の妨げにならないことの確認用）
	abortGate  chan struct{} // 非 nil なら、Abort は閉じられるまで戻らない（排他の完了待ちの確認用）
	panicWrite bool          // 真なら、次の書き込みで panic する（go-rtmp の panic の再現）
}

func newFakePublisher() *fakePublisher {
	return &fakePublisher{closed: make(chan struct{})}
}

func (p *fakePublisher) write(kind string, ts uint32, payload []byte) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.panicWrite && kind != "meta" {
		panic("fake publisher: simulated panic")
	}
	select {
	case <-p.closed:
		return fmt.Errorf("%w", rtmps.ErrClosed)
	default:
	}
	if len(p.writeErrs) > 0 {
		err := p.writeErrs[0]
		p.writeErrs = p.writeErrs[1:]
		if err != nil {
			p.terminateLocked(err)
			return fmt.Errorf("%w: %w", rtmps.ErrClosed, err)
		}
	}
	p.writes = append(p.writes, publishedTag{kind: kind, ts: ts, payload: append([]byte(nil), payload...)})
	p.sentBytes += uint64(len(payload))
	return nil
}

func (p *fakePublisher) WriteMeta(payload []byte) error { return p.write("meta", 0, payload) }

func (p *fakePublisher) WriteVideo(ts uint32, payload []byte) error {
	return p.write("video", ts, payload)
}

func (p *fakePublisher) WriteAudio(ts uint32, payload []byte) error {
	return p.write("audio", ts, payload)
}

func (p *fakePublisher) PendingMs() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pendingMs
}

func (p *fakePublisher) setPending(ms int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.pendingMs = ms
}

func (p *fakePublisher) SentBytes() uint64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.sentBytes
}

func (p *fakePublisher) Closed() <-chan struct{} { return p.closed }

func (p *fakePublisher) Err() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	select {
	case <-p.closed:
		return p.err
	default:
		return nil
	}
}

func (p *fakePublisher) terminateLocked(err error) {
	p.closeOnce.Do(func() {
		p.err = err
		close(p.closed)
	})
}

// terminate は、受け口の側から切られた・送出待ちの上限に達した、などの終了を再現する。
func (p *fakePublisher) terminate(err error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.terminateLocked(err)
}

func (p *fakePublisher) setPanicOnWrite() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.panicWrite = true
}

func (p *fakePublisher) failWrites(errs ...error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.writeErrs = append(p.writeErrs, errs...)
}

func (p *fakePublisher) Close() error {
	p.mu.Lock()
	p.closeCalls++
	p.order = append(p.order, "close")
	gate := p.closeGate
	p.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-p.closed: // Abort で解ける
		}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.terminateLocked(rtmps.ErrClosed)
	return p.closeErr
}

func (p *fakePublisher) Abort() {
	p.mu.Lock()
	p.abortCalls++
	p.order = append(p.order, "abort")
	p.terminateLocked(rtmps.ErrClosed)
	gate := p.abortGate
	p.mu.Unlock()
	if gate != nil {
		<-gate
	}
}

// holdAbort は、以後の Abort を、返された channel が閉じられるまで、戻らないようにする。
func (p *fakePublisher) holdAbort() chan struct{} {
	gate := make(chan struct{})
	p.mu.Lock()
	defer p.mu.Unlock()
	p.abortGate = gate
	return gate
}

func (p *fakePublisher) tags() []publishedTag {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]publishedTag(nil), p.writes...)
}

func (p *fakePublisher) counts() (closes, aborts int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.closeCalls, p.abortCalls
}

func (p *fakePublisher) isClosed() bool {
	select {
	case <-p.closed:
		return true
	default:
		return false
	}
}

// mediaTags は、設定のタグ（時刻 0 のシーケンスヘッダ）を除いた、映像・音声のタグ。
func mediaTags(tags []publishedTag) []publishedTag {
	var out []publishedTag
	for _, tag := range tags {
		switch {
		case tag.kind == "meta":
		case tag.kind == "video" && len(tag.payload) > 1 && tag.payload[1] == 0:
		case tag.kind == "audio" && len(tag.payload) > 1 && tag.payload[1] == 0:
		default:
			out = append(out, tag)
		}
	}
	return out
}

type openRecord struct {
	url    string
	key    string
	logger bool
}

type fakeFactory struct {
	mu       sync.Mutex
	opens    []openRecord
	pubs     []*fakePublisher
	outcomes []error // 試行ごとの結果（nil は成功）。尽きたら成功
	byKey    map[string]*fakePublisher
	gate     chan struct{}
	entered  chan struct{}
}

func newFakeFactory() *fakeFactory {
	return &fakeFactory{entered: make(chan struct{}, 1024)}
}

func (f *fakeFactory) Open(ctx context.Context, request OpenRequest) (Publisher, error) {
	f.mu.Lock()
	f.opens = append(f.opens, openRecord{url: string(request.URL), key: string(request.StreamKey), logger: request.Logger != nil})
	gate := f.gate
	f.mu.Unlock()
	if gate != nil {
		f.entered <- struct{}{}
		select {
		case <-gate:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.outcomes) > 0 {
		err := f.outcomes[0]
		f.outcomes = f.outcomes[1:]
		if err != nil {
			return nil, err
		}
	}
	pub := newFakePublisher()
	f.pubs = append(f.pubs, pub)
	if f.byKey == nil {
		f.byKey = map[string]*fakePublisher{}
	}
	f.byKey[string(request.StreamKey)] = pub
	return pub, nil
}

func (f *fakeFactory) setGate(gate chan struct{}) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.gate = gate
}

func (f *fakeFactory) failNext(errs ...error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.outcomes = append(f.outcomes, errs...)
}

// forKey は、配信キーで引いた Publisher（配信ごとに別のキーを返す準備の疑似と組み合わせる）。
func (f *fakeFactory) forKey(key string) *fakePublisher {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.byKey[key]
}

func (f *fakeFactory) openCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.opens)
}

func (f *fakeFactory) publishers() []*fakePublisher {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]*fakePublisher(nil), f.pubs...)
}

// last は、最後に作った Publisher。まだなければ失敗する。
func (f *fakeFactory) last(t testing.TB) *fakePublisher {
	t.Helper()
	pubs := f.publishers()
	if len(pubs) == 0 {
		t.Fatal("no publisher has been opened")
	}
	return pubs[len(pubs)-1]
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

var _ io.Writer = (*syncBuffer)(nil)

// ---- ゴルーチンの残り ----

// sessionGoroutineMarkers は、このパッケージ（と事象のキュー）の、ゴルーチンのスタックに現れる印。
func sessionGoroutineMarkers() []string {
	return []string{"session.(*IngestSession)", "session.(*Registry)", "session.(*Connection)", "backend.(*EventQueue)"}
}

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

// leftoverGoroutines は、取り込みセッション・台帳・接続・事象のキューの処理で動いているゴルーチンを返す。
func leftoverGoroutines() []string {
	var found []string
	for _, block := range goroutineBlocks() {
		if strings.Contains(block, "leftoverGoroutines") {
			continue // 検査している自分
		}
		for _, marker := range sessionGoroutineMarkers() {
			if strings.Contains(block, marker) {
				found = append(found, block)
				break
			}
		}
	}
	return found
}

// assertNoLeftoverGoroutines は、セッションを閉じたあとに、ゴルーチンが残らないことを確かめる（終わるのを最大 10 秒待つ）。
func assertNoLeftoverGoroutines(t testing.TB) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		found := leftoverGoroutines()
		if len(found) == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("goroutines remain after the sessions were closed:\n%s", strings.Join(found, "\n---\n"))
		}
		runtime.Gosched()
		time.Sleep(time.Millisecond)
	}
}
