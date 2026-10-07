package rtmps

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yutopp/go-flv/tag"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/flv"
)

// 統合試験：go-rtmp のサーバー（TLS・自己署名）を受け口にして、Publisher が、実際の RTMPS で送出する。
// 実際の YouTube へは、接続しない。配信キーは、明らかなダミー。

// integrationVideoConfig は、AVCDecoderConfigurationRecord（契約 ws-protocol.md 5.3 の例と同じ形）。
func integrationVideoConfig() []byte {
	return []byte{
		0x01, 0x4D, 0x40, 0x1F, 0xFF, 0xE1, 0x00, 0x0F, 0x67, 0x4D, 0x40, 0x1F, 0x96, 0x54, 0x05, 0x01,
		0xED, 0x80, 0xA0, 0x40, 0x3C, 0x22, 0x11, 0x01, 0x00, 0x04, 0x68, 0xEE, 0x3C, 0x80,
	}
}

func integrationAudioConfig() []byte { return []byte{0x12, 0x10} }

func integrationProfile() flv.Profile {
	return flv.Profile{Width: 1280, Height: 720, Framerate: 30, VideoBitrateKbps: 4500, AudioBitrateKbps: 128, AudioSampleRateHz: 44100, AudioChannels: 2}
}

// integrationNALUs は、AVCC 形式の NAL 列（長さ 4 バイトの前置き + 中身。i で中身を変える）。
func integrationNALUs(i, size int) []byte {
	nalu := bytes.Repeat([]byte{byte(i)}, size)
	return append([]byte{byte(size >> 24), byte(size >> 16), byte(size >> 8), byte(size)}, nalu...)
}

// dialServer は、受け口へ接続した Publisher を返す。試験の終わりに、必ず Abort する。
func dialServer(t *testing.T, server *rtmpTestServer, cfg Config) *Publisher {
	t.Helper()
	if cfg.RootCAs == nil {
		cfg.RootCAs = server.roots
	}
	if cfg.PollInterval == 0 {
		cfg.PollInterval = 10 * time.Millisecond
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	publisher, err := Dial(ctx, server.destination(), StreamKey(dummyStreamKey), cfg)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	t.Cleanup(publisher.Abort)
	return publisher
}

// pace は、送出待ちが maxPendingMs 以下になるまで待つ（実時間で積む送り手の再現。受け口が健全なら、送出に追いつく）。
func pace(t *testing.T, p *Publisher, maxPendingMs int) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for p.PendingMs() > maxPendingMs {
		if time.Now().After(deadline) {
			t.Fatalf("the pending time stayed above %d ms (PendingMs = %d)", maxPendingMs, p.PendingMs())
		}
		time.Sleep(time.Millisecond)
	}
}

// waitClosed は、Publisher が終了する（Closed() が通知する）のを待つ。
func waitClosed(t *testing.T, p *Publisher) {
	t.Helper()
	select {
	case <-p.Closed():
	case <-time.After(10 * time.Second):
		t.Fatalf("Closed() was not signaled")
	}
}

func filterKind(records []record, kind string) []record {
	var out []record
	for _, r := range records {
		if r.kind == kind {
			out = append(out, r)
		}
	}
	return out
}

// checkBody は、(本体, エラー) を返す呼び出しを、そのまま渡せる補助（失敗なら、試験を止める）。
func checkBody(t *testing.T) func(body []byte, err error) []byte {
	return func(body []byte, err error) []byte {
		t.Helper()
		if err != nil {
			t.Fatalf("flv: %v", err)
		}
		return body
	}
}

// 映像・音声・メタデータが、時刻つきで、受け口へ届く。Muxer の出力を、そのまま送る（go-flv で読み戻して確かめる）。
func TestPublisherDeliversMuxerOutputToTheReceiver(t *testing.T) {
	server := newRTMPTestServer(t, testServerOptions{})
	logs := &syncBuffer{}
	p := dialServer(t, server, Config{Logger: slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug}))})

	check := checkBody(t)
	muxer := flv.NewMuxer()
	meta := check(muxer.Metadata(integrationProfile()))
	videoConfig := check(muxer.VideoConfig(integrationVideoConfig()))
	audioConfig := check(muxer.AudioConfig(integrationAudioConfig()))
	muxer.MarkProvisioned()

	var want []record
	var total uint64
	push := func(r record) {
		t.Helper()
		if err := write(p, r); err != nil {
			t.Fatalf("write %s ts %d: %v", r.kind, r.ts, err)
		}
		want = append(want, r)
		total += uint64(len(r.payload))
	}
	push(record{"meta", 0, meta})
	push(record{"video", 0, videoConfig})
	push(record{"audio", 0, audioConfig})
	const frames = 90 // 3 秒分
	for i := 0; i < frames; i++ {
		ts := uint32((i*1000 + 15) / 30)
		push(record{"video", ts, check(muxer.Video(i%30 == 0, integrationNALUs(i, 2000+i)))})
		push(record{"audio", ts, check(muxer.Audio(bytes.Repeat([]byte{byte(i)}, 100)))})
		push(record{"audio", ts + 16, check(muxer.Audio(bytes.Repeat([]byte{byte(i + 1)}, 100)))})
		pace(t, p, 500)
	}

	if err := p.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	session := server.session(0)
	eventually(t, "the receiver got every message", func() bool { return session.receivedCount() == len(want) })

	got := session.received()
	for _, kind := range []string{"meta", "video", "audio"} {
		sameRecords(t, filterKind(got, kind), filterKind(want, kind))
	}
	if sent := p.SentBytes(); sent != total {
		t.Errorf("SentBytes = %d, want %d", sent, total)
	}

	// 受け口が受け取った本体を、go-flv で読み戻す
	videos := filterKind(got, "video")
	var firstVideo tag.VideoData
	if err := tag.DecodeVideoData(bytes.NewReader(videos[0].payload), &firstVideo); err != nil {
		t.Fatalf("decode the first video message: %v", err)
	}
	if firstVideo.AVCPacketType != tag.AVCPacketTypeSequenceHeader || firstVideo.FrameType != tag.FrameTypeKeyFrame {
		t.Errorf("the first video message must be the decoder configuration (sequence header), got %+v", firstVideo)
	}
	keyframes := 0
	for _, r := range videos[1:] {
		var data tag.VideoData
		if err := tag.DecodeVideoData(bytes.NewReader(r.payload), &data); err != nil {
			t.Fatalf("decode a video message: %v", err)
		}
		if data.AVCPacketType != tag.AVCPacketTypeNALU {
			t.Errorf("a media frame has packet type %d", data.AVCPacketType)
		}
		if data.FrameType == tag.FrameTypeKeyFrame {
			keyframes++
		}
	}
	if keyframes != frames/30 {
		t.Errorf("key frames = %d, want %d", keyframes, frames/30)
	}
	var firstAudio tag.AudioData
	if err := tag.DecodeAudioData(bytes.NewReader(filterKind(got, "audio")[0].payload), &firstAudio); err != nil {
		t.Fatalf("decode the first audio message: %v", err)
	}
	if firstAudio.AACPacketType != tag.AACPacketTypeSequenceHeader {
		t.Errorf("the first audio message must be the decoder configuration, got %+v", firstAudio)
	}
	var script tag.ScriptData
	if err := tag.DecodeScriptData(bytes.NewReader(filterKind(got, "meta")[0].payload), &script); err != nil {
		t.Fatalf("decode the metadata: %v", err)
	}
	if width := script.Objects["onMetaData"]["width"]; width != float64(1280) {
		t.Errorf("onMetaData width = %v, want 1280", width)
	}

	// 接続の様子：アプリ名（URL のパス）・tcUrl・配信キー・SNI
	session.mu.Lock()
	connect, publishName, publishType := session.connect, session.publishName, session.publishType
	session.mu.Unlock()
	if connect.App != "live2" || connect.Type != "nonprivate" || connect.TCURL != fmt.Sprintf("rtmps://%s:%d/live2", testHost, server.port) {
		t.Errorf("connect = %+v", connect)
	}
	if publishName != dummyStreamKey || publishType != "live" {
		t.Errorf("publish = %q (%q), want the stream key and \"live\"", "<hidden>", publishType)
	}
	if names := server.seenServerNames(); len(names) != 1 || names[0] != testHost {
		t.Errorf("SNI = %v, want [%s] (connect by host name, never by IP address)", names, testHost)
	}

	// Close は、送り切ってから切断する。受け口は、接続の終わりを見る
	select {
	case <-session.closedCh:
	case <-time.After(5 * time.Second):
		t.Errorf("the receiver did not see the connection close")
	}
	if err := p.Err(); !errors.Is(err, ErrClosed) {
		t.Errorf("Err() = %v, want ErrClosed", err)
	}

	// 配信キーは、ログにも、Publisher の書式化にも、現れない
	for name, text := range map[string]string{"log": logs.String(), "String": p.String(), "%v": fmt.Sprintf("%v", p), "%+v": fmt.Sprintf("%+v", p), "%#v": fmt.Sprintf("%#v", p)} {
		if strings.Contains(text, dummyStreamKey) || strings.Contains(text, "SECRET") {
			t.Errorf("%s exposed the stream key: %s", name, text)
		}
	}
	if logs.String() == "" {
		t.Errorf("the publisher should leave a trace (a log line) when it stops")
	}
}

// Close は、送出待ちを送り切ってから切断する（回線の上で、1 件も欠けない）。
func TestCloseDeliversEverythingOverTheWire(t *testing.T) {
	server := newRTMPTestServer(t, testServerOptions{})
	p := dialServer(t, server, Config{})
	const frames = 200
	var want []record
	for i := 0; i < frames; i++ {
		r := record{"video", uint32(i * 33), bytes.Repeat([]byte{byte(i)}, 20*1024+i)}
		if err := write(p, r); err != nil {
			t.Fatalf("write %d: %v", i, err)
		}
		want = append(want, r)
		pace(t, p, 1000)
	}
	// 直前に積んだものが、まだ送出待ちに残っていても、Close が送り切る
	if err := p.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	session := server.session(0)
	eventually(t, "every frame received", func() bool { return session.receivedCount() == frames })
	sameRecords(t, session.received(), want)
	select {
	case <-session.closedCh:
	case <-time.After(5 * time.Second):
		t.Errorf("the receiver did not see the connection close")
	}
}

// 受け口が切断したら、書き込みが無くても Closed() が通知し、以後の書き込みは ErrClosed。
func TestServerDisconnectIsDetected(t *testing.T) {
	server := newRTMPTestServer(t, testServerOptions{})
	p := dialServer(t, server, Config{PublishRejectWindow: time.Nanosecond})
	if err := p.WriteVideo(0, payloadOf(100, 'v')); err != nil {
		t.Fatal(err)
	}
	session := server.session(0)
	eventually(t, "the first message received", func() bool { return session.receivedCount() == 1 })

	start := time.Now()
	session.closeConnection()
	select {
	case <-p.Closed():
	case <-time.After(5 * time.Second):
		t.Fatalf("Closed() was not signaled after the receiver closed the connection")
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Errorf("the disconnect was noticed after %v, want well under a second", elapsed)
	}
	err := p.Err()
	if !errors.Is(err, ErrDisconnected) || errors.Is(err, ErrPublishRejected) {
		t.Errorf("Err() = %v, want ErrDisconnected (a disconnect long after publish)", err)
	}
	if !errors.Is(err, io.EOF) {
		t.Errorf("Err() = %v, want the underlying io.EOF to be reachable with errors.Is", err)
	}
	if err := p.WriteVideo(33, payloadOf(1, 'x')); !errors.Is(err, ErrClosed) || !errors.Is(err, ErrDisconnected) {
		t.Errorf("write after the disconnect = %v, want ErrClosed wrapping ErrDisconnected", err)
	}
	waitTeardown(t, p)
}

// publish の直後の切断は、配信キーの不正・使用中の可能性として、ErrPublishRejected（go-rtmp は onStatus を処理しない）。
func TestRejectedPublishIsReportedAsPublishRejected(t *testing.T) {
	server := newRTMPTestServer(t, testServerOptions{rejectPublish: true})
	p := dialServer(t, server, Config{})
	select {
	case <-p.Closed():
	case <-time.After(5 * time.Second):
		t.Fatalf("Closed() was not signaled after the receiver rejected the publish")
	}
	err := p.Err()
	if !errors.Is(err, ErrPublishRejected) || errors.Is(err, ErrDisconnected) {
		t.Fatalf("Err() = %v, want ErrPublishRejected (and not ErrDisconnected)", err)
	}
	if err := p.WriteVideo(0, payloadOf(1, 'x')); !errors.Is(err, ErrClosed) || !errors.Is(err, ErrPublishRejected) {
		t.Errorf("write after the rejection = %v, want ErrClosed wrapping ErrPublishRejected", err)
	}
	if err := p.Close(); !errors.Is(err, ErrPublishRejected) {
		t.Errorf("Close = %v, want the cause (ErrPublishRejected)", err)
	}
	if strings.Contains(err.Error(), dummyStreamKey) {
		t.Errorf("the error exposed the stream key")
	}
}

// stalledServer は、2 件の映像を受けたあと、読み取りを止める受け口（回線の詰まりの再現）。release で再開する。
func stalledServer(t *testing.T) (*rtmpTestServer, func()) {
	t.Helper()
	release := make(chan struct{})
	var once sync.Once
	releaseAll := func() { once.Do(func() { close(release) }) }
	server := newRTMPTestServer(t, testServerOptions{onMessage: func(h *recordingHandler, kind string, count int) {
		if kind == "video" && count > 2 {
			<-release
		}
	}})
	t.Cleanup(releaseAll) // 受け口の後始末（server.close）より先に呼ばれる
	return server, releaseAll
}

// 受け口が読み取りを止めると、送出が詰まり、送出待ちが 3 秒分に達して ErrBufferOverflow。バッファを破棄して、接続を切る。
func TestBufferOverflowWhenTheReceiverStopsReading(t *testing.T) {
	server, release := stalledServer(t)
	p := dialServer(t, server, Config{PublishRejectWindow: time.Nanosecond})

	payload := bytes.Repeat([]byte{7}, 200*1024)
	var overflow error
	frames := 0
	for ; frames < 1000; frames++ {
		if err := p.WriteVideo(uint32(frames*33), payload); err != nil {
			overflow = err
			break
		}
		time.Sleep(time.Millisecond) // 実時間の 33 倍の速さで積む。健全な受け口なら、送出が追いつく
	}
	if !errors.Is(overflow, ErrBufferOverflow) {
		t.Fatalf("after %d frames the error is %v, want ErrBufferOverflow", frames, overflow)
	}
	if frames < 2 {
		t.Fatalf("the overflow came too early (frame %d)", frames)
	}
	select {
	case <-p.Closed():
	default:
		t.Fatalf("Closed() must be signaled by the time the overflow is reported")
	}
	if got := p.Err(); !errors.Is(got, ErrBufferOverflow) {
		t.Errorf("Err() = %v, want ErrBufferOverflow", got)
	}
	if got := p.PendingMs(); got != 0 {
		t.Errorf("PendingMs after the buffer was discarded = %d, want 0", got)
	}
	// 止まっていた書き込みを、接続を壊して解く（go-rtmp の Close が、止まっている書き込みを待つ 2 秒を、待たない）
	start := time.Now()
	waitTeardown(t, p)
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Errorf("the teardown took %v; the stalled write must be released by dropping the connection", elapsed)
	}

	// 受け口は、接続が切れたことを、読み取りを再開したあとに見る（カーネルのバッファに残っていた分は、読み切る）
	release()
	select {
	case <-server.session(0).closedCh:
	case <-time.After(5 * time.Second):
		t.Errorf("the receiver did not see the connection drop")
	}
}

// 実時間の 11 倍の速さで積んでも（媒体のビットレートは、実際の 4.6 Mbps ほど）、受け口が健全なら、上限に達しない。
func TestNoOverflowWhenTheReceiverKeepsUp(t *testing.T) {
	server := newRTMPTestServer(t, testServerOptions{})
	p := dialServer(t, server, Config{})
	payload := bytes.Repeat([]byte{7}, 10*1024)
	const frames = 150
	for i := 0; i < frames; i++ {
		if err := p.WriteVideo(uint32(i*33), payload); err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		time.Sleep(3 * time.Millisecond)
	}
	if err := p.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	session := server.session(0)
	eventually(t, "every frame received", func() bool { return session.receivedCount() == frames })
}

// Abort は、止まっている書き込みも解いて、直ちに切断する（接続を壊す）。
func TestAbortReleasesAStalledWriterImmediately(t *testing.T) {
	server, release := stalledServer(t)
	p := dialServer(t, server, Config{})
	payload := bytes.Repeat([]byte{7}, 200*1024)
	// 詰まるまで積む（カーネルのバッファが埋まり、書き込みのゴルーチンが止まると、送出待ちが増え始める。時刻は 1 件ごとに 1 ms）
	stalled := false
	for i := 0; i < 800 && !stalled; i++ {
		if err := p.WriteVideo(uint32(i), payload); err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		time.Sleep(time.Millisecond)
		stalled = p.PendingMs() >= 5
	}
	if !stalled {
		t.Fatalf("the stall was not reproduced: the receiver kept up with 800 frames of 200 KiB")
	}
	start := time.Now()
	p.Abort()
	// 接続を壊せば、ミリ秒で済む。壊さないと、go-rtmp の Close が、止まっている書き込みを 2 秒ほど待つ
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Errorf("Abort took %v while a write was stalled; the connection must be dropped at once", elapsed)
	}
	select {
	case <-p.Closed():
	default:
		t.Errorf("Closed() not signaled after Abort")
	}
	release()
	select {
	case <-server.session(0).closedCh:
	case <-time.After(5 * time.Second):
		t.Errorf("the receiver did not see the connection drop")
	}
}

// 映像・音声・メタを、別のゴルーチンから並行に呼べる（実際の RTMPS の上で。-race で確かめる）。
func TestConcurrentWritersOverRTMPS(t *testing.T) {
	server := newRTMPTestServer(t, testServerOptions{})
	p := dialServer(t, server, Config{})
	const perKind = 300
	var wg sync.WaitGroup
	errs := make(chan error, 3)
	run := func(name string, send func(i int) error) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < perKind; i++ {
				if err := send(i); err != nil {
					errs <- fmt.Errorf("%s %d: %w", name, i, err)
					return
				}
				if i%20 == 0 {
					time.Sleep(time.Millisecond)
				}
			}
		}()
	}
	run("video", func(i int) error { return p.WriteVideo(uint32(i), bytes.Repeat([]byte{'v'}, 500+i)) })
	run("audio", func(i int) error { return p.WriteAudio(uint32(i), bytes.Repeat([]byte{'a'}, 100+i%10)) })
	run("meta", func(i int) error { return p.WriteMeta(bytes.Repeat([]byte{'m'}, 30+i%5)) })
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	if err := p.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	session := server.session(0)
	eventually(t, "every message received", func() bool { return session.receivedCount() == 3*perKind })
	got := session.received()
	for _, kind := range []string{"video", "audio", "meta"} {
		records := filterKind(got, kind)
		if len(records) != perKind {
			t.Fatalf("%s: received %d, want %d", kind, len(records), perKind)
		}
		for i, r := range records {
			if kind != "meta" && r.ts != uint32(i) {
				t.Fatalf("%s %d arrived with ts %d (the order within a kind must be kept)", kind, i, r.ts)
			}
		}
	}
}

// 送出が失敗したあとは、新しい Publisher を Dial し直せる（呼び出し側が再接続する）。古い Publisher は、閉じたまま。
func TestRedialAfterTheConnectionDropped(t *testing.T) {
	server := newRTMPTestServer(t, testServerOptions{})
	first := dialServer(t, server, Config{PublishRejectWindow: time.Nanosecond})
	if err := first.WriteVideo(0, payloadOf(10, 'a')); err != nil {
		t.Fatal(err)
	}
	server.session(0).closeConnection()
	select {
	case <-first.Closed():
	case <-time.After(5 * time.Second):
		t.Fatalf("the first publisher did not notice the disconnect")
	}

	second := dialServer(t, server, Config{})
	if err := second.WriteVideo(0, payloadOf(10, 'b')); err != nil {
		t.Fatalf("the second publisher: %v", err)
	}
	if err := second.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	eventually(t, "the second session received its frame", func() bool { return server.session(1).receivedCount() == 1 })
	if server.sessionCount() != 2 {
		t.Errorf("sessions = %d, want 2", server.sessionCount())
	}
	if err := first.WriteVideo(1, payloadOf(1, 'x')); !errors.Is(err, ErrClosed) {
		t.Errorf("the first publisher must stay closed: %v", err)
	}
}

// 配信キーは、どの失敗でも、エラー・ログへ現れない（拒否・切断・上限・接続の失敗）。
func TestStreamKeyNeverAppearsInErrorsOrLogs(t *testing.T) {
	logs := &syncBuffer{}
	logger := slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	var texts []string
	collect := func(err error) {
		if err != nil {
			texts = append(texts, err.Error(), fmt.Sprintf("%+v", err), fmt.Sprintf("%#v", err), fmt.Sprintf("%v", errors.Unwrap(err)))
		}
	}

	// 1. publish の拒否
	rejecting := newRTMPTestServer(t, testServerOptions{rejectPublish: true})
	p1 := dialServer(t, rejecting, Config{Logger: logger})
	waitClosed(t, p1)
	collect(p1.Err())
	collect(p1.WriteVideo(0, payloadOf(1, 'x')))
	collect(p1.Close())

	// 2. 受け口の切断
	healthy := newRTMPTestServer(t, testServerOptions{})
	p2 := dialServer(t, healthy, Config{Logger: logger, PublishRejectWindow: time.Nanosecond})
	_ = p2.WriteVideo(0, payloadOf(10, 'a'))
	healthy.session(0).closeConnection()
	waitClosed(t, p2)
	collect(p2.Err())
	collect(p2.Close())

	// 3. 送出待ちの上限
	stalled, release := stalledServer(t)
	p3 := dialServer(t, stalled, Config{Logger: logger})
	for i := 0; i < 1000; i++ {
		if err := p3.WriteVideo(uint32(i*33), bytes.Repeat([]byte{1}, 200*1024)); err != nil {
			collect(err)
			break
		}
		time.Sleep(time.Millisecond)
	}
	collect(p3.Err())
	collect(p3.Close())
	release()

	// 4. 接続の失敗（証明書を信頼しない）
	untrusted := newRTMPTestServer(t, testServerOptions{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, err := Dial(ctx, untrusted.destination(), StreamKey(dummyStreamKey), Config{Logger: logger})
	if err == nil {
		t.Fatalf("a certificate that is not trusted must be refused")
	}
	collect(err)

	// 5. 検証の失敗
	collect(StreamKey("bad key with spaces " + dummyStreamKey).Validate())
	_, err = Dial(ctx, untrusted.destination(), StreamKey(" "+dummyStreamKey), Config{Logger: logger})
	collect(err)

	if len(texts) < 10 {
		t.Fatalf("only %d error texts were collected; the scenarios did not run", len(texts))
	}
	for _, text := range texts {
		if strings.Contains(text, dummyStreamKey) || strings.Contains(text, "SECRET") {
			t.Errorf("an error exposed the stream key: %s", text)
		}
	}
	if logs.String() == "" {
		t.Errorf("the scenarios left no log")
	}
	if strings.Contains(logs.String(), dummyStreamKey) || strings.Contains(logs.String(), "SECRET") {
		t.Errorf("the log exposed the stream key:\n%s", logs.String())
	}
}

// ---- 閉じ方：受け口が閉じるまで待つ ----

// sendSomeMessages は、映像を n 件、積む（本文は、任意のバイト列。受け口は、中身を見ずに、記録する）。
func sendSomeMessages(t *testing.T, p *Publisher, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		if err := p.WriteVideo(uint32(i*33), payloadOf(2000, byte(i))); err != nil {
			t.Fatalf("WriteVideo %d: %v", i, err)
		}
		pace(t, p, 500)
	}
}

// Close は、送り切ったあと、受け口が閉じるまで（FIN を見るまで）待ってから戻る。受け口が閉じたことは、送ったものを、受け口が
// すべて受け取ったことの確認になる（読んでいない受信を残したまま閉じて、RST で最後の部分を捨てさせない）。
// 受け口の側の後始末が遅れても、戻るのは、受け口が閉じたあと。
func TestPublisherCloseWaitsForTheReceiverToClose(t *testing.T) {
	const receiverDelay = 400 * time.Millisecond
	server := newRTMPTestServer(t, testServerOptions{onClose: func(*recordingHandler) { time.Sleep(receiverDelay) }})
	p := dialServer(t, server, Config{CloseLinger: 20 * time.Second})
	const messages = 40
	sendSomeMessages(t, p, messages)

	start := time.Now()
	if err := p.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if elapsed := time.Since(start); elapsed < receiverDelay {
		t.Errorf("Close returned after %v, before the receiver closed its side (%v)", elapsed, receiverDelay)
	}
	// 受け口が閉じたあとなので、受け口は、すべてのメッセージを処理済み
	if got := server.session(0).receivedCount(); got != messages {
		t.Errorf("the receiver had %d of %d messages when Close returned", got, messages)
	}
}

// 受け口が閉じなくても、Close は、CloseLinger で待つのをやめる（有限の時間で終わる）。送り切っているので、失敗ではない。
func TestPublisherCloseStopsWaitingForAReceiverThatDoesNotClose(t *testing.T) {
	release := make(chan struct{})
	server := newRTMPTestServer(t, testServerOptions{onClose: func(*recordingHandler) {
		select {
		case <-release:
		case <-time.After(20 * time.Second):
		}
	}})
	t.Cleanup(func() { close(release) }) // 受け口の後始末（server.close）より先に実行される
	const linger = 300 * time.Millisecond
	p := dialServer(t, server, Config{CloseLinger: linger})
	sendSomeMessages(t, p, 10)

	start := time.Now()
	if err := p.Close(); err != nil {
		t.Errorf("Close = %v, want nil (everything was sent; the receiver not closing is not a failure)", err)
	}
	elapsed := time.Since(start)
	if elapsed < linger {
		t.Errorf("Close returned after %v, before the linger %v", elapsed, linger)
	}
	if elapsed > linger+4*time.Second {
		t.Errorf("Close took %v with a linger of %v", elapsed, linger)
	}
}
