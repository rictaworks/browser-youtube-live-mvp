package rtmps

import (
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

// 試験用の疑似の sink。RTMP の接続を使わずに、Publisher の送出キュー・上限・閉じ方を、時計を待たずに確かめる。
// 書き込みを、許可（grant）が出るまで止められる（回線の詰まりの再現）。kill は、止まっている書き込みを解く
// （実際の接続を、shutdown で壊すのと同じ）。

type record struct {
	kind    string // "video"・"audio"・"meta"
	ts      uint32
	payload []byte
}

type fakeSink struct {
	mu        sync.Mutex
	recorded  []record
	permits   chan struct{} // nil なら、書き込みは止まらない。非 nil なら、書き込みごとに 1 つの許可を受け取る（閉じたら、止まらない）
	killCh    chan struct{}
	killOnce  sync.Once
	failErr   error // 非 nil なら、以後の書き込みが、このエラーで失敗する
	connErr   error // 非 nil なら、connectionError が返す
	closeErr  error
	closeGate chan struct{} // 非 nil なら、close は、これが閉じるまで戻らない（後始末が終わらない状況の再現）
	order     []string      // "kill"・"close" の呼ばれた順
}

func newFakeSink() *fakeSink {
	return &fakeSink{killCh: make(chan struct{})}
}

// errKilled は、kill された sink の書き込みが返すエラー（定数。グローバル変数を持たない）。
const errKilled Error = "fake sink: killed"

// limit は、以後の書き込みを、許可が出るまで止める。
func (f *fakeSink) limit() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.permits = make(chan struct{}, 1<<16)
}

// grant は、止まっている書き込みを、n 回分、通す（limit のあと）。
func (f *fakeSink) grant(n int) {
	f.mu.Lock()
	permits := f.permits
	f.mu.Unlock()
	for i := 0; i < n; i++ {
		permits <- struct{}{}
	}
}

// unblock は、書き込みの制限をやめる（止まっているものも、以後のものも通す）。
func (f *fakeSink) unblock() {
	f.mu.Lock()
	permits := f.permits
	f.mu.Unlock()
	if permits != nil {
		close(permits)
	}
}

func (f *fakeSink) failWith(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.failErr = err
}

func (f *fakeSink) breakConnection(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.connErr = err
}

func (f *fakeSink) records() []record {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]record(nil), f.recorded...)
}

func (f *fakeSink) callOrder() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.order...)
}

func (f *fakeSink) write(kind string, ts uint32, payload []byte) error {
	f.mu.Lock()
	permits := f.permits
	f.mu.Unlock()
	if permits != nil {
		select {
		case <-permits:
		case <-f.killCh:
			return errKilled
		}
	}
	select {
	case <-f.killCh:
		return errKilled
	default:
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.failErr != nil {
		return f.failErr
	}
	f.recorded = append(f.recorded, record{kind: kind, ts: ts, payload: payload})
	return nil
}

func (f *fakeSink) writeVideo(ts uint32, payload []byte) error { return f.write("video", ts, payload) }
func (f *fakeSink) writeAudio(ts uint32, payload []byte) error { return f.write("audio", ts, payload) }
func (f *fakeSink) writeMeta(payload []byte) error             { return f.write("meta", 0, payload) }

func (f *fakeSink) connectionError() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.connErr
}

func (f *fakeSink) kill() {
	f.mu.Lock()
	f.order = append(f.order, "kill")
	f.mu.Unlock()
	f.killOnce.Do(func() { close(f.killCh) })
}

func (f *fakeSink) close() error {
	f.mu.Lock()
	f.order = append(f.order, "close")
	gate := f.closeGate
	closeErr := f.closeErr
	f.mu.Unlock()
	if gate != nil {
		<-gate
	}
	return closeErr
}

// holdClose は、以後の close を、返されたチャネルが閉じるまで止める（後始末が終わらない状況の再現）。
func (f *fakeSink) holdClose() (release func()) {
	gate := make(chan struct{})
	f.mu.Lock()
	f.closeGate = gate
	f.mu.Unlock()
	var once sync.Once
	return func() { once.Do(func() { close(gate) }) }
}

// --- 試験の補助 ---

// eventually は、cond が真になるまで待つ（上限を過ぎたら、試験を失敗させる）。
func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("timed out waiting for: %s", what)
}

// newTestPublisher は、疑似の sink で Publisher を作る。試験の終わりに、必ず Abort する（ゴルーチンを残さない）。
// 切断の検知は 5 ms 間隔。publish 直後の切断の窓は、既定で 1 ナノ秒（どの切断も ErrDisconnected になる）。
// 拒否（ErrPublishRejected）に分類したい試験だけが、窓を長くする。
func newTestPublisher(t *testing.T, sink *fakeSink, cfg Config) *Publisher {
	t.Helper()
	if cfg.PollInterval == 0 {
		cfg.PollInterval = 5 * time.Millisecond
	}
	if cfg.PublishRejectWindow == 0 {
		cfg.PublishRejectWindow = time.Nanosecond
	}
	publisher, err := newPublisher(sink, cfg)
	if err != nil {
		t.Fatalf("newPublisher: %v", err)
	}
	t.Cleanup(func() { publisher.Abort() })
	return publisher
}

// waitTeardown は、後始末（接続の切断・ゴルーチンの終了）が済むのを待つ。
func waitTeardown(t *testing.T, publisher *Publisher) {
	t.Helper()
	select {
	case <-publisher.done:
	case <-time.After(5 * time.Second):
		t.Fatalf("the teardown did not finish")
	}
}

// goroutinesWith は、いま動いているゴルーチンのうち、スタックに、いずれかの印を含むものの数。
func goroutinesWith(markers ...string) int {
	buffer := make([]byte, 1<<20)
	buffer = buffer[:runtime.Stack(buffer, true)]
	count := 0
	for _, stack := range strings.Split(string(buffer), "\n\n") {
		for _, marker := range markers {
			if strings.Contains(stack, marker) {
				count++
				break
			}
		}
	}
	return count
}

// publisherGoroutines は、いま動いている、Publisher の書き込み・見張りのゴルーチンの数。
func publisherGoroutines() int {
	return goroutinesWith("rtmps.(*Publisher).writeLoop", "rtmps.(*Publisher).monitor")
}

// dialWorkers は、いま動いている、接続の試行のゴルーチンの数。
// go-rtmp の connect・createStream は、応答が来ないと、待ち続けて、解けない（接続を閉じても）。そのため、応答が来ない受け口との
// 接続の試行は、ゴルーチンを 1 つ残す（既知の制約）。その試験のあとも残るので、数は、試験の前の値と比べる。
func dialWorkers() int {
	return goroutinesWith("rtmps.(*dialAttempt).run")
}

// waitNoPublisherGoroutines は、Publisher のゴルーチンが残っていないことを確かめる（リークの検知）。
func waitNoPublisherGoroutines(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if publisherGoroutines() == 0 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("%d publisher goroutines are still running", publisherGoroutines())
}

// waitDialWorkersAtMost は、接続の試行のゴルーチンが、baseline 以下に戻ることを確かめる。
func waitDialWorkersAtMost(t *testing.T, baseline int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if dialWorkers() <= baseline {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("%d dial workers are still running (baseline %d)", dialWorkers(), baseline)
}
