package rtmps

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// Publisher の送出キュー・上限・閉じ方（疑似の sink）。RTMPS の接続を使う試験は、publisher_integration_test.go。

func payloadOf(length int, mark byte) []byte {
	payload := bytes.Repeat([]byte{mark}, length)
	return payload
}

// write は、記録 1 件を、Publisher の対応する書き込みで送る。
func write(p *Publisher, r record) error {
	switch r.kind {
	case "video":
		return p.WriteVideo(r.ts, r.payload)
	case "audio":
		return p.WriteAudio(r.ts, r.payload)
	default:
		return p.WriteMeta(r.payload)
	}
}

func sameRecords(t *testing.T, got, want []record) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("delivered %d messages, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i].kind != want[i].kind || got[i].ts != want[i].ts || !bytes.Equal(got[i].payload, want[i].payload) {
			t.Fatalf("message %d = %s ts %d (%d bytes), want %s ts %d (%d bytes)", i, got[i].kind, got[i].ts, len(got[i].payload), want[i].kind, want[i].ts, len(want[i].payload))
		}
	}
}

func isClosed(p *Publisher) bool {
	select {
	case <-p.Closed():
		return true
	default:
		return false
	}
}

func TestPublisherDeliversEverythingInOrder(t *testing.T) {
	sink := newFakeSink()
	p := newTestPublisher(t, sink, Config{})
	want := []record{
		{"meta", 0, payloadOf(40, 'm')},
		{"video", 0, payloadOf(30, 'c')},
		{"audio", 0, payloadOf(4, 'd')},
		{"video", 0, payloadOf(1000, 'k')},
		{"audio", 0, payloadOf(300, 'a')},
		{"audio", 23, payloadOf(300, 'b')},
		{"video", 33, payloadOf(120, 'p')},
		{"audio", 46, payloadOf(300, 'c')},
		{"video", 67, payloadOf(130, 'q')},
		{"meta", 0, payloadOf(40, 'n')},
	}
	var total uint64
	for _, r := range want {
		if err := write(p, r); err != nil {
			t.Fatalf("write %s: %v", r.kind, err)
		}
		total += uint64(len(r.payload))
	}
	if err := p.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	sameRecords(t, sink.records(), want)
	if got := p.SentBytes(); got != total {
		t.Errorf("SentBytes = %d, want %d", got, total)
	}
	if order := strings.Join(sink.callOrder(), ","); order != "close" {
		t.Errorf("sink calls = %q, want only close (a graceful close must not kill the connection)", order)
	}
	if !isClosed(p) {
		t.Errorf("Closed() was not signaled after Close")
	}
	if err := p.Err(); !errors.Is(err, ErrClosed) {
		t.Errorf("Err() = %v, want ErrClosed", err)
	}
}

// 書き込みは、非同期の送出キューへ積むだけで、呼び出し元をブロックしない（回線が詰まっていても）。
func TestWritesDoNotBlockWhenTheSinkIsStalled(t *testing.T) {
	sink := newFakeSink()
	sink.limit()
	p := newTestPublisher(t, sink, Config{})

	start := time.Now()
	const frames = 50
	for i := 0; i < frames; i++ {
		if err := p.WriteVideo(uint32(i*33), payloadOf(100, 'v')); err != nil {
			t.Fatalf("WriteVideo %d: %v", i, err)
		}
		if err := p.WriteAudio(uint32(i*23), payloadOf(10, 'a')); err != nil {
			t.Fatalf("WriteAudio %d: %v", i, err)
		}
		if err := p.WriteMeta(payloadOf(10, 'm')); err != nil {
			t.Fatalf("WriteMeta %d: %v", i, err)
		}
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("%d writes took %v while the sink was stalled; a write must not block", frames*3, elapsed)
	}
	if got, want := p.PendingMs(), (frames-1)*33; got != want {
		t.Errorf("PendingMs = %d, want %d (the newest queued time minus the time of the first message)", got, want)
	}
	if len(sink.records()) != 0 {
		t.Errorf("the stalled sink received messages")
	}

	sink.unblock()
	eventually(t, "all messages delivered", func() bool { return len(sink.records()) == frames*3 })
	eventually(t, "pending drained", func() bool { return p.PendingMs() == 0 })
}

// PendingMs は、送出待ちのメディア時間の幅（最後に積んだ時刻 - 最後に送った時刻）。
func TestPendingMsIsTheWidthBetweenTheLastQueuedAndTheLastSentTimes(t *testing.T) {
	sink := newFakeSink()
	sink.limit()
	p := newTestPublisher(t, sink, Config{})

	expectPending := func(want int) {
		t.Helper()
		eventually(t, fmt.Sprintf("PendingMs == %d", want), func() bool { return p.PendingMs() == want })
		// 安定している（一度そろったあと、動かない）
		time.Sleep(5 * time.Millisecond)
		if got := p.PendingMs(); got != want {
			t.Fatalf("PendingMs = %d, want a stable %d", got, want)
		}
	}

	if got := p.PendingMs(); got != 0 {
		t.Fatalf("PendingMs before any write = %d, want 0", got)
	}
	steps := []struct {
		queue       func() error
		wantPending int
	}{
		{func() error { return p.WriteVideo(1000, payloadOf(10, 'a')) }, 0}, // 最初のメディアが、起点
		{func() error { return p.WriteAudio(1023, payloadOf(10, 'b')) }, 23},
		{func() error { return p.WriteVideo(1033, payloadOf(10, 'c')) }, 33},
		{func() error { return p.WriteAudio(1046, payloadOf(10, 'd')) }, 46},
		{func() error { return p.WriteMeta(payloadOf(10, 'm')) }, 46},       // メタデータは、時刻を持たない
		{func() error { return p.WriteVideo(900, payloadOf(10, 'e')) }, 46}, // 古い時刻は、最後に積んだ時刻を戻さない
	}
	for i, step := range steps {
		if err := step.queue(); err != nil {
			t.Fatalf("step %d: %v", i, err)
		}
		expectPending(step.wantPending)
	}

	// 1 つ送るごとに、最後に送った時刻が進む。キューの順は、積んだ順（1000・1023・1033・1046・メタ・900）
	for i, want := range []int{46, 23, 13, 0, 0, 0} {
		sink.grant(1)
		eventually(t, fmt.Sprintf("message %d delivered", i+1), func() bool { return len(sink.records()) == i+1 })
		expectPending(want)
	}
}

// 3 秒分（契約 relay.egress_buffer_limit_ms）の上限に達したら ErrBufferOverflow（上限ちょうどは、達している）。
func TestOverflowBoundary(t *testing.T) {
	limit := uint32(contract.RelayEgressBufferLimitMs)
	cases := []struct {
		name         string
		firstTs      uint32
		secondTs     uint32
		audio        bool
		wantOverflow bool
	}{
		{name: "上限の 1 ms 手前", firstTs: 0, secondTs: limit - 1},
		{name: "上限ちょうど", firstTs: 0, secondTs: limit, wantOverflow: true},
		{name: "上限の 1 ms 超", firstTs: 0, secondTs: limit + 1, wantOverflow: true},
		{name: "大きく超える", firstTs: 0, secondTs: limit * 20, wantOverflow: true},
		{name: "起点が 0 でない（上限の 1 ms 手前）", firstTs: 5000, secondTs: 5000 + limit - 1},
		{name: "起点が 0 でない（上限ちょうど）", firstTs: 5000, secondTs: 5000 + limit, wantOverflow: true},
		{name: "音声でも同じ（手前）", firstTs: 100, secondTs: 100 + limit - 1, audio: true},
		{name: "音声でも同じ（ちょうど）", firstTs: 100, secondTs: 100 + limit, audio: true, wantOverflow: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			sink := newFakeSink()
			sink.limit()
			p := newTestPublisher(t, sink, Config{})
			if err := p.WriteVideo(c.firstTs, payloadOf(10, 'a')); err != nil {
				t.Fatalf("first write: %v", err)
			}
			var err error
			if c.audio {
				err = p.WriteAudio(c.secondTs, payloadOf(10, 'b'))
			} else {
				err = p.WriteVideo(c.secondTs, payloadOf(10, 'b'))
			}
			if !c.wantOverflow {
				if err != nil {
					t.Fatalf("write at the edge below the limit: %v", err)
				}
				if isClosed(p) {
					t.Fatalf("the publisher closed below the limit")
				}
				if got, want := p.PendingMs(), int(c.secondTs-c.firstTs); got != want {
					t.Errorf("PendingMs = %d, want %d", got, want)
				}
				return
			}
			if !errors.Is(err, ErrBufferOverflow) {
				t.Fatalf("error = %v, want ErrBufferOverflow", err)
			}
		})
	}
}

// 上限に達したら、バッファを破棄し、接続を切って、Publisher は閉じる（呼び出し側が再接続する）。
func TestOverflowDiscardsTheBufferAndClosesThePublisher(t *testing.T) {
	sink := newFakeSink()
	sink.limit()
	p := newTestPublisher(t, sink, Config{})
	for i := 0; i < 20; i++ {
		if err := p.WriteVideo(uint32(i), payloadOf(10, byte('a'+i))); err != nil {
			t.Fatalf("write %d: %v", i, err)
		}
	}
	err := p.WriteAudio(uint32(contract.RelayEgressBufferLimitMs), payloadOf(10, 'z'))
	if !errors.Is(err, ErrBufferOverflow) {
		t.Fatalf("error = %v, want ErrBufferOverflow", err)
	}
	if errors.Is(err, ErrClosed) {
		t.Errorf("the call that reaches the limit reports the overflow itself (not ErrClosed)")
	}

	if !isClosed(p) {
		t.Fatalf("Closed() must be signaled as soon as the buffer overflows")
	}
	if got := p.Err(); !errors.Is(got, ErrBufferOverflow) {
		t.Errorf("Err() = %v, want ErrBufferOverflow", got)
	}
	if got := p.PendingMs(); got != 0 {
		t.Errorf("PendingMs after the buffer was discarded = %d, want 0", got)
	}

	waitTeardown(t, p)
	if order := strings.Join(sink.callOrder(), ","); order != "kill,close" {
		t.Errorf("sink calls = %q, want kill then close (the stalled write must be released, the connection dropped)", order)
	}
	sink.unblock()
	if got := sink.records(); len(got) != 0 {
		t.Errorf("the discarded buffer was still sent: %d messages", len(got))
	}

	// 以後の書き込みは、ErrClosed（原因も包む）
	for name, writeAgain := range map[string]func() error{
		"video": func() error { return p.WriteVideo(1, payloadOf(1, 'x')) },
		"audio": func() error { return p.WriteAudio(1, payloadOf(1, 'x')) },
		"meta":  func() error { return p.WriteMeta(payloadOf(1, 'x')) },
	} {
		err := writeAgain()
		if !errors.Is(err, ErrClosed) || !errors.Is(err, ErrBufferOverflow) {
			t.Errorf("%s after the overflow: error = %v, want ErrClosed wrapping ErrBufferOverflow", name, err)
		}
	}
	if err := p.Close(); !errors.Is(err, ErrBufferOverflow) {
		t.Errorf("Close after the overflow = %v, want the cause (ErrBufferOverflow)", err)
	}
}

// 送出が追いついている間は、上限に達しない（時刻の幅は、送り終えた時刻から数える）。
func TestNoOverflowWhileTheSinkKeepsUp(t *testing.T) {
	sink := newFakeSink()
	p := newTestPublisher(t, sink, Config{})
	const messages = 2000 // 1 ms 刻み。送出が、2,000 件（2 秒分）まで遅れても、上限（3 秒分）に達しない
	for i := 0; i < messages; i++ {
		if err := p.WriteVideo(uint32(i), payloadOf(10, 'v')); err != nil {
			t.Fatalf("write %d: %v", i, err)
		}
	}
	if err := p.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if got := len(sink.records()); got != messages {
		t.Errorf("delivered %d messages, want %d", got, messages)
	}
}

// 時刻が進まない書き込み（同じ時刻の繰り返し・逆行）でも、送出待ちの量（バイト）に上限があり、メモリが増え続けない。
func TestOverflowByBytesWhenTimestampsDoNotAdvance(t *testing.T) {
	const megabyte = 1024 * 1024
	t.Run("上限ちょうどまでは受け付ける", func(t *testing.T) {
		sink := newFakeSink()
		sink.limit()
		p := newTestPublisher(t, sink, Config{})
		chunk := make([]byte, megabyte)
		// 書き込みのゴルーチンが、最初の 1 件を取り出して止まる。残りの積み残しが、maxPendingBytes ちょうどになるまで積む
		if err := p.WriteVideo(5, chunk); err != nil {
			t.Fatal(err)
		}
		eventually(t, "the writer took the first message", func() bool {
			p.mu.Lock()
			defer p.mu.Unlock()
			return len(p.queue) == 0
		})
		for i := 0; i < maxPendingBytes/megabyte; i++ {
			if err := p.WriteVideo(5, chunk); err != nil {
				t.Fatalf("message %d (the queue holds %d MiB): %v", i, i, err)
			}
		}
		if isClosed(p) || p.PendingMs() != 0 {
			t.Fatalf("the queue at exactly the byte limit must stay open (pending %d ms)", p.PendingMs())
		}
		// 1 バイトでも超えたら、上限
		err := p.WriteVideo(5, []byte{1})
		if !errors.Is(err, ErrBufferOverflow) {
			t.Fatalf("error = %v, want ErrBufferOverflow", err)
		}
		if !strings.Contains(err.Error(), "bytes") {
			t.Errorf("the error should say that the byte limit was reached: %v", err)
		}
		if !isClosed(p) {
			t.Errorf("the publisher must close")
		}
		p.mu.Lock()
		discarded := p.queue == nil && p.queuedBytes == 0
		p.mu.Unlock()
		if !discarded {
			t.Errorf("the buffer must be discarded")
		}
	})
	t.Run("メタデータの大量の書き込みでも", func(t *testing.T) {
		sink := newFakeSink()
		sink.limit()
		p := newTestPublisher(t, sink, Config{})
		chunk := make([]byte, megabyte)
		var overflow error
		for i := 0; i < maxPendingBytes/megabyte+3; i++ {
			if err := p.WriteMeta(chunk); err != nil {
				overflow = err
				break
			}
		}
		if !errors.Is(overflow, ErrBufferOverflow) {
			t.Fatalf("error = %v, want ErrBufferOverflow", overflow)
		}
	})
	t.Run("送り終えた分は、数えない", func(t *testing.T) {
		sink := newFakeSink()
		p := newTestPublisher(t, sink, Config{})
		chunk := make([]byte, megabyte)
		for i := 0; i < 3*maxPendingBytes/megabyte; i++ {
			if err := p.WriteVideo(5, chunk); err != nil {
				t.Fatalf("message %d: %v", i, err)
			}
			eventually(t, "the queue drained", func() bool {
				p.mu.Lock()
				defer p.mu.Unlock()
				return p.queuedBytes == 0
			})
		}
	})
}

// メタデータは、時刻を持たず、送出待ちの幅にも、上限にも、数えない。
func TestMetaMessagesDoNotCountTowardsTheLimit(t *testing.T) {
	sink := newFakeSink()
	sink.limit()
	p := newTestPublisher(t, sink, Config{})
	for i := 0; i < 10000; i++ {
		if err := p.WriteMeta(payloadOf(10, 'm')); err != nil {
			t.Fatalf("WriteMeta %d: %v", i, err)
		}
	}
	if got := p.PendingMs(); got != 0 {
		t.Errorf("PendingMs = %d, want 0", got)
	}
	if isClosed(p) {
		t.Errorf("the publisher closed because of metadata messages")
	}
}

// Close は、送出待ちを送り切ってから、接続を切る（停止の経路。13.3）。送り切るまで、戻らない。
func TestCloseSendsEverythingPendingBeforeClosing(t *testing.T) {
	sink := newFakeSink()
	sink.limit()
	p := newTestPublisher(t, sink, Config{})
	var want []record
	for i := 0; i < 10; i++ {
		r := record{kind: "video", ts: uint32(i * 33), payload: payloadOf(50+i, byte('a'+i))}
		want = append(want, r)
		if err := write(p, r); err != nil {
			t.Fatal(err)
		}
	}

	closeResult := make(chan error, 1)
	go func() { closeResult <- p.Close() }()

	select {
	case err := <-closeResult:
		t.Fatalf("Close returned (%v) before the pending messages were sent", err)
	case <-time.After(60 * time.Millisecond):
	}
	// 閉じている最中の書き込みは、受け付けない
	if err := p.WriteVideo(1000, payloadOf(1, 'x')); !errors.Is(err, ErrClosed) {
		t.Errorf("a write while closing = %v, want ErrClosed", err)
	}
	if order := strings.Join(sink.callOrder(), ","); order != "" {
		t.Errorf("the connection was touched before everything was sent: %q", order)
	}

	sink.unblock()
	select {
	case err := <-closeResult:
		if err != nil {
			t.Fatalf("Close: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("Close did not return after the sink was released")
	}
	sameRecords(t, sink.records(), want)
	if order := strings.Join(sink.callOrder(), ","); order != "close" {
		t.Errorf("sink calls = %q, want only close", order)
	}
}

// 送り切れなければ、期限（CloseTimeout）で、強制的に切る。
func TestCloseGivesUpAfterTheTimeoutWhenTheSinkIsStalled(t *testing.T) {
	sink := newFakeSink()
	sink.limit()
	p := newTestPublisher(t, sink, Config{CloseTimeout: 50 * time.Millisecond})
	for i := 0; i < 5; i++ {
		if err := p.WriteVideo(uint32(i), payloadOf(10, 'v')); err != nil {
			t.Fatal(err)
		}
	}
	start := time.Now()
	err := p.Close()
	if !errors.Is(err, ErrDrainTimeout) {
		t.Fatalf("Close = %v, want ErrDrainTimeout", err)
	}
	if elapsed := time.Since(start); elapsed < 50*time.Millisecond || elapsed > 3*time.Second {
		t.Errorf("Close took %v, want about the 50 ms timeout", elapsed)
	}
	if order := strings.Join(sink.callOrder(), ","); order != "kill,close" {
		t.Errorf("sink calls = %q, want kill then close", order)
	}
	if got := p.Err(); !errors.Is(got, ErrDrainTimeout) {
		t.Errorf("Err() = %v, want ErrDrainTimeout", got)
	}
}

// Abort は、バッファを破棄して、直ちに切断する。
func TestAbortDiscardsTheBufferAndDropsTheConnection(t *testing.T) {
	sink := newFakeSink()
	sink.limit()
	p := newTestPublisher(t, sink, Config{})
	for i := 0; i < 10; i++ {
		if err := p.WriteVideo(uint32(i), payloadOf(10, 'v')); err != nil {
			t.Fatal(err)
		}
	}
	start := time.Now()
	p.Abort()
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Errorf("Abort took %v", elapsed)
	}
	if !isClosed(p) {
		t.Errorf("Closed() was not signaled after Abort")
	}
	if order := strings.Join(sink.callOrder(), ","); order != "kill,close" {
		t.Errorf("sink calls = %q, want kill then close", order)
	}
	sink.unblock()
	if got := sink.records(); len(got) != 0 {
		t.Errorf("the aborted buffer was still sent: %d messages", len(got))
	}
	if err := p.Err(); !errors.Is(err, ErrClosed) {
		t.Errorf("Err() = %v, want ErrClosed", err)
	}
	if err := p.WriteAudio(1, payloadOf(1, 'x')); !errors.Is(err, ErrClosed) {
		t.Errorf("write after Abort = %v, want ErrClosed", err)
	}
	if err := p.Close(); err != nil {
		t.Errorf("Close after Abort = %v, want nil (the caller chose to discard)", err)
	}
	if got := p.PendingMs(); got != 0 {
		t.Errorf("PendingMs after Abort = %d, want 0", got)
	}
}

// 書き込みが失敗したら、Publisher は閉じる（接続を切って、バッファを破棄する）。
func TestSinkWriteFailureClosesThePublisher(t *testing.T) {
	boom := errors.New("write: connection reset by peer")
	sink := newFakeSink()
	p := newTestPublisher(t, sink, Config{})
	if err := p.WriteVideo(0, payloadOf(10, 'a')); err != nil {
		t.Fatal(err)
	}
	eventually(t, "the first message delivered", func() bool { return len(sink.records()) == 1 })

	sink.failWith(boom)
	if err := p.WriteVideo(33, payloadOf(10, 'b')); err != nil {
		t.Fatalf("the write is queued (the failure surfaces from the connection): %v", err)
	}
	select {
	case <-p.Closed():
	case <-time.After(5 * time.Second):
		t.Fatalf("Closed() was not signaled after a write failure")
	}
	err := p.Err()
	if !errors.Is(err, ErrDisconnected) || !errors.Is(err, boom) {
		t.Fatalf("Err() = %v, want ErrDisconnected wrapping the write error", err)
	}
	if errors.Is(err, ErrPublishRejected) {
		t.Errorf("a failure long after publish is a disconnect, not a rejected publish")
	}
	waitTeardown(t, p)
	if order := strings.Join(sink.callOrder(), ","); order != "kill,close" {
		t.Errorf("sink calls = %q, want kill then close", order)
	}
	if err := p.WriteVideo(66, payloadOf(1, 'x')); !errors.Is(err, ErrClosed) || !errors.Is(err, ErrDisconnected) {
		t.Errorf("write after the failure = %v, want ErrClosed wrapping ErrDisconnected", err)
	}
}

// 切断は、書き込みが無くても、検知する（接続の状態を見張る）。
func TestDisconnectIsDetectedWithoutAnyWrite(t *testing.T) {
	sink := newFakeSink()
	p := newTestPublisher(t, sink, Config{})
	if isClosed(p) {
		t.Fatal("closed at the start")
	}
	sink.breakConnection(io.EOF)
	select {
	case <-p.Closed():
	case <-time.After(5 * time.Second):
		t.Fatalf("Closed() was not signaled after the connection broke")
	}
	if err := p.Err(); !errors.Is(err, ErrDisconnected) || !errors.Is(err, io.EOF) {
		t.Errorf("Err() = %v, want ErrDisconnected wrapping io.EOF", err)
	}
	waitTeardown(t, p)
	if order := strings.Join(sink.callOrder(), ","); order != "kill,close" {
		t.Errorf("sink calls = %q, want kill then close", order)
	}
	if err := p.WriteAudio(1, payloadOf(1, 'x')); !errors.Is(err, ErrClosed) {
		t.Errorf("write after the disconnect = %v, want ErrClosed", err)
	}
}

// publish の直後の切断は、配信キーの不正・使用中の可能性として、ErrPublishRejected に分類する
// （go-rtmp は onStatus を処理しないので、切断で検知する）。ErrDisconnected とは別の分類。
func TestDisconnectRightAfterPublishIsClassifiedAsRejected(t *testing.T) {
	t.Run("接続の状態から検知", func(t *testing.T) {
		sink := newFakeSink()
		p := newTestPublisher(t, sink, Config{PublishRejectWindow: time.Hour})
		sink.breakConnection(io.EOF)
		select {
		case <-p.Closed():
		case <-time.After(5 * time.Second):
			t.Fatalf("Closed() was not signaled")
		}
		err := p.Err()
		if !errors.Is(err, ErrPublishRejected) || !errors.Is(err, io.EOF) {
			t.Fatalf("Err() = %v, want ErrPublishRejected wrapping io.EOF", err)
		}
		if errors.Is(err, ErrDisconnected) {
			t.Errorf("a rejected publish must be distinguishable from a later disconnect")
		}
		if err := p.WriteVideo(1, payloadOf(1, 'x')); !errors.Is(err, ErrClosed) || !errors.Is(err, ErrPublishRejected) {
			t.Errorf("write after the rejection = %v, want ErrClosed wrapping ErrPublishRejected", err)
		}
		if err := p.Close(); !errors.Is(err, ErrPublishRejected) {
			t.Errorf("Close = %v, want the cause (ErrPublishRejected)", err)
		}
	})
	t.Run("書き込みの失敗から検知", func(t *testing.T) {
		sink := newFakeSink()
		sink.failWith(errors.New("write: broken pipe"))
		p := newTestPublisher(t, sink, Config{PublishRejectWindow: time.Hour, PollInterval: time.Hour})
		if err := p.WriteVideo(0, payloadOf(10, 'a')); err != nil {
			t.Fatal(err)
		}
		select {
		case <-p.Closed():
		case <-time.After(5 * time.Second):
			t.Fatalf("Closed() was not signaled")
		}
		if err := p.Err(); !errors.Is(err, ErrPublishRejected) {
			t.Errorf("Err() = %v, want ErrPublishRejected", err)
		}
	})
}

// 窓（PublishRejectWindow）より後の切断は、ErrDisconnected。
func TestDisconnectAfterTheWindowIsAPlainDisconnect(t *testing.T) {
	sink := newFakeSink()
	p := newTestPublisher(t, sink, Config{PublishRejectWindow: 30 * time.Millisecond})
	time.Sleep(80 * time.Millisecond)
	sink.breakConnection(io.EOF)
	select {
	case <-p.Closed():
	case <-time.After(5 * time.Second):
		t.Fatalf("Closed() was not signaled")
	}
	err := p.Err()
	if !errors.Is(err, ErrDisconnected) || errors.Is(err, ErrPublishRejected) {
		t.Errorf("Err() = %v, want ErrDisconnected", err)
	}
}

// 映像・音声・メタを、別のゴルーチンから並行に書ける（-race で確かめる）。
func TestConcurrentWriters(t *testing.T) {
	sink := newFakeSink()
	p := newTestPublisher(t, sink, Config{})
	const perKind = 500
	var wg sync.WaitGroup
	var expectedBytes uint64
	var bytesMu sync.Mutex
	producers := map[string]func(i int) error{
		"video": func(i int) error { return p.WriteVideo(uint32(i), payloadOf(20+i%7, 'v')) },
		"audio": func(i int) error { return p.WriteAudio(uint32(i), payloadOf(10+i%5, 'a')) },
		"meta":  func(i int) error { return p.WriteMeta(payloadOf(5+i%3, 'm')) },
	}
	sizes := map[string]func(i int) int{
		"video": func(i int) int { return 20 + i%7 },
		"audio": func(i int) int { return 10 + i%5 },
		"meta":  func(i int) int { return 5 + i%3 },
	}
	errs := make(chan error, 3*perKind)
	for kind, produce := range producers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < perKind; i++ {
				if err := produce(i); err != nil {
					errs <- fmt.Errorf("%s %d: %w", kind, i, err)
					return
				}
				bytesMu.Lock()
				expectedBytes += uint64(sizes[kind](i))
				bytesMu.Unlock()
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	if err := p.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	got := sink.records()
	if len(got) != 3*perKind {
		t.Fatalf("delivered %d messages, want %d", len(got), 3*perKind)
	}
	// 種別ごとの順序は、書いた順（時刻が単調に増える）
	last := map[string]int{"video": -1, "audio": -1}
	counts := map[string]int{}
	for _, r := range got {
		counts[r.kind]++
		if r.kind == "meta" {
			continue
		}
		if int(r.ts) <= last[r.kind] {
			t.Fatalf("%s timestamps went backward: %d after %d", r.kind, r.ts, last[r.kind])
		}
		last[r.kind] = int(r.ts)
	}
	for kind, count := range counts {
		if count != perKind {
			t.Errorf("%s delivered %d, want %d", kind, count, perKind)
		}
	}
	if got := p.SentBytes(); got != expectedBytes {
		t.Errorf("SentBytes = %d, want %d", got, expectedBytes)
	}
}

// 空の本文・RTMP のメッセージの長さの上限（24 ビット）を超える本文は、拒否する。Publisher は、閉じない。
func TestInvalidMessagesAreRejectedWithoutClosing(t *testing.T) {
	sink := newFakeSink()
	p := newTestPublisher(t, sink, Config{})
	tooLarge := make([]byte, maxMessageBytes+1)
	exactlyMax := make([]byte, maxMessageBytes)
	for name, call := range map[string]func() error{
		"video nil":     func() error { return p.WriteVideo(0, nil) },
		"video empty":   func() error { return p.WriteVideo(0, []byte{}) },
		"audio nil":     func() error { return p.WriteAudio(0, nil) },
		"audio empty":   func() error { return p.WriteAudio(0, []byte{}) },
		"meta nil":      func() error { return p.WriteMeta(nil) },
		"meta empty":    func() error { return p.WriteMeta([]byte{}) },
		"video too big": func() error { return p.WriteVideo(0, tooLarge) },
		"audio too big": func() error { return p.WriteAudio(0, tooLarge) },
		"meta too big":  func() error { return p.WriteMeta(tooLarge) },
	} {
		if err := call(); !errors.Is(err, ErrInvalidMessage) {
			t.Errorf("%s: error = %v, want ErrInvalidMessage", name, err)
		}
	}
	if isClosed(p) {
		t.Fatalf("an invalid message must not close the publisher")
	}
	if err := p.WriteVideo(0, exactlyMax); err != nil {
		t.Errorf("a message of exactly the maximum size: %v", err)
	}
	if err := p.WriteAudio(0, payloadOf(1, 'a')); err != nil {
		t.Errorf("the publisher must stay usable: %v", err)
	}
}

// Close は、何度呼んでも、並行に呼んでも、同じ結果（冪等）。
func TestCloseIsIdempotentAndSafeToCallConcurrently(t *testing.T) {
	sink := newFakeSink()
	p := newTestPublisher(t, sink, Config{})
	for i := 0; i < 20; i++ {
		if err := p.WriteVideo(uint32(i), payloadOf(10, 'v')); err != nil {
			t.Fatal(err)
		}
	}
	results := make(chan error, 8)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results <- p.Close()
		}()
	}
	wg.Wait()
	close(results)
	for err := range results {
		if err != nil {
			t.Errorf("concurrent Close = %v, want nil", err)
		}
	}
	if err := p.Close(); err != nil {
		t.Errorf("a later Close = %v, want nil", err)
	}
	p.Abort() // 閉じたあとの Abort も、無害
	if got := len(sink.records()); got != 20 {
		t.Errorf("delivered %d, want 20", got)
	}
	if got := strings.Count(strings.Join(sink.callOrder(), ","), "close"); got != 1 {
		t.Errorf("the connection was closed %d times, want once", got)
	}
}

// 何も書いていない Publisher も、直ちに閉じられる。
func TestCloseWithNothingPending(t *testing.T) {
	sink := newFakeSink()
	p := newTestPublisher(t, sink, Config{})
	start := time.Now()
	if err := p.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Errorf("Close took %v with nothing to send", elapsed)
	}
	if len(sink.records()) != 0 {
		t.Errorf("unexpected messages")
	}
}

// 後始末が終わらなければ、Close は、TeardownTimeout で待つのをやめて、ErrTeardownTimeout を返す（有限の時間で戻る）。
func TestCloseReturnsTeardownTimeoutWhenTheSinkNeverFinishesClosing(t *testing.T) {
	sink := newFakeSink()
	release := sink.holdClose()
	p := newTestPublisher(t, sink, Config{TeardownTimeout: 100 * time.Millisecond, CloseLinger: time.Millisecond})
	t.Cleanup(release) // Abort の後始末より先に、止めている close を解く
	if err := p.WriteVideo(0, payloadOf(10, 'v')); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	err := p.Close()
	elapsed := time.Since(start)
	if !errors.Is(err, ErrTeardownTimeout) {
		t.Fatalf("Close = %v, want ErrTeardownTimeout", err)
	}
	if elapsed < 100*time.Millisecond || elapsed > 3*time.Second {
		t.Errorf("Close took %v with a teardown timeout of 100ms", elapsed)
	}
	// 止めていた close を解けば、後始末は済む（ゴルーチンは残らない）
	release()
	waitTeardown(t, p)
}

// 後始末を待つ期限は、TeardownTimeout と CloseLinger の合計（送り切った Close は、後始末の最後に、受け口が閉じるのを待つ）。
func TestTeardownBudgetIncludesTheLinger(t *testing.T) {
	sink := newFakeSink()
	release := sink.holdClose()
	p := newTestPublisher(t, sink, Config{TeardownTimeout: 50 * time.Millisecond, CloseLinger: 5 * time.Second})
	t.Cleanup(release)
	if err := p.WriteVideo(0, payloadOf(10, 'v')); err != nil {
		t.Fatal(err)
	}
	go func() {
		time.Sleep(300 * time.Millisecond) // TeardownTimeout より遅く、合計より早く済む
		release()
	}()
	if err := p.Close(); err != nil {
		t.Fatalf("Close = %v, want nil: the teardown finished within TeardownTimeout + CloseLinger", err)
	}
}

// 接続を閉じるときのエラーは、Close が返す。
func TestCloseReturnsTheConnectionCloseError(t *testing.T) {
	sink := newFakeSink()
	closeFailed := errors.New("close: use of closed network connection")
	sink.closeErr = closeFailed
	p := newTestPublisher(t, sink, Config{})
	if err := p.WriteVideo(0, payloadOf(10, 'v')); err != nil {
		t.Fatal(err)
	}
	if err := p.Close(); !errors.Is(err, closeFailed) {
		t.Errorf("Close = %v, want the connection close error", err)
	}
}

// 失敗・Abort・上限・Close の、どの終わり方でも、ゴルーチンは残らない。
func TestNoGoroutinesRemainAfterAnyKindOfClose(t *testing.T) {
	endings := map[string]func(t *testing.T, p *Publisher, s *fakeSink){
		"Close": func(t *testing.T, p *Publisher, s *fakeSink) {
			if err := p.Close(); err != nil {
				t.Errorf("Close: %v", err)
			}
		},
		"Abort": func(t *testing.T, p *Publisher, s *fakeSink) { p.Abort() },
		"切断": func(t *testing.T, p *Publisher, s *fakeSink) {
			s.breakConnection(io.EOF)
			<-p.Closed()
			waitTeardown(t, p)
		},
		"書き込みの失敗": func(t *testing.T, p *Publisher, s *fakeSink) {
			s.failWith(errors.New("boom"))
			_ = p.WriteVideo(5, payloadOf(1, 'x'))
			<-p.Closed()
			waitTeardown(t, p)
		},
		"上限": func(t *testing.T, p *Publisher, s *fakeSink) {
			_ = p.WriteVideo(uint32(contract.RelayEgressBufferLimitMs)+10, payloadOf(1, 'x'))
			_ = p.WriteVideo(uint32(contract.RelayEgressBufferLimitMs)*3, payloadOf(1, 'x'))
			<-p.Closed()
			waitTeardown(t, p)
		},
		"期限切れの Close": func(t *testing.T, p *Publisher, s *fakeSink) {
			if err := p.Close(); !errors.Is(err, ErrDrainTimeout) {
				t.Errorf("Close = %v, want ErrDrainTimeout", err)
			}
		},
	}
	for name, end := range endings {
		t.Run(name, func(t *testing.T) {
			sink := newFakeSink()
			if name == "上限" || name == "期限切れの Close" {
				sink.limit()
			}
			p, err := newPublisher(sink, Config{PollInterval: 5 * time.Millisecond, PublishRejectWindow: time.Nanosecond, CloseTimeout: 50 * time.Millisecond})
			if err != nil {
				t.Fatal(err)
			}
			if err := p.WriteVideo(0, payloadOf(10, 'v')); err != nil {
				t.Fatal(err)
			}
			end(t, p, sink)
			waitTeardown(t, p)
			waitNoPublisherGoroutines(t)
		})
	}
}

// Publisher は、配信キーを持たない。書式化しても、中身（接続）を出さない。
func TestPublisherFormatting(t *testing.T) {
	sink := newFakeSink()
	p := newTestPublisher(t, sink, Config{})
	for _, verb := range []string{"%v", "%+v", "%#v", "%s"} {
		text := fmt.Sprintf(verb, p)
		if !strings.Contains(text, "rtmps.Publisher") {
			t.Errorf("Sprintf(%q) = %q, want it to name the type", verb, text)
		}
		if strings.Contains(text, "0x") || strings.Contains(text, "fakeSink") {
			t.Errorf("Sprintf(%q) = %q dumps internals", verb, text)
		}
	}
}

func TestConfigNormalize(t *testing.T) {
	defaults, err := Config{}.normalized()
	if err != nil {
		t.Fatalf("normalized: %v", err)
	}
	if defaults.DialTimeout != DefaultDialTimeout || defaults.CloseTimeout != DefaultCloseTimeout || defaults.CloseLinger != DefaultCloseLinger ||
		defaults.TeardownTimeout != DefaultTeardownTimeout || defaults.PollInterval != DefaultPollInterval || defaults.PublishRejectWindow != DefaultPublishRejectWindow {
		t.Errorf("defaults = %+v", defaults)
	}
	if defaults.Logger == nil {
		t.Errorf("a default logger is needed (it discards)")
	}
	custom, err := Config{
		DialTimeout: time.Second, CloseTimeout: 2 * time.Second, CloseLinger: 5 * time.Millisecond, TeardownTimeout: 6 * time.Second,
		PollInterval: 3 * time.Millisecond, PublishRejectWindow: 4 * time.Second,
	}.normalized()
	if err != nil {
		t.Fatalf("normalized: %v", err)
	}
	if custom.DialTimeout != time.Second || custom.CloseTimeout != 2*time.Second || custom.CloseLinger != 5*time.Millisecond ||
		custom.TeardownTimeout != 6*time.Second || custom.PollInterval != 3*time.Millisecond || custom.PublishRejectWindow != 4*time.Second {
		t.Errorf("custom = %+v", custom)
	}
	for name, cfg := range map[string]Config{
		"DialTimeout":         {DialTimeout: -1},
		"CloseTimeout":        {CloseTimeout: -time.Second},
		"CloseLinger":         {CloseLinger: -time.Second},
		"TeardownTimeout":     {TeardownTimeout: -time.Second},
		"PollInterval":        {PollInterval: -time.Millisecond},
		"PublishRejectWindow": {PublishRejectWindow: -time.Second},
	} {
		if _, err := cfg.normalized(); !errors.Is(err, ErrInvalidConfig) {
			t.Errorf("negative %s: error = %v, want ErrInvalidConfig", name, err)
		}
	}
	if _, err := newPublisher(newFakeSink(), Config{DialTimeout: -1}); !errors.Is(err, ErrInvalidConfig) {
		t.Errorf("newPublisher with a negative timeout = %v, want ErrInvalidConfig", err)
	}
}
