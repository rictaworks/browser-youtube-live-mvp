package rtmps

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"io"
	"math/big"
	"net"
	"strconv"
	"sync"
	"testing"
	"time"

	rtmp "github.com/yutopp/go-rtmp"
	"github.com/yutopp/go-rtmp/message"
)

// 試験用の受け口。go-rtmp のサーバーを、TLS（自己署名の証明書）で立てる。実際の YouTube へは、接続しない。
// 配信キーを含め、受け取ったものを、ログへ出さない（go-rtmp のサーバーのログは、捨てる）。

const testHost = "localhost"

// newTestCertificate は、自己署名の証明書（SAN は dnsNames）と、それを信頼する認証局の集合を返す。
func newTestCertificate(t *testing.T, dnsNames ...string) (tls.Certificate, *x509.CertPool) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate a key: %v", err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "rtmps test"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
		DNSNames:              dnsNames,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create a certificate: %v", err)
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("parse the certificate: %v", err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(leaf)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, pool
}

// recordingHandler は、1 つの接続（取り込みセッション）で、受け口が受け取ったものを記録する。
type recordingHandler struct {
	rtmp.DefaultHandler
	server *rtmpTestServer

	mu          sync.Mutex
	conn        *rtmp.Conn
	connect     message.NetConnectionConnectCommand
	connected   bool
	publishName string
	publishType string
	published   bool
	messages    []record
	closeOnce   sync.Once
	closedCh    chan struct{}
}

func (h *recordingHandler) OnServe(conn *rtmp.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.conn = conn
}

func (h *recordingHandler) OnConnect(timestamp uint32, cmd *message.NetConnectionConnect) error {
	h.mu.Lock()
	h.connect = cmd.Command
	h.connected = true
	h.mu.Unlock()
	if hook := h.server.onConnect; hook != nil {
		hook(h)
	}
	if h.server.rejectConnect {
		return errors.New("test server: connect rejected")
	}
	return nil
}

func (h *recordingHandler) OnPublish(ctx *rtmp.StreamContext, timestamp uint32, cmd *message.NetStreamPublish) error {
	h.mu.Lock()
	h.publishName = cmd.PublishingName
	h.publishType = cmd.PublishingType
	h.published = true
	h.mu.Unlock()
	if h.server.rejectPublish {
		return errors.New("test server: publish rejected")
	}
	return nil
}

func (h *recordingHandler) record(kind string, timestamp uint32, payload io.Reader) error {
	data, err := io.ReadAll(payload)
	if err != nil {
		return err
	}
	h.mu.Lock()
	h.messages = append(h.messages, record{kind: kind, ts: timestamp, payload: data})
	count := len(h.messages)
	h.mu.Unlock()
	if hook := h.server.onMessage; hook != nil {
		hook(h, kind, count)
	}
	return nil
}

func (h *recordingHandler) OnVideo(timestamp uint32, payload io.Reader) error {
	return h.record("video", timestamp, payload)
}

func (h *recordingHandler) OnAudio(timestamp uint32, payload io.Reader) error {
	return h.record("audio", timestamp, payload)
}

func (h *recordingHandler) OnSetDataFrame(timestamp uint32, data *message.NetStreamSetDataFrame) error {
	return h.record("meta", timestamp, bytes.NewReader(data.Payload))
}

func (h *recordingHandler) OnClose() {
	if hook := h.server.onClose; hook != nil {
		hook(h)
	}
	h.closeOnce.Do(func() { close(h.closedCh) })
}

// received は、受け取ったメッセージの写し。
func (h *recordingHandler) received() []record {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]record(nil), h.messages...)
}

func (h *recordingHandler) receivedCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.messages)
}

// closeConnection は、受け口の側から、接続を閉じる。
func (h *recordingHandler) closeConnection() {
	h.mu.Lock()
	conn := h.conn
	h.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
}

type testServerOptions struct {
	// dnsNames は、証明書の SAN（既定は localhost）。
	dnsNames []string
	// rejectPublish が true なら、publish を拒否する（onStatus のあと、接続を閉じる）。
	rejectPublish bool
	// rejectConnect が true なら、connect を拒否する（エラーの応答を返して、接続を閉じる）。
	rejectConnect bool
	// onConnect は、connect を受け取ったとき（応答を返す前）に、受け口のゴルーチンから呼ばれる。止めれば、応答は返らず、
	// 接続を閉じれば、応答を返さずに切れる（go-rtmp のクライアントの connect は、応答が来ないと、待ち続ける）。
	onConnect func(h *recordingHandler)
	// onMessage は、メッセージを受け取るたびに、受け口のゴルーチンから呼ばれる（受け口の読み取りを止める試験に使う）。
	onMessage func(h *recordingHandler, kind string, count int)
	// onClose は、受け口が、接続の終わり（相手が閉じた）を見て、自分の側を閉じるとき（TCP の切断の前）に、受け口のゴルーチンから
	// 呼ばれる。止めれば、受け口の側の切断が遅れる（相手が閉じるのを待つ側の試験に使う）。受け口は、それまでのメッセージを、
	// すべて処理している。
	onClose func(h *recordingHandler)
}

// rtmpTestServer は、TLS の go-rtmp のサーバー。
type rtmpTestServer struct {
	t             *testing.T
	listener      net.Listener
	server        *rtmp.Server
	roots         *x509.CertPool
	port          int
	rejectPublish bool
	rejectConnect bool
	onConnect     func(h *recordingHandler)
	onMessage     func(h *recordingHandler, kind string, count int)
	onClose       func(h *recordingHandler)

	mu          sync.Mutex
	sessions    []*recordingHandler
	serverNames []string // 受け取った TLS の SNI
	serveDone   chan struct{}
}

func newRTMPTestServer(t *testing.T, opts testServerOptions) *rtmpTestServer {
	t.Helper()
	names := opts.dnsNames
	if len(names) == 0 {
		names = []string{testHost}
	}
	cert, roots := newTestCertificate(t, names...)
	s := &rtmpTestServer{t: t, roots: roots, rejectPublish: opts.rejectPublish, rejectConnect: opts.rejectConnect, onConnect: opts.onConnect, onMessage: opts.onMessage, onClose: opts.onClose, serveDone: make(chan struct{})}

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
		GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
			s.mu.Lock()
			s.serverNames = append(s.serverNames, hello.ServerName)
			s.mu.Unlock()
			return nil, nil
		},
	}
	listener, err := tls.Listen("tcp", "127.0.0.1:0", tlsConfig)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	s.listener = listener
	s.port = listener.Addr().(*net.TCPAddr).Port
	s.server = rtmp.NewServer(&rtmp.ServerConfig{
		OnConnect: func(conn net.Conn) (io.ReadWriteCloser, *rtmp.ConnConfig) {
			handler := &recordingHandler{server: s, closedCh: make(chan struct{})}
			s.mu.Lock()
			s.sessions = append(s.sessions, handler)
			s.mu.Unlock()
			return conn, &rtmp.ConnConfig{Handler: handler}
		},
	})
	go func() {
		defer close(s.serveDone)
		_ = s.server.Serve(listener)
	}()
	t.Cleanup(s.close)
	return s
}

// close は、受け口を止める。すべての接続も閉じる（受け口のゴルーチンを残さない）。
func (s *rtmpTestServer) close() {
	_ = s.server.Close()
	s.mu.Lock()
	sessions := append([]*recordingHandler(nil), s.sessions...)
	s.mu.Unlock()
	for _, session := range sessions {
		session.closeConnection()
	}
	select {
	case <-s.serveDone:
	case <-time.After(5 * time.Second):
		s.t.Errorf("the test server did not stop")
	}
}

// policy は、この受け口だけを許可する Policy（検証は、省略しない）。
func (s *rtmpTestServer) policy() Policy {
	s.t.Helper()
	policy, err := NewPolicy(Target{Host: testHost, Port: s.port})
	if err != nil {
		s.t.Fatalf("NewPolicy: %v", err)
	}
	return policy
}

// destination は、この受け口の、検証済みの送出先。
func (s *rtmpTestServer) destination() ValidatedDestination {
	s.t.Helper()
	dest, err := Validate("rtmps://"+testHost+":"+strconv.Itoa(s.port)+"/live2", s.policy())
	if err != nil {
		s.t.Fatalf("Validate: %v", err)
	}
	return dest
}

// session は、n 番目（0 から）の接続の記録を返す（まだ無ければ、待つ）。
func (s *rtmpTestServer) session(n int) *recordingHandler {
	s.t.Helper()
	var found *recordingHandler
	eventually(s.t, "the server accepted connection "+strconv.Itoa(n), func() bool {
		s.mu.Lock()
		defer s.mu.Unlock()
		if len(s.sessions) > n {
			found = s.sessions[n]
			return true
		}
		return false
	})
	return found
}

func (s *rtmpTestServer) sessionCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.sessions)
}

func (s *rtmpTestServer) seenServerNames() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.serverNames...)
}

// silentTLSServer は、TLS のハンドシェイクを済ませたあと、RTMP を一切話さない受け口（go-rtmp のハンドシェイクの応答が来ない状況の再現）。
// 接続が閉じられたこと（読み取りの終わり）を、closed へ通知する。
type silentTLSServer struct {
	listener net.Listener
	roots    *x509.CertPool
	port     int
	accepted chan struct{}
	closed   chan struct{}
	stop     chan struct{}
	wg       sync.WaitGroup
}

func newSilentTLSServer(t *testing.T) *silentTLSServer {
	t.Helper()
	cert, roots := newTestCertificate(t, testHost)
	listener, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	s := &silentTLSServer{
		listener: listener,
		roots:    roots,
		port:     listener.Addr().(*net.TCPAddr).Port,
		accepted: make(chan struct{}, 16),
		closed:   make(chan struct{}, 16),
		stop:     make(chan struct{}),
	}
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			s.accepted <- struct{}{}
			s.wg.Add(1)
			go func() {
				defer s.wg.Done()
				defer conn.Close()
				if tlsConn, ok := conn.(*tls.Conn); ok {
					if err := tlsConn.Handshake(); err != nil {
						s.closed <- struct{}{}
						return
					}
				}
				// 何も書かず、相手が閉じる（または、受け口を止める）まで読む
				go func() {
					<-s.stop
					_ = conn.Close()
				}()
				_, _ = io.Copy(io.Discard, conn)
				s.closed <- struct{}{}
			}()
		}
	}()
	t.Cleanup(func() {
		close(s.stop)
		_ = listener.Close()
		s.wg.Wait()
	})
	return s
}

func (s *silentTLSServer) policy(t *testing.T) Policy {
	t.Helper()
	policy, err := NewPolicy(Target{Host: testHost, Port: s.port})
	if err != nil {
		t.Fatalf("NewPolicy: %v", err)
	}
	return policy
}

func (s *silentTLSServer) destination(t *testing.T) ValidatedDestination {
	t.Helper()
	dest, err := Validate("rtmps://"+testHost+":"+strconv.Itoa(s.port)+"/live2", s.policy(t))
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	return dest
}

// silentTCPServer は、TCP の接続を受けるだけで、TLS のハンドシェイクにも応じない受け口（TLS のハンドシェイクが止まる状況の再現）。
type silentTCPServer struct {
	listener net.Listener
	port     int
	accepted chan struct{}
	closed   chan struct{}
	stop     chan struct{}
	wg       sync.WaitGroup
}

func newSilentTCPServer(t *testing.T) *silentTCPServer {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	s := &silentTCPServer{
		listener: listener,
		port:     listener.Addr().(*net.TCPAddr).Port,
		accepted: make(chan struct{}, 16),
		closed:   make(chan struct{}, 16),
		stop:     make(chan struct{}),
	}
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			s.accepted <- struct{}{}
			s.wg.Add(1)
			go func() {
				defer s.wg.Done()
				defer conn.Close()
				go func() {
					<-s.stop
					_ = conn.Close()
				}()
				_, _ = io.Copy(io.Discard, conn)
				s.closed <- struct{}{}
			}()
		}
	}()
	t.Cleanup(func() {
		close(s.stop)
		_ = listener.Close()
		s.wg.Wait()
	})
	return s
}

func (s *silentTCPServer) destination(t *testing.T) ValidatedDestination {
	t.Helper()
	policy, err := NewPolicy(Target{Host: testHost, Port: s.port})
	if err != nil {
		t.Fatalf("NewPolicy: %v", err)
	}
	dest, err := Validate("rtmps://"+testHost+":"+strconv.Itoa(s.port)+"/live2", policy)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	return dest
}

// syncBuffer は、並行に書いてよい、メモリ上のバッファ（slog の出力先として使う）。
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
