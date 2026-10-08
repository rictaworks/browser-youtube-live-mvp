package wsapi_test

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	rtmp "github.com/yutopp/go-rtmp"
	"github.com/yutopp/go-rtmp/message"
)

// 結合試験の疑似の相手：アプリケーション（内部通信。契約 internal-api.md どおりの応答。呼び出しを記録）と、
// RTMP の受け口（go-rtmp のサーバー。TLS・自己署名）。実際の YouTube・アプリケーションには接続しない。値は明らかなダミー。

const (
	appSecret      = "dummy-shared-secret-SECRET-0001"
	watchURL       = "https://www.youtube.com/watch?v=dummyVideoId"
	rtmpHost       = "localhost"
	secretStreamID = "dummy-stream-key-SECRET"
)

// ---- アプリケーション ----

type appTicket struct {
	broadcastID string
	state       string // 照合の結果の配信の状態
	accountKey  string
	profile     string // 確定済みのプロファイル（reserved では空）
}

type recordedCall struct {
	kind string // verify・provision・heartbeat・event
	id   string
	body map[string]any
}

type fakeApp struct {
	t       *testing.T
	server  *httptest.Server
	rtmpURL string

	mu          sync.Mutex
	tickets     map[string]appTicket
	used        map[string]bool
	epochs      map[string]int
	calls       []recordedCall
	notices     map[string][]map[string]any // 次の心拍の応答に載せる通知
	lastSeq     map[string]int
	lastReply   map[string][]byte
	stopWith    map[string]string // 配信 → 心拍の応答で停止を指示する（end_reason）
	provisionFn func(id string, epoch int) (status int, body map[string]any)
	down        bool // 不達：応答を返さず、接続を切る
	attempts    int  // 届いた要求の数（不達で切ったものを含む）
}

func newFakeApp(t *testing.T) *fakeApp {
	a := &fakeApp{
		t: t, tickets: map[string]appTicket{}, used: map[string]bool{}, epochs: map[string]int{},
		notices: map[string][]map[string]any{}, lastSeq: map[string]int{}, lastReply: map[string][]byte{}, stopWith: map[string]string{},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /internal/v1/verify", a.handle("verify", a.verify))
	mux.HandleFunc("POST /internal/v1/broadcasts/{id}/provision", a.handle("provision", a.provision))
	mux.HandleFunc("POST /internal/v1/broadcasts/{id}/heartbeat", a.handle("heartbeat", a.heartbeat))
	mux.HandleFunc("POST /internal/v1/broadcasts/{id}/events", a.handle("event", a.event))
	a.server = httptest.NewServer(mux)
	t.Cleanup(a.server.Close)
	return a
}

func (a *fakeApp) URL() string { return a.server.URL }

// handle は、認証（X-Relay-Secret）・不達・要求の記録をそろえて行ってから、各呼び出しの処理へ渡す。
func (a *fakeApp) handle(kind string, serve func(w http.ResponseWriter, id string, body map[string]any)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		a.attempts++
		down := a.down
		a.mu.Unlock()
		if down {
			if hijacker, ok := w.(http.Hijacker); ok {
				if conn, _, err := hijacker.Hijack(); err == nil {
					_ = conn.Close()
				}
			}
			return
		}
		if r.Header.Get("X-Relay-Secret") != appSecret {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"code": "unauthorized"}})
			return
		}
		body := map[string]any{}
		payload, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if len(payload) > 0 {
			if err := json.Unmarshal(payload, &body); err != nil {
				writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": map[string]any{"code": "invalid_input"}})
				return
			}
		}
		id := r.PathValue("id")
		a.mu.Lock()
		a.calls = append(a.calls, recordedCall{kind: kind, id: id, body: body})
		a.mu.Unlock()
		serve(w, id, body)
	}
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func errorBody(code string, details map[string]any) map[string]any {
	inner := map[string]any{"code": code}
	if details != nil {
		inner["details"] = details
	}
	return map[string]any{"error": inner}
}

func (a *fakeApp) verify(w http.ResponseWriter, _ string, body map[string]any) {
	ticket, _ := body["ticket"].(string)
	a.mu.Lock()
	defer a.mu.Unlock()
	info, known := a.tickets[ticket]
	if !known || a.used[ticket] {
		writeJSON(w, http.StatusNotFound, errorBody("ticket_invalid", nil))
		return
	}
	a.used[ticket] = true
	if info.state == "ended" {
		writeJSON(w, http.StatusConflict, errorBody("broadcast_not_attachable", nil))
		return
	}
	a.epochs[info.broadcastID]++
	var profile any
	if info.profile != "" {
		profile = info.profile
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"broadcast_id": info.broadcastID, "state": info.state, "epoch": a.epochs[info.broadcastID], "account_key": info.accountKey,
		"profile": profile, "limits": map[string]any{"time_limit_seconds": 3600},
	})
}

func (a *fakeApp) provision(w http.ResponseWriter, id string, body map[string]any) {
	epoch, _ := body["epoch"].(float64)
	a.mu.Lock()
	current := a.epochs[id]
	fn := a.provisionFn
	rtmpURL := a.rtmpURL
	a.mu.Unlock()
	if int(epoch) != current {
		writeJSON(w, http.StatusConflict, errorBody("stale_epoch", nil))
		return
	}
	if fn != nil {
		status, reply := fn(id, int(epoch))
		writeJSON(w, status, reply)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ingest":    map[string]any{"url": rtmpURL, "stream_key": streamKeyOf(id)},
		"watch_url": watchURL,
		"state":     "awaiting_media",
	})
}

func (a *fakeApp) heartbeat(w http.ResponseWriter, id string, body map[string]any) {
	epoch, _ := body["epoch"].(float64)
	seq, _ := body["seq"].(float64)
	a.mu.Lock()
	defer a.mu.Unlock()
	if int(epoch) != a.epochs[id] {
		writeJSON(w, http.StatusOK, map[string]any{"command": "stop", "reason": "stale_epoch"})
		return
	}
	if reason := a.stopWith[id]; reason != "" {
		writeJSON(w, http.StatusOK, map[string]any{"command": "stop", "end_reason": reason})
		return
	}
	if int(seq) <= a.lastSeq[id] && a.lastReply[id] != nil { // 再送：前回の応答を返す（契約：seq で冪等）
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = w.Write(a.lastReply[id])
		return
	}
	notices := a.notices[id]
	a.notices[id] = nil
	if notices == nil {
		notices = []map[string]any{}
	}
	encoded, _ := json.Marshal(map[string]any{"command": "continue", "notices": notices})
	a.lastSeq[id] = int(seq)
	a.lastReply[id] = encoded
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(encoded)
}

func (a *fakeApp) event(w http.ResponseWriter, _ string, _ map[string]any) {
	w.WriteHeader(http.StatusNoContent)
}

// ---- 試験からの操作 ----

func streamKeyOf(broadcastID string) string {
	return secretStreamID + "-" + broadcastID[len(broadcastID)-6:]
}

// addTicket は、接続チケットを 1 つ登録する。state が reserved 以外（復帰）なら、プロファイルは 720p。
func (a *fakeApp) addTicket(ticket, broadcastID, state, accountKey string) {
	info := appTicket{broadcastID: broadcastID, state: state, accountKey: accountKey}
	if state != "reserved" && state != "ended" {
		info.profile = "720p"
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	a.tickets[ticket] = info
}

func (a *fakeApp) setDown(down bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.down = down
}

func (a *fakeApp) setRTMPURL(url string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.rtmpURL = url
}

func (a *fakeApp) setProvision(fn func(id string, epoch int) (int, map[string]any)) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.provisionFn = fn
}

// queueNotice は、次の心拍の応答に載せる通知（status）を積む。
func (a *fakeApp) queueNotice(id string, notice map[string]any) {
	a.mu.Lock()
	defer a.mu.Unlock()
	notice["kind"] = "status"
	a.notices[id] = append(a.notices[id], notice)
}

func (a *fakeApp) stopHeartbeatsWith(id, endReason string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.stopWith[id] = endReason
}

func (a *fakeApp) attemptCount() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.attempts
}

func (a *fakeApp) callsOf(kind string) []recordedCall {
	a.mu.Lock()
	defer a.mu.Unlock()
	var out []recordedCall
	for _, call := range a.calls {
		if call.kind == kind {
			out = append(out, call)
		}
	}
	return out
}

func (a *fakeApp) callsFor(kind, id string) []recordedCall {
	var out []recordedCall
	for _, call := range a.callsOf(kind) {
		if call.id == id {
			out = append(out, call)
		}
	}
	return out
}

// eventKinds は、配信の事象を、「種類」または「種類:原因」の文字列にして、届いた順に返す。
func (a *fakeApp) eventKinds(id string) []string {
	var out []string
	for _, call := range a.callsFor("event", id) {
		text, _ := call.body["kind"].(string)
		if detail, ok := call.body["detail"].(map[string]any); ok {
			if cause, ok := detail["cause"].(string); ok {
				text += ":" + cause
			}
		}
		out = append(out, text)
	}
	return out
}

// ---- RTMP の受け口 ----

type rtmpRecord struct {
	kind    string // meta・video・audio
	ts      uint32
	payload []byte
}

// rtmpPeer は、受け口の接続 1 本（go-rtmp のハンドラ）。
type rtmpPeer struct {
	rtmp.DefaultHandler
	server *rtmpServer

	mu          sync.Mutex
	conn        *rtmp.Conn
	publishName string
	records     []rtmpRecord
	closedCh    chan struct{}
	closeOnce   sync.Once
}

func (p *rtmpPeer) OnServe(conn *rtmp.Conn) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.conn = conn
}

func (p *rtmpPeer) OnConnect(uint32, *message.NetConnectionConnect) error { return nil }

func (p *rtmpPeer) OnPublish(_ *rtmp.StreamContext, _ uint32, cmd *message.NetStreamPublish) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.publishName = cmd.PublishingName
	return nil
}

func (p *rtmpPeer) record(kind string, timestamp uint32, payload io.Reader) error {
	data, err := io.ReadAll(payload)
	if err != nil {
		return err
	}
	p.mu.Lock()
	p.records = append(p.records, rtmpRecord{kind: kind, ts: timestamp, payload: data})
	count := len(p.records)
	p.mu.Unlock()
	if hook := p.server.recordHook(); hook != nil {
		hook(kind, count)
	}
	return nil
}

func (p *rtmpPeer) OnVideo(timestamp uint32, payload io.Reader) error {
	return p.record("video", timestamp, payload)
}

func (p *rtmpPeer) OnAudio(timestamp uint32, payload io.Reader) error {
	return p.record("audio", timestamp, payload)
}

func (p *rtmpPeer) OnSetDataFrame(timestamp uint32, data *message.NetStreamSetDataFrame) error {
	return p.record("meta", timestamp, strings.NewReader(string(data.Payload)))
}

func (p *rtmpPeer) OnClose() {
	if hook := p.server.closeHook(); hook != nil {
		hook()
	}
	p.closeOnce.Do(func() { close(p.closedCh) })
}

func (p *rtmpPeer) snapshot() []rtmpRecord {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]rtmpRecord(nil), p.records...)
}

func (p *rtmpPeer) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.records)
}

func (p *rtmpPeer) key() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.publishName
}

func (p *rtmpPeer) isClosed() bool {
	select {
	case <-p.closedCh:
		return true
	default:
		return false
	}
}

func (p *rtmpPeer) dropConnection() {
	p.mu.Lock()
	conn := p.conn
	p.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
}

// mediaOnly は、設定のタグ（メタデータ・時刻 0 のシーケンスヘッダ）を除いた、映像・音声のタグ。
func mediaOnly(records []rtmpRecord) []rtmpRecord {
	var out []rtmpRecord
	for _, record := range records {
		switch {
		case record.kind == "meta":
		case record.kind == "video" && len(record.payload) > 1 && record.payload[1] == 0:
		case record.kind == "audio" && len(record.payload) > 1 && record.payload[1] == 0:
		default:
			out = append(out, record)
		}
	}
	return out
}

type rtmpServer struct {
	t         *testing.T
	listener  net.Listener
	server    *rtmp.Server
	roots     *x509.CertPool
	port      int
	mu        sync.Mutex
	peers     []*rtmpPeer
	serveDone chan struct{}
	// onRecord・onClose は、受け口のゴルーチンから呼ばれる（受け口の読み取りや切断を、止める試験に使う）。mu で守る
	onRecord func(kind string, count int)
	onClose  func()
}

// setOnRecord は、メッセージを受け取るたびに呼ぶ処理を設定する（読み取りを止める試験に使う）。
func (s *rtmpServer) setOnRecord(hook func(kind string, count int)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.onRecord = hook
}

func (s *rtmpServer) recordHook() func(kind string, count int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.onRecord
}

// setOnClose は、受け口が接続の終わりを見て、自分の側を閉じるときに呼ぶ処理を設定する（切断を遅らせる試験に使う）。
func (s *rtmpServer) setOnClose(hook func()) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.onClose = hook
}

func (s *rtmpServer) closeHook() func() {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.onClose
}

func newRTMPServer(t *testing.T) *rtmpServer {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate a key: %v", err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "rtmps integration test"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
		DNSNames:              []string{rtmpHost},
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

	listener, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}},
		MinVersion:   tls.VersionTLS12,
	})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	s := &rtmpServer{t: t, listener: listener, roots: pool, port: listener.Addr().(*net.TCPAddr).Port, serveDone: make(chan struct{})}
	s.server = rtmp.NewServer(&rtmp.ServerConfig{
		OnConnect: func(conn net.Conn) (io.ReadWriteCloser, *rtmp.ConnConfig) {
			peer := &rtmpPeer{server: s, closedCh: make(chan struct{})}
			s.mu.Lock()
			s.peers = append(s.peers, peer)
			s.mu.Unlock()
			return conn, &rtmp.ConnConfig{Handler: peer}
		},
	})
	go func() {
		defer close(s.serveDone)
		_ = s.server.Serve(listener)
	}()
	t.Cleanup(s.close)
	return s
}

func (s *rtmpServer) close() {
	_ = s.server.Close()
	s.mu.Lock()
	peers := append([]*rtmpPeer(nil), s.peers...)
	s.mu.Unlock()
	for _, peer := range peers {
		peer.dropConnection()
	}
	select {
	case <-s.serveDone:
	case <-time.After(5 * time.Second):
		s.t.Errorf("the RTMP test server did not stop")
	}
}

// URL は、準備の応答に載せる取り込み先。
func (s *rtmpServer) URL() string { return fmt.Sprintf("rtmps://%s:%d/live2", rtmpHost, s.port) }

func (s *rtmpServer) peerCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.peers)
}

// peerByKey は、配信キー（publish の名前）が key の接続。まだ無ければ nil。
func (s *rtmpServer) peerByKey(key string) *rtmpPeer {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, peer := range s.peers {
		if peer.key() == key {
			return peer
		}
	}
	return nil
}

// ---- 待機の部品 ----

type fakeWaiter struct {
	mu      sync.Mutex
	pending []chan time.Time
	delays  []time.Duration
}

func (w *fakeWaiter) After(d time.Duration) <-chan time.Time {
	w.mu.Lock()
	defer w.mu.Unlock()
	ch := make(chan time.Time, 1)
	w.pending = append(w.pending, ch)
	w.delays = append(w.delays, d)
	return ch
}

// fireAll は、待っているものを、すべて鳴らす（再送の待機が、経ったことにする）。
func (w *fakeWaiter) fireAll() {
	w.mu.Lock()
	pending := w.pending
	w.pending = nil
	w.mu.Unlock()
	for _, ch := range pending {
		ch <- time.Time{}
	}
}

func (w *fakeWaiter) pendingCount() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.pending)
}
