package rtmps

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// 接続の失敗の記録：種類（timeout・canceled・certificate・dns・refused・transport・write_timeout・protocol）だけを、
// 決まった語彙で残す。取り込み先のアドレスを含み得る原因の文言は、ログへ出さない。protocol（go-rtmp が、受け取ったメッセージを
// 処理できなかった）だけは、アドレスを含まないので、原因を残す（YouTube が、go-rtmp の未対応のメッセージを送ったときに、
// 実機で原因を突き止められるように）。

type fakeAddress string

func (a fakeAddress) Network() string { return "tcp" }
func (a fakeAddress) String() string  { return string(a) }

func TestFailureKind(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want string
	}{
		{"接続全体の期限", fmt.Errorf("%w: %w", ErrDialTimeout, context.DeadlineExceeded), kindTimeout},
		{"取り消し", context.Canceled, kindCanceled},
		{"DialError に包んだ取り消し", &DialError{Phase: phaseTransport, Err: context.Canceled}, kindCanceled},
		{"DialError に包んだ期限", &DialError{Phase: phaseConnect, Err: ErrDialTimeout}, kindTimeout},
		{"証明書（信頼しない認証局）", &tls.CertificateVerificationError{Err: x509.UnknownAuthorityError{}}, kindCertificate},
		{"証明書（ホスト名の不一致）", &tls.CertificateVerificationError{Err: x509.HostnameError{Host: "example"}}, kindCertificate},
		{"名前の解決", &net.OpError{Op: "dial", Net: "tcp", Err: &net.DNSError{Err: "no such host", Name: "example", IsNotFound: true}}, kindDNS},
		{"接続の拒否", &net.OpError{Op: "dial", Net: "tcp", Err: fmt.Errorf("connect: %w", syscall.ECONNREFUSED)}, kindRefused},
		{"EOF", io.EOF, kindTransport},
		{"途中の EOF", io.ErrUnexpectedEOF, kindTransport},
		{"閉じたソケット", net.ErrClosed, kindTransport},
		{"リセット", fmt.Errorf("read: %w", syscall.ECONNRESET), kindTransport},
		{"壊れたパイプ", fmt.Errorf("write: %w", syscall.EPIPE), kindTransport},
		{"net.OpError", &net.OpError{Op: "read", Net: "tcp", Err: errors.New("i/o timeout")}, kindTransport},
		{"切断に包んだ EOF", fmt.Errorf("%w: %w", ErrDisconnected, io.EOF), kindTransport},
		{"書き込みの順番待ちの期限", fmt.Errorf("Failed to wait chunk writer: %w", context.DeadlineExceeded), kindWriteTimeout},
		{"go-rtmp の未対応のメッセージ", errors.New("Unsupported type for UserCtrl: TypeID = 31"), kindProtocol},
		{"パニック", errors.New("runtime error: invalid memory address or nil pointer dereference"), kindProtocol},
		{"接続を見放した試行", errKillSwitchReleased, kindProtocol},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := failureKind(c.err); got != c.want {
				t.Fatalf("failureKind = %q, want %q", got, c.want)
			}
		})
	}
}

func TestFailureAttrsKeepTheCauseOnlyForProtocolFailures(t *testing.T) {
	text := func(err error) string {
		var buffer syncBuffer
		slog.New(slog.NewTextHandler(&buffer, nil)).Info("x", failureAttrs(err)...)
		return buffer.String()
	}
	protocol := text(errors.New("Unsupported type for UserCtrl: TypeID = 31"))
	if !strings.Contains(protocol, "kind=protocol") || !strings.Contains(protocol, "Unsupported type for UserCtrl") {
		t.Errorf("protocol failure log = %q", protocol)
	}
	for _, err := range []error{io.EOF, context.Canceled, ErrDialTimeout, fmt.Errorf("read tcp 198.51.100.7:51000->203.0.113.5:443: %w", syscall.ECONNRESET)} {
		got := text(err)
		if strings.Contains(got, "detail=") || strings.Contains(got, "203.0.113.5") || strings.Contains(got, "198.51.100.7") {
			t.Errorf("the log for %v has a detail or an address: %q", failureKind(err), got)
		}
	}

	// 長い原因は、切る（UTF-8 の途中で切らない）
	long := errors.New(strings.Repeat("a", maxLoggedDetailBytes+50))
	if got := truncateForLog(long.Error(), maxLoggedDetailBytes); len(got) != maxLoggedDetailBytes+len("...") {
		t.Errorf("truncated length = %d, want %d", len(got), maxLoggedDetailBytes+3)
	}
	multibyte := strings.Repeat(string(rune(0x3042)), 100) // 1 文字 3 バイト
	for limit := 1; limit < 12; limit++ {
		got := truncateForLog(multibyte, limit)
		if !strings.HasSuffix(got, "...") || strings.ContainsRune(got, rune(0xFFFD)) {
			t.Fatalf("limit %d: %q is not valid UTF-8 ending with an ellipsis", limit, got)
		}
	}
	if got := truncateForLog("short", 100); got != "short" {
		t.Errorf("a short text must stay as it is: %q", got)
	}
}

func TestConnectionFailuresAreLoggedByKindWithoutAddresses(t *testing.T) {
	cases := []struct {
		name       string
		err        error
		wantKind   string
		wantDetail string // 空なら、detail を残さない
	}{
		{"接続の終わり（EOF）", io.EOF, kindTransport, ""},
		{"閉じたソケット", net.ErrClosed, kindTransport, ""},
		{"アドレスを含む接続の失敗", &net.OpError{Op: "write", Net: "tcp", Addr: fakeAddress("203.0.113.5:443"), Err: syscall.EPIPE}, kindTransport, ""},
		{"リセット", fmt.Errorf("read tcp 198.51.100.7:51000->203.0.113.5:443: %w", syscall.ECONNRESET), kindTransport, ""},
		{"書き込みの順番待ちの期限", fmt.Errorf("Failed to wait chunk writer: %w", context.DeadlineExceeded), kindWriteTimeout, ""},
		{"go-rtmp が処理できないメッセージ", errors.New("Unsupported type for UserCtrl: TypeID = 31"), kindProtocol, "Unsupported type for UserCtrl: TypeID = 31"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			for _, path := range []string{"見張り", "書き込み"} {
				sink := newFakeSink()
				logs := &syncBuffer{}
				logger := slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
				p := newTestPublisher(t, sink, Config{Logger: logger, PublishRejectWindow: time.Nanosecond})
				if path == "見張り" {
					sink.breakConnection(c.err)
				} else {
					sink.failWith(c.err)
					if err := p.WriteVideo(0, payloadOf(10, 'v')); err != nil {
						t.Fatal(err)
					}
				}
				waitClosed(t, p)
				waitTeardown(t, p)

				text := logs.String()
				if !strings.Contains(text, "connection error") || !strings.Contains(text, "kind="+c.wantKind) {
					t.Errorf("%s: the log does not name the kind %q:\n%s", path, c.wantKind, text)
				}
				if c.wantDetail == "" && strings.Contains(text, "detail=") {
					t.Errorf("%s: the log has a detail for a %s failure:\n%s", path, c.wantKind, text)
				}
				if c.wantDetail != "" && !strings.Contains(text, c.wantDetail) {
					t.Errorf("%s: the log lacks the detail %q:\n%s", path, c.wantDetail, text)
				}
				for _, address := range []string{"203.0.113.5", "198.51.100.7", ":443"} {
					if strings.Contains(text, address) {
						t.Errorf("%s: the log exposed the address %q:\n%s", path, address, text)
					}
				}
			}
		})
	}
}

// 自分で接続を壊したあとの書き込みの失敗は、失敗として記録しない（最初の原因だけを記録する）。
func TestOnlyTheFirstFailureIsLogged(t *testing.T) {
	sink := newFakeSink()
	sink.limit()
	logs := &syncBuffer{}
	p := newTestPublisher(t, sink, Config{Logger: slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug}))})
	if err := p.WriteVideo(0, payloadOf(10, 'v')); err != nil {
		t.Fatal(err)
	}
	// 書き込みのゴルーチンが、1 件目を取り出して、止まっていること（上限で破棄されるのは、キューの残りだけ）
	eventually(t, "the writer took the first message", func() bool {
		p.mu.Lock()
		defer p.mu.Unlock()
		return len(p.queue) == 0
	})
	// 上限に達して、接続を壊す。止まっていた書き込みは、kill で失敗する（これは、記録しない）
	if err := p.WriteVideo(uint32(contract.RelayEgressBufferLimitMs), payloadOf(10, 'v')); !errors.Is(err, ErrBufferOverflow) {
		t.Fatalf("error = %v, want ErrBufferOverflow", err)
	}
	waitTeardown(t, p)
	if strings.Contains(logs.String(), "connection error") {
		t.Errorf("a failure caused by our own kill was logged as a connection error:\n%s", logs.String())
	}
	if !strings.Contains(logs.String(), "publisher stopped") {
		t.Errorf("the stop itself must be logged:\n%s", logs.String())
	}
}

// 接続の失敗は、Dial のログにも、種類だけが残る（原因の文言のアドレス・ホスト名は残らない）。
func TestDialFailuresAreLoggedByKind(t *testing.T) {
	server := newRTMPTestServer(t, testServerOptions{})
	logs := &syncBuffer{}
	logger := slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	// 信頼していない認証局
	if _, err := Dial(contextWithTimeout(t), server.destination(), StreamKey(dummyStreamKey), Config{Logger: logger}); err == nil {
		t.Fatalf("a certificate that is not trusted must be refused")
	}
	text := logs.String()
	if !strings.Contains(text, "dial failed") || !strings.Contains(text, "kind=certificate") || !strings.Contains(text, "phase=transport") {
		t.Errorf("the log does not name the failure:\n%s", text)
	}
	for _, leaked := range []string{"127.0.0.1", testHost, "x509", dummyStreamKey} {
		if strings.Contains(text, leaked) {
			t.Errorf("the log exposed %q:\n%s", leaked, text)
		}
	}
}

func contextWithTimeout(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	t.Cleanup(cancel)
	return ctx
}
