package rtmps

import (
	"errors"
	"fmt"
	"io"
	"math/rand"
	"strings"
	"testing"
	"time"
)

// 性質の試験：操作の列（書き込み・回線の詰まりと再開・書き込みの失敗・切断・Abort）を、固定のシードの乱数で作り、どの列でも、
// 次の性質が成り立つこと。
//   - 受け口へ届いたものは、受理した書き込み（エラーを返さなかったもの）の、先頭からの連続した部分（順序を保ち、欠けや重複が無い）
//   - 失敗も Abort も無く、Close が nil を返したなら、受理したものが、すべて届いている
//   - 終了したあとは、Closed()・Err() が終了を示し、バッファは破棄され、接続は 1 度だけ閉じられ、ゴルーチンは残らない
//   - 送出量（SentBytes）は、届いたものの本文の合計に一致する

type scenarioResult struct {
	accepted []record
	closeErr error
	aborted  bool
	injected bool // 書き込みの失敗・切断を起こした
}

func runRandomScenario(t *testing.T, seed int64) scenarioResult {
	t.Helper()
	rng := rand.New(rand.NewSource(seed))
	sink := newFakeSink()
	stalled := rng.Intn(2) == 0
	if stalled {
		sink.limit()
	}
	p, err := newPublisher(sink, Config{PollInterval: 3 * time.Millisecond, PublishRejectWindow: time.Nanosecond, CloseTimeout: 150 * time.Millisecond})
	if err != nil {
		t.Fatalf("newPublisher: %v", err)
	}
	t.Cleanup(p.Abort)

	// 操作の種類の許可：0 = 書き込みと詰まりだけ、1 = 失敗・切断も、2 = Abort も、3 = すべて
	mode := rng.Intn(4)
	allowInjection := mode == 1 || mode == 3
	allowAbort := mode == 2 || mode == 3

	var result scenarioResult
	kinds := []string{"video", "audio", "meta"}
	var ts uint32
	steps := 30 + rng.Intn(250)
loop:
	for i := 0; i < steps; i++ {
		switch op := rng.Intn(100); {
		case op < 72: // 書き込み
			kind := kinds[rng.Intn(len(kinds))]
			if rng.Intn(25) == 0 {
				ts += uint32(rng.Intn(4000)) // 大きく進める（上限に達し得る）
			} else {
				ts += uint32(rng.Intn(60))
			}
			r := record{kind: kind, ts: ts, payload: payloadOf(1+rng.Intn(300), byte(i))}
			if kind == "meta" {
				r.ts = 0
			}
			err := write(p, r)
			switch {
			case err == nil:
				result.accepted = append(result.accepted, r)
			case errors.Is(err, ErrClosed) || errors.Is(err, ErrBufferOverflow):
				break loop // 閉じた（上限・失敗・Abort）。以後の書き込みは、すべて ErrClosed
			default:
				t.Fatalf("seed %d step %d: unexpected write error: %v", seed, i, err)
			}
		case op < 82: // 詰まりを 1〜4 件分、解く
			if stalled {
				sink.grant(1 + rng.Intn(4))
			}
		case op < 88: // 詰まりを、すべて解く
			if stalled {
				sink.unblock()
				stalled = false
			}
		case op < 91: // 書き込みの失敗
			if allowInjection && rng.Intn(3) == 0 {
				sink.failWith(errors.New("write: broken pipe"))
				result.injected = true
			}
		case op < 94: // 切断
			if allowInjection && rng.Intn(3) == 0 {
				sink.breakConnection(io.EOF)
				result.injected = true
			}
		case op < 96: // Abort
			if allowAbort && rng.Intn(4) == 0 {
				p.Abort()
				result.aborted = true
				break loop
			}
		default:
			time.Sleep(time.Duration(rng.Intn(3)) * time.Millisecond)
		}
	}

	result.closeErr = p.Close()
	waitTeardown(t, p)

	// 性質：終了している
	if !isClosed(p) {
		t.Fatalf("seed %d: Closed() not signaled after Close", seed)
	}
	if p.Err() == nil {
		t.Fatalf("seed %d: Err() is nil after Close", seed)
	}
	if got := p.PendingMs(); got != 0 {
		t.Fatalf("seed %d: PendingMs after the end = %d, want 0", seed, got)
	}
	p.mu.Lock()
	queueLeft, bytesLeft := len(p.queue), p.queuedBytes
	p.mu.Unlock()
	if queueLeft != 0 || bytesLeft != 0 {
		t.Fatalf("seed %d: the buffer was not discarded (%d messages, %d bytes)", seed, queueLeft, bytesLeft)
	}
	if err := write(p, record{kind: "video", ts: ts + 1, payload: []byte{1}}); !errors.Is(err, ErrClosed) {
		t.Fatalf("seed %d: write after the end = %v, want ErrClosed", seed, err)
	}

	// 性質：接続は、1 度だけ閉じられ、壊すのは、高々 1 度
	order := sink.callOrder()
	closes, kills := 0, 0
	for _, call := range order {
		switch call {
		case "close":
			closes++
		case "kill":
			kills++
		}
	}
	if closes != 1 || kills > 1 || order[len(order)-1] != "close" {
		t.Fatalf("seed %d: sink calls = %v, want one close (last) and at most one kill", seed, order)
	}

	// 性質：届いたものは、受理した書き込みの先頭からの連続した部分
	delivered := sink.records()
	if len(delivered) > len(result.accepted) {
		t.Fatalf("seed %d: delivered %d messages but only %d were accepted", seed, len(delivered), len(result.accepted))
	}
	sameRecords(t, delivered, result.accepted[:len(delivered)])

	// 性質：送出量
	var total uint64
	for _, r := range delivered {
		total += uint64(len(r.payload))
	}
	if got := p.SentBytes(); got != total {
		t.Fatalf("seed %d: SentBytes = %d, want %d", seed, got, total)
	}

	// 性質：失敗も Abort も無く、Close が nil なら、すべて届いている
	if result.closeErr == nil && !result.aborted && !result.injected && len(delivered) != len(result.accepted) {
		t.Fatalf("seed %d: Close returned nil but only %d of %d accepted messages were delivered", seed, len(delivered), len(result.accepted))
	}
	// 性質：Close の失敗は、決まった原因だけ
	if result.closeErr != nil {
		known := errors.Is(result.closeErr, ErrDrainTimeout) || errors.Is(result.closeErr, ErrDisconnected) || errors.Is(result.closeErr, ErrBufferOverflow)
		if !known {
			t.Fatalf("seed %d: Close returned an unexpected error: %v", seed, result.closeErr)
		}
	}
	waitNoPublisherGoroutines(t)
	return result
}

func TestPublisherRandomizedOperations(t *testing.T) {
	outcomes := map[string]int{}
	for seed := int64(1); seed <= 120; seed++ {
		t.Run(fmt.Sprintf("seed_%d", seed), func(t *testing.T) {
			result := runRandomScenario(t, seed)
			switch {
			case result.aborted:
				outcomes["abort"]++
			case result.injected:
				outcomes["injected failure"]++
			case result.closeErr == nil:
				outcomes["clean close"]++
			default:
				outcomes["other close error"]++
			}
		})
	}
	// 空振りの防止：どの終わり方も、実際に起きている
	for _, name := range []string{"abort", "injected failure", "clean close"} {
		if outcomes[name] == 0 {
			t.Errorf("no scenario ended with %q; the generated scripts do not cover it (%v)", name, outcomes)
		}
	}
	if t.Failed() {
		return
	}
	t.Logf("scenario outcomes: %s", strings.TrimSpace(fmt.Sprint(outcomes)))
}
