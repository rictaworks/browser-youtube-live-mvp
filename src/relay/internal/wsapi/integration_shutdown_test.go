package wsapi_test

import (
	"context"
	"errors"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/server"
)

// 中継層の結合試験：正常停止（SIGTERM・SIGINT。ここでは、Serve の context の取り消し、または Shutdown の呼び出しで再現する）。

// 新しい接続を受け付けず、既存のセッションを閉じる。RTMPS は送出待ちを送り切ってから切断し、事象 session_ended をアプリケーションへ送る
func TestShutdownClosesEverySessionGracefullyAndFlushesTheEvents(t *testing.T) {
	env := newRelayEnv(t)
	env.rtmp.setOnRecord(func(string, int) { time.Sleep(time.Millisecond) }) // 受け口が少し遅い：送出待ちが、すぐには空にならない
	first, second := env.prepareBroadcast(1), env.prepareBroadcast(2)
	env.clock.Advance(5 * time.Second)
	env.confirmBroadcast(first)
	env.confirmBroadcast(second)
	for _, l := range []*live{first, second} {
		l.pushMedia(80)
	}
	// 送ったフレームが取り込みセッションに処理された印：受領応答が、最後のメディア時刻を示す（受け口へは、まだ全部は届いていない）
	for _, l := range []*live{first, second} {
		l.waitAcked()
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	started := time.Now()
	if err := env.relay.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown() error = %v; want nil", err)
	}
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Errorf("Shutdown took %v", elapsed)
	}

	for _, l := range []*live{first, second} {
		// 送り切ってから切断した：ブラウザが送ったすべてのタグが、受け口に届いている
		want := 3 + l.videoSent + l.audioSent
		if got := l.peer.count(); got != want {
			t.Errorf("broadcast %d: the receiver got %d tags; want all %d (the pending media must be sent before the cut)", l.account, got, want)
		}
		eventually(t, "the receiver saw the connection close", l.peer.isClosed)
		// ブラウザへは、致命通知 internal_error（復帰を試みる）のあと、通常の切断
		l.client.waitFor(contract.FrameTypeFatal, fatalIs("internal_error"))
		if code := l.client.waitClosed(); code != 1000 {
			t.Errorf("broadcast %d: close code = %d; want 1000", l.account, code)
		}
		// 事象 session_ended は、Shutdown が戻る前にアプリケーションへ届いている
		if kinds := env.app.eventKinds(l.bid); !contains(kinds, "session_ended") {
			t.Errorf("broadcast %d: events = %v; want session_ended to be flushed before Shutdown returns", l.account, kinds)
		}
	}
	if n := env.relay.Registry().Count(); n != 0 {
		t.Errorf("%d ingest sessions remain", n)
	}
	if n := env.relay.WebSocket().Active(); n != 0 {
		t.Errorf("%d WebSocket connections remain", n)
	}
	// 新しい接続は受け付けない
	_, response, err := websocket.DefaultDialer.Dial(env.wsURL(), nil)
	if err == nil {
		t.Fatal("a new connection was accepted after the shutdown")
	}
	if response == nil || response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("response = %v; want HTTP 503", response)
	}
	env.assertNoSecretsLogged()
}

// 猶予時間を超えたら中止する：受け口が読まず、送出待ちを送り切れないとき、送り切るのを待たずに、RTMPS を直ちに切る
// （Close を Abort へ格上げする。Close の最悪は約 17 秒）。ゴルーチンが残らない
func TestShutdownAbortsAStalledDrainWhenTheGraceIsExceeded(t *testing.T) {
	env := newRelayEnv(t, func(d *server.Deps) { d.FlushReserve = 100 * time.Millisecond })
	l := env.startBroadcast(1)
	l.sendMedia(30)

	// 受け口が、読むのを止める（回線の詰まり）。release で再開する
	release := make(chan struct{})
	var once sync.Once
	var received atomic.Int64
	env.rtmp.setOnRecord(func(kind string, _ int) {
		if kind == "video" && received.Add(1) > 1 {
			<-release
		}
	})
	t.Cleanup(func() { once.Do(func() { close(release) }) }) // env の後始末（Shutdown）より先に実行される

	// 大きな映像（1.9 MB）を、1 枚ずつ送る。メディアの時刻は 1 ミリ秒ずつ（送出待ちの「時間」は増えない）。時計は、1 枚ごとに
	// 2 秒進める（受信量の上限 9,000 kbps = 10 秒で 11.25 MB を超えず、映像・音声の途絶の監視 5 秒にも掛からない）。
	// カーネルの緩衝に収まらない量を積むと、受け口へ書く役が止まり、送出待ちが残る
	videoUs, audioUs := l.lastVideoUs(), l.lastAudioUs()
	for i := 0; i < 6; i++ {
		audioUs += audioTimeUs(1)
		videoUs += 1000
		l.client.send(contract.FrameTypeAudio, false, audioUs, audioPayload(i, 40))
		if err := l.client.tryRaw(bigVideo(videoUs, false, 1_900_000)); err != nil {
			t.Fatalf("write: %v", err)
		}
		time.Sleep(20 * time.Millisecond) // 送った 1.9 MB が処理されるのを、少し待つ（待たなくても、次の受領応答で確かめる）
		l.waitAckedAt(videoUs, audioUs)   // 取り込みセッションが処理した（時計は 0.5 秒以上進む）
		env.clock.Advance(1500 * time.Millisecond)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 600*time.Millisecond)
	defer cancel()
	started := time.Now()
	err := env.relay.Shutdown(ctx)
	elapsed := time.Since(started)
	t.Logf("Shutdown took %v", elapsed)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Shutdown() error = %v after %v; want it to report that the grace period was exceeded", err, elapsed)
	}
	// 強制に切り替えなければ、Close は、送り切れないまま CloseTimeout（5 秒）を待ち、そのあと、書き込みのゴルーチンの終了（go-rtmp が
	// 前のメッセージの完了を待つ 5 秒）が続く（約 10 秒）。強制に切り替えると、猶予（0.6 秒）のあと、後始末の 2〜5 秒で済む
	// （後始末は、go-rtmp の内部の待ちで、中継からは縮められない）
	if elapsed > 8*time.Second {
		t.Errorf("Shutdown took %v; want it to stop shortly after the grace period (600ms) plus the teardown, not wait for the stalled drain (5s) and then the writer (5s)", elapsed)
	}
	if n := env.relay.Registry().Count(); n != 0 {
		t.Errorf("%d ingest sessions remain after the forced stop", n)
	}
	if n := env.relay.WebSocket().Active(); n != 0 {
		t.Errorf("%d WebSocket connections remain after the forced stop", n)
	}
	l.client.waitFor(contract.FrameTypeFatal, fatalIs("internal_error"))
	once.Do(func() { close(release) })
	assertNoLeftoverGoroutines(t)
}

// Serve は、context が終わる（SIGTERM・SIGINT）と、停止の手順に入り、戻る。HTTP の待ち受けも閉じる
func TestServeStopsGracefullyWhenTheContextIsCancelled(t *testing.T) {
	env := newRelayEnv(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	served := make(chan error, 1)
	go func() { served <- env.relay.Serve(ctx, listener) }()
	env.wsURLOverride = "ws://" + listener.Addr().String() + "/ws"

	l := env.startBroadcast(1)
	l.sendMedia(30)

	cancel() // SIGTERM
	select {
	case err := <-served:
		if err != nil {
			t.Fatalf("Serve() error = %v; want nil after a requested stop", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Serve did not return after the context was cancelled")
	}
	l.client.waitFor(contract.FrameTypeFatal, fatalIs("internal_error"))
	if code := l.client.waitClosed(); code != 1000 {
		t.Errorf("close code = %d; want 1000", code)
	}
	eventually(t, "the receiver saw the connection close", l.peer.isClosed)
	if !contains(env.app.eventKinds(l.bid), "session_ended") {
		t.Errorf("events = %v; want session_ended to be flushed before Serve returns", env.app.eventKinds(l.bid))
	}
	if _, err := http.Get("http://" + listener.Addr().String() + "/health"); err == nil {
		t.Error("the listener still accepts connections after the stop")
	}
	env.assertNoSecretsLogged()
}

// 起動直後（セッションが無い）の停止も、速やかに終わる
func TestShutdownWithoutAnySessionIsImmediate(t *testing.T) {
	env := newRelayEnv(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	started := time.Now()
	if err := env.relay.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown() error = %v", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Errorf("Shutdown took %v with nothing to close", elapsed)
	}
}
