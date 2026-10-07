package rtmps

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"sync"
	"testing"
	"time"
)

// Dial：接続全体の期限・取り消し・TLS の検証・不正な引数。go-rtmp の Dial 系は context を取らず、RTMP のハンドシェイクに
// タイムアウトが無く、connect・createStream は応答を待ち続けるため、期限で接続を閉じる監視を置く（ソケットを shutdown で壊す）。

func dialWith(ctx context.Context, dest ValidatedDestination, cfg Config) (*Publisher, error) {
	return Dial(ctx, dest, StreamKey(dummyStreamKey), cfg)
}

func TestDialRejectsInvalidArgumentsBeforeTouchingTheNetwork(t *testing.T) {
	server := newRTMPTestServer(t, testServerOptions{})
	valid := server.destination()
	cases := []struct {
		name string
		call func() error
		want error
	}{
		{"検証を通っていない送出先（零値）", func() error {
			_, err := dialWith(context.Background(), ValidatedDestination{}, Config{RootCAs: server.roots})
			return err
		}, ErrInvalidDestination},
		{"空の配信キー", func() error {
			_, err := Dial(context.Background(), valid, "", Config{RootCAs: server.roots})
			return err
		}, ErrInvalidStreamKey},
		{"空白を含む配信キー", func() error {
			_, err := Dial(context.Background(), valid, "dummy key", Config{RootCAs: server.roots})
			return err
		}, ErrInvalidStreamKey},
		{"負の期限", func() error {
			_, err := dialWith(context.Background(), valid, Config{DialTimeout: -time.Second, RootCAs: server.roots})
			return err
		}, ErrInvalidConfig},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if err := c.call(); !errors.Is(err, c.want) {
				t.Fatalf("Dial error = %v, want %v", err, c.want)
			}
		})
	}
	time.Sleep(50 * time.Millisecond)
	if got := server.sessionCount(); got != 0 {
		t.Errorf("the receiver saw %d connections; an invalid call must not reach the network", got)
	}
}

func TestDialWithACanceledContextDoesNotConnect(t *testing.T) {
	server := newRTMPTestServer(t, testServerOptions{})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := dialWith(ctx, server.destination(), Config{RootCAs: server.roots})
	if !errors.Is(err, ErrDialFailed) || !errors.Is(err, context.Canceled) {
		t.Fatalf("Dial error = %v, want ErrDialFailed wrapping context.Canceled", err)
	}
	time.Sleep(50 * time.Millisecond)
	if got := server.sessionCount(); got != 0 {
		t.Errorf("the receiver saw %d connections after a canceled context", got)
	}
}

// 証明書の検証は、既定で行う。省略できるのは、PolicyFor が、開発・試験の環境の疑似の取り込み口にだけ許した場合。
func TestDialVerifiesTheServerCertificate(t *testing.T) {
	t.Run("信頼していない認証局", func(t *testing.T) {
		server := newRTMPTestServer(t, testServerOptions{})
		_, err := dialWith(context.Background(), server.destination(), Config{}) // 認証局を渡さない（OS の証明書ストアだけ）
		if !errors.Is(err, ErrDialFailed) {
			t.Fatalf("Dial error = %v, want ErrDialFailed", err)
		}
		var verification *tls.CertificateVerificationError
		var unknown x509.UnknownAuthorityError
		if !errors.As(err, &verification) || !errors.As(err, &unknown) {
			t.Errorf("Dial error = %v, want a certificate verification error (unknown authority)", err)
		}
		var dialErr *DialError
		if !errors.As(err, &dialErr) || dialErr.Phase != phaseTransport {
			t.Errorf("the failure must be reported for the %q phase: %v", phaseTransport, err)
		}
		if got := server.sessionCount(); got > 1 {
			t.Errorf("connections = %d", got)
		}
	})
	t.Run("ホスト名が一致しない証明書", func(t *testing.T) {
		server := newRTMPTestServer(t, testServerOptions{dnsNames: []string{"other.example"}})
		_, err := dialWith(context.Background(), server.destination(), Config{RootCAs: server.roots})
		var hostname x509.HostnameError
		if !errors.Is(err, ErrDialFailed) || !errors.As(err, &hostname) {
			t.Fatalf("Dial error = %v, want a host name mismatch error", err)
		}
	})
	t.Run("信頼する認証局を渡せば、成功する", func(t *testing.T) {
		server := newRTMPTestServer(t, testServerOptions{})
		p, err := dialWith(context.Background(), server.destination(), Config{RootCAs: server.roots})
		if err != nil {
			t.Fatalf("Dial: %v", err)
		}
		if err := p.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
	})
	t.Run("省略の印のある送出先（開発用の疑似の取り込み口）だけが、検証を省略する", func(t *testing.T) {
		server := newRTMPTestServer(t, testServerOptions{})
		dest := server.destination()
		dest.skipTLSVerify = true
		p, err := dialWith(context.Background(), dest, Config{}) // 自己署名の証明書を、信頼していない
		if err != nil {
			t.Fatalf("Dial with the verification skipped: %v", err)
		}
		if err := p.WriteVideo(0, payloadOf(10, 'v')); err != nil {
			t.Errorf("WriteVideo: %v", err)
		}
		if err := p.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
		eventually(t, "the frame arrived", func() bool { return server.session(0).receivedCount() == 1 })
	})
}

func TestTLSConfigFor(t *testing.T) {
	roots := x509.NewCertPool()
	verified := ValidatedDestination{host: "a.rtmps.youtube.com", port: 443, app: "live2"}
	config := tlsConfigFor(verified, roots)
	if config.ServerName != "a.rtmps.youtube.com" {
		t.Errorf("ServerName = %q, want the host name (SNI)", config.ServerName)
	}
	if config.MinVersion < tls.VersionTLS12 {
		t.Errorf("MinVersion = %#x, want TLS 1.2 or later", config.MinVersion)
	}
	if config.InsecureSkipVerify {
		t.Errorf("the verification must be on for a YouTube ingest")
	}
	if config.RootCAs != roots {
		t.Errorf("RootCAs must be the injected pool")
	}
	if len(config.Certificates) != 0 || config.VerifyPeerCertificate != nil || config.VerifyConnection != nil {
		t.Errorf("no client certificates and no custom verification hooks are expected")
	}

	skipped := ValidatedDestination{host: "fake-ingest", port: 1935, app: "live2", skipTLSVerify: true}
	if !tlsConfigFor(skipped, nil).InsecureSkipVerify {
		t.Errorf("the development ingest may skip the verification")
	}
	if tlsConfigFor(skipped, nil).ServerName != "fake-ingest" {
		t.Errorf("the SNI must be set for the development ingest as well")
	}
}

// RTMP のハンドシェイクに応じない受け口（TLS は成立する）：期限で接続を閉じる。go-rtmp にはハンドシェイクのタイムアウトが無い。
func TestDialTimesOutWhenTheReceiverNeverAnswersTheRTMPHandshake(t *testing.T) {
	server := newSilentTLSServer(t)
	baseline := dialWorkers()
	start := time.Now()
	p, err := dialWith(context.Background(), server.destination(t), Config{DialTimeout: 300 * time.Millisecond, RootCAs: server.roots})
	elapsed := time.Since(start)
	if p != nil {
		p.Abort()
		t.Fatalf("Dial succeeded against a silent receiver")
	}
	if !errors.Is(err, ErrDialTimeout) || !errors.Is(err, ErrDialFailed) {
		t.Fatalf("Dial error = %v, want ErrDialTimeout (and ErrDialFailed)", err)
	}
	if elapsed < 250*time.Millisecond || elapsed > 3*time.Second {
		t.Errorf("Dial returned after %v, want about the 300 ms deadline", elapsed)
	}
	var dialErr *DialError
	if !errors.As(err, &dialErr) || dialErr.Phase != phaseTransport {
		t.Errorf("the timeout must be reported for the %q phase: %v", phaseTransport, err)
	}
	// 接続は、閉じられた（放置されない）。受け口は、接続の終わりを見る
	select {
	case <-server.accepted:
	default:
		t.Fatalf("the receiver never accepted a connection")
	}
	select {
	case <-server.closed:
	case <-time.After(3 * time.Second):
		t.Errorf("the connection was left open after the deadline; the socket must be closed")
	}
	waitDialWorkersAtMost(t, baseline)
}

// TLS のハンドシェイクが止まる受け口：期限で、接続を閉じる。
func TestDialTimesOutDuringTheTLSHandshake(t *testing.T) {
	server := newSilentTCPServer(t)
	baseline := dialWorkers()
	start := time.Now()
	p, err := dialWith(context.Background(), server.destination(t), Config{DialTimeout: 300 * time.Millisecond})
	elapsed := time.Since(start)
	if p != nil {
		p.Abort()
		t.Fatalf("Dial succeeded against a receiver that never answers the TLS handshake")
	}
	if !errors.Is(err, ErrDialTimeout) || !errors.Is(err, ErrDialFailed) {
		t.Fatalf("Dial error = %v, want ErrDialTimeout (and ErrDialFailed)", err)
	}
	if elapsed < 250*time.Millisecond || elapsed > 3*time.Second {
		t.Errorf("Dial returned after %v, want about the 300 ms deadline", elapsed)
	}
	select {
	case <-server.closed:
	case <-time.After(3 * time.Second):
		t.Errorf("the connection was left open after the deadline")
	}
	waitDialWorkersAtMost(t, baseline)
}

// connect に応答が来ない受け口：期限で、接続を閉じて戻る（go-rtmp の connect は、応答を待ち続ける）。
func TestDialTimesOutWhenConnectIsNeverAnswered(t *testing.T) {
	release := make(chan struct{})
	var once sync.Once
	server := newRTMPTestServer(t, testServerOptions{onConnect: func(h *recordingHandler) { <-release }})
	t.Cleanup(func() { once.Do(func() { close(release) }) })

	start := time.Now()
	p, err := dialWith(context.Background(), server.destination(), Config{DialTimeout: 400 * time.Millisecond, RootCAs: server.roots})
	elapsed := time.Since(start)
	if p != nil {
		p.Abort()
		t.Fatalf("Dial succeeded although connect was never answered")
	}
	if !errors.Is(err, ErrDialTimeout) || !errors.Is(err, ErrDialFailed) {
		t.Fatalf("Dial error = %v, want ErrDialTimeout (and ErrDialFailed)", err)
	}
	if elapsed < 350*time.Millisecond || elapsed > 3*time.Second {
		t.Errorf("Dial returned after %v, want about the 400 ms deadline", elapsed)
	}
	var dialErr *DialError
	if !errors.As(err, &dialErr) || dialErr.Phase != phaseConnect {
		t.Errorf("the timeout must be reported for the %q phase: %v", phaseConnect, err)
	}
}

// connect の途中で、受け口が接続を閉じたら、期限を待たずに戻る（接続の状態を見張る）。
func TestDialFailsFastWhenTheReceiverClosesWhileConnecting(t *testing.T) {
	server := newRTMPTestServer(t, testServerOptions{onConnect: func(h *recordingHandler) { h.closeConnection() }})
	start := time.Now()
	p, err := dialWith(context.Background(), server.destination(), Config{DialTimeout: 8 * time.Second, RootCAs: server.roots, PollInterval: 10 * time.Millisecond})
	elapsed := time.Since(start)
	if p != nil {
		p.Abort()
		t.Fatalf("Dial succeeded although the receiver closed the connection")
	}
	if elapsed > 3*time.Second {
		t.Errorf("Dial took %v; it must notice the closed connection without waiting for the 8 s deadline", elapsed)
	}
	if !errors.Is(err, ErrDialFailed) || !errors.Is(err, ErrDisconnected) || !errors.Is(err, io.EOF) {
		t.Errorf("Dial error = %v, want ErrDialFailed wrapping ErrDisconnected and io.EOF", err)
	}
	if errors.Is(err, ErrDialTimeout) {
		t.Errorf("this is a disconnect, not a timeout")
	}
}

// 受け口が connect を拒否（エラーの応答）したら、その原因を包んで返す。
func TestDialReportsARejectedConnect(t *testing.T) {
	server := newRTMPTestServer(t, testServerOptions{rejectConnect: true})
	p, err := dialWith(context.Background(), server.destination(), Config{RootCAs: server.roots})
	if p != nil {
		p.Abort()
		t.Fatalf("Dial succeeded although connect was rejected")
	}
	var dialErr *DialError
	if !errors.Is(err, ErrDialFailed) || !errors.As(err, &dialErr) || dialErr.Phase != phaseConnect {
		t.Fatalf("Dial error = %v, want a failure of the %q phase", err, phaseConnect)
	}
}

// 呼び出し側が取り消したら、期限を待たずに戻り、接続を閉じる。
func TestDialIsCanceledByTheCaller(t *testing.T) {
	server := newSilentTLSServer(t)
	baseline := dialWorkers()
	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(150*time.Millisecond, cancel)

	start := time.Now()
	p, err := dialWith(ctx, server.destination(t), Config{DialTimeout: 30 * time.Second, RootCAs: server.roots})
	elapsed := time.Since(start)
	if p != nil {
		p.Abort()
		t.Fatalf("Dial succeeded against a silent receiver")
	}
	if !errors.Is(err, ErrDialFailed) || !errors.Is(err, context.Canceled) {
		t.Fatalf("Dial error = %v, want ErrDialFailed wrapping context.Canceled", err)
	}
	if errors.Is(err, ErrDialTimeout) {
		t.Errorf("a canceled dial is not a timeout")
	}
	if elapsed > 3*time.Second {
		t.Errorf("Dial returned after %v; a cancel must not wait for the 30 s deadline", elapsed)
	}
	select {
	case <-server.closed:
	case <-time.After(3 * time.Second):
		t.Errorf("the connection was left open after the cancel")
	}
	waitDialWorkersAtMost(t, baseline)
}

// 呼び出し側の context の期限も、接続全体の期限として効く（短い方）。
func TestDialHonorsTheCallersDeadline(t *testing.T) {
	server := newSilentTLSServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := dialWith(ctx, server.destination(t), Config{DialTimeout: 30 * time.Second, RootCAs: server.roots})
	if !errors.Is(err, ErrDialTimeout) {
		t.Fatalf("Dial error = %v, want ErrDialTimeout", err)
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Errorf("Dial returned after %v", elapsed)
	}
}
