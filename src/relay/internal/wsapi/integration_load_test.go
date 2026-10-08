package wsapi_test

import (
	"fmt"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// 中継層の簡易な負荷の確認：同時 20 接続（疑似のメディア 30 fps）。ゴルーチンとメモリが、接続数に対して線形で、小さいこと。
// 再エンコードをしないので、1 接続あたりの処理量は小さい（requirements.md 27 章）。-race で警告が出ないことも、この試験の目的。

// heapInUse は、ごみ集めのあとの、使用中のヒープ（バイト）。
func heapInUse() int64 {
	runtime.GC()
	runtime.GC()
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	return int64(stats.HeapAlloc)
}

func TestTwentyConcurrentBroadcastsAtThirtyFramesPerSecondScaleLinearly(t *testing.T) {
	const total = 20
	const mebibyte = 1 << 20
	env := newRelayEnv(t)
	baseGoroutines, baseHeap := countRelayGoroutines(), heapInUse()

	// 準備：時計を進める前に、20 本すべてを、RTMPS の接続まで進める。5 本の時点と、20 本の時点で、ゴルーチンとメモリを測る
	lives := make([]*live, 0, total)
	var goroutinesAt5, heapAt5 int64
	for n := 1; n <= total; n++ {
		lives = append(lives, env.prepareBroadcast(n))
		if n == 5 {
			goroutinesAt5, heapAt5 = int64(countRelayGoroutines()-baseGoroutines), heapInUse()-baseHeap
		}
	}
	env.clock.Advance(5 * time.Second)
	for _, l := range lives {
		env.confirmBroadcast(l)
	}

	// 送出：20 本が同時に、3 秒ぶん（映像 90 枚・音声約 130 枚。30 fps）を送る
	var wg sync.WaitGroup
	for _, l := range lives {
		wg.Add(1)
		go func() {
			defer wg.Done()
			l.pushMedia(90)
		}()
	}
	wg.Wait()
	for _, l := range lives {
		l.waitDelivered()
	}
	goroutinesAt20 := int64(countRelayGoroutines() - baseGoroutines)
	heapAt20 := heapInUse() - baseHeap

	// すべての接続で、受け口に届いたタグが、送ったとおり（映像・音声の数・時刻が戻らない）
	for _, l := range lives {
		tags := mediaOnly(l.peer.snapshot())
		if len(tags) != l.videoSent+l.audioSent {
			t.Fatalf("broadcast %d: the receiver got %d media tags; want %d", l.account, len(tags), l.videoSent+l.audioSent)
		}
		last := map[string]uint32{}
		for i, tag := range tags {
			if tag.ts < last[tag.kind] {
				t.Fatalf("broadcast %d: tag %d (%s) time %d went back from %d", l.account, i, tag.kind, tag.ts, last[tag.kind])
			}
			last[tag.kind] = tag.ts
		}
	}
	// 受領応答：20 本のそれぞれへ、自分の最新のメディア時刻
	for _, l := range lives {
		l.waitAcked()
	}

	// ゴルーチン：1 本あたりが小さく（上限を置く）、20 本は 5 本の 4 倍に収まる（線形）
	perBroadcast := goroutinesAt20 / total
	t.Logf("relay goroutines: %d (5 broadcasts), %d (20 broadcasts, streaming); heap: %.1f MiB (5), %.1f MiB (20)",
		goroutinesAt5, goroutinesAt20, float64(heapAt5)/mebibyte, float64(heapAt20)/mebibyte)
	if perBroadcast < 2 || perBroadcast > 12 {
		t.Errorf("%d relay goroutines per broadcast; want a small constant (2..12)", perBroadcast)
	}
	if goroutinesAt20 > 4*goroutinesAt5+int64(total) {
		t.Errorf("goroutines grew from %d (5 broadcasts) to %d (20 broadcasts); want about 4x (linear)", goroutinesAt5, goroutinesAt20)
	}
	// メモリ：1 本あたり 3 MiB 未満（受け口が記録するタグ・クライアントの受信を含む、試験全体の増え方）。20 本は 5 本の 4 倍に収まる
	if perHeap := heapAt20 / total; perHeap > 3*mebibyte {
		t.Errorf("%.1f MiB of heap per broadcast; want a small bound (under 3 MiB)", float64(perHeap)/mebibyte)
	}
	if heapAt20 > 4*heapAt5+8*mebibyte {
		t.Errorf("heap grew from %.1f MiB (5 broadcasts) to %.1f MiB (20 broadcasts); want about 4x (linear)", float64(heapAt5)/mebibyte, float64(heapAt20)/mebibyte)
	}

	// 終了：20 本とも、送出待ちを送り切って閉じ、ゴルーチンは、元に戻る
	for _, l := range lives {
		l.client.send(contract.FrameTypeEnd, false, 0, []byte(`{"reason":"user_stop"}`))
	}
	for _, l := range lives {
		if code := l.client.waitClosed(); code != 1000 {
			t.Errorf("broadcast %d: close code = %d; want 1000", l.account, code)
		}
	}
	eventually(t, "all sessions left the registry", func() bool { return env.relay.Registry().Count() == 0 })
	eventually(t, "all session_ended events arrived", func() bool {
		for _, l := range lives {
			if !contains(env.app.eventKinds(l.bid), "session_ended") {
				return false
			}
		}
		return true
	})
	eventually(t, fmt.Sprintf("the relay goroutines returned to the baseline (%d)", baseGoroutines), func() bool {
		return countRelayGoroutines() <= baseGoroutines
	})
	env.assertNoSecretsLogged()
}
