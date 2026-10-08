package session

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
)

// maxAttachAttempts は、閉じている最中の取り込みセッションに当たったとき、その終了を待って作り直す回数の上限。
const maxAttachAttempts = 4

// Registry は、セッション台帳（requirements.md 24.3 の SessionRegistry）。取り込みセッションを、配信の識別子で引く。
// ゴルーチンから並行に呼んでよい。
//
// 同一アカウントの新しい取り込みセッションを照合した時点で、当該アカウントの他の取り込みセッションをすべて閉じる
// （10.5。古い映像が新しい配信へ流れないように、閉じるまで完了を待つ）。受信量の超過で切断した配信への再接続は、
// 一定の期間、受け付けない。
type Registry struct {
	deps Deps
	opts Options

	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup

	inflight atomic.Int64

	mu           sync.Mutex
	sessions     map[string]*IngestSession
	conns        map[*Connection]struct{}
	banned       map[string]time.Time
	shuttingDown bool
}

// NewRegistry は、台帳を作る。依存（Backend・Events・Publishers・Clock）が無い、設定が不正なら、エラー。
func NewRegistry(deps Deps) (*Registry, error) {
	normalized, err := deps.normalized()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Registry{
		deps:     normalized,
		opts:     normalized.Options,
		ctx:      ctx,
		cancel:   cancel,
		sessions: map[string]*IngestSession{},
		conns:    map[*Connection]struct{}{},
		banned:   map[string]time.Time{},
	}, nil
}

// Accept は、WebSocket の接続を受ける。接続通知（hello）の期限（10 秒）を数え始める。停止の手順に入っていれば ErrShuttingDown。
func (r *Registry) Accept(link BrowserLink) (*Connection, error) {
	r.mu.Lock()
	if r.shuttingDown {
		r.mu.Unlock()
		return nil, ErrShuttingDown
	}
	c := newConnection(r, link)
	r.conns[c] = struct{}{}
	r.mu.Unlock()
	return c, nil
}

func (r *Registry) forgetConn(c *Connection) {
	r.mu.Lock()
	delete(r.conns, c)
	r.mu.Unlock()
}

// Register は、取り込みセッションを台帳に登録する。同じ配信のものがすでにあれば ErrAlreadyRegistered、
// 閉じた（閉じている最中の）ものなら ErrSessionClosed、停止の手順に入っていれば ErrShuttingDown。
func (r *Registry) Register(s *IngestSession) error {
	r.mu.Lock()
	if r.shuttingDown {
		r.mu.Unlock()
		return ErrShuttingDown
	}
	if s.closing.Load() || s.isFinished() {
		r.mu.Unlock()
		return ErrSessionClosed
	}
	if _, exists := r.sessions[s.id]; exists {
		r.mu.Unlock()
		return fmt.Errorf("%w: %s", ErrAlreadyRegistered, s.id)
	}
	r.sessions[s.id] = s
	s.registryRef.Store(r)
	r.mu.Unlock()
	if s.isFinished() {
		r.remove(s, false) // 登録の最中に終わった。残さない
	}
	return nil
}

// Find は、配信の識別子で、取り込みセッションを引く。
func (r *Registry) Find(broadcastID string) (*IngestSession, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.sessions[broadcastID]
	return s, ok
}

// Count は、台帳にある取り込みセッションの数。
func (r *Registry) Count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.sessions)
}

// Remove は、取り込みセッションを台帳から外す（同じ配信の、別の取り込みセッションは外さない）。
func (r *Registry) Remove(s *IngestSession) { r.remove(s, false) }

// remove は、取り込みセッションを台帳から外す。ban が真なら、その配信への再接続を、一定の期間、受け付けない。
func (r *Registry) remove(s *IngestSession, ban bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if current, ok := r.sessions[s.id]; ok && current == s {
		delete(r.sessions, s.id)
	}
	if ban {
		r.banLocked(s.id)
	}
}

// snapshot は、台帳にある取り込みセッションの一覧。
func (r *Registry) snapshot() []*IngestSession {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]*IngestSession, 0, len(r.sessions))
	for _, s := range r.sessions {
		out = append(out, s)
	}
	return out
}

// CloseOthers は、同一アカウント（accountKey）の取り込みセッションのうち、keepBroadcastID 以外を、すべて閉じ、
// 閉じるのが完了するまで待つ。古い映像が新しい配信へ流れないよう、バッファを破棄して直ちに切る。閉じた数を返す。
func (r *Registry) CloseOthers(accountKey, keepBroadcastID string) int {
	r.mu.Lock()
	var others []*IngestSession
	for id, s := range r.sessions {
		if id != keepBroadcastID && s.accountKey == accountKey {
			others = append(others, s)
		}
	}
	r.mu.Unlock()
	for _, s := range others {
		s.Close(CloseReasonSuperseded)
	}
	for _, s := range others {
		<-s.Done()
	}
	return len(others)
}

// Shutdown は、中継の停止の手順。新しい接続・取り込みセッションを受け付けなくし、接続通知の前後の接続を閉じ、すべての
// 取り込みセッションを閉じる（RTMPS は、送出待ちを送り切ってから切る）。ctx が終わっても閉じ切れなければ、送り切るのを
// 待たずに切り、ctx のエラーを返す。戻ったときには、このパッケージのゴルーチンは残らない。何度呼んでもよい。
func (r *Registry) Shutdown(ctx context.Context) error {
	r.mu.Lock()
	r.shuttingDown = true
	sessions := make([]*IngestSession, 0, len(r.sessions))
	for _, s := range r.sessions {
		sessions = append(sessions, s)
	}
	conns := make([]*Connection, 0, len(r.conns))
	for c := range r.conns {
		conns = append(conns, c)
	}
	r.mu.Unlock()

	for _, c := range conns {
		c.fatalAndClose(contract.FatalCodeInternalError, CloseNormal) // 復帰（再接続）を試みる
	}
	for _, s := range sessions {
		s.Close(CloseReasonShutdown)
	}
	allDone := make(chan struct{})
	go func() {
		defer close(allDone)
		for _, s := range sessions {
			<-s.Done()
		}
	}()
	var result error
	select {
	case <-allDone:
	case <-ctx.Done():
		result = ctx.Err()
		for _, s := range sessions {
			s.Close(CloseReasonForced)
		}
		<-allDone
	}
	r.cancel()
	r.wg.Wait()
	return result
}

// ---- 照合 ----

// verifyAsync は、接続チケットの照合を、別のゴルーチンで行う（アプリケーションの呼び出しの最中も、ほかの接続を止めない）。
// 接続が先に切れても、照合の呼び出しは取り消さない（チケットは消費され、アプリケーションの世代は進むため、その結果を受けて、
// 送出世代を合わせる必要がある）。
func (r *Registry) verifyAsync(c *Connection, ticket backend.Ticket) {
	r.inflight.Add(1)
	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		defer r.inflight.Add(-1)
		defer func() {
			if recovered := recover(); recovered != nil {
				r.deps.Logger.Error("verification panicked", slog.String("panic_type", fmt.Sprintf("%T", recovered)))
				c.fatalAndClose(contract.FatalCodeInternalError, CloseNormal)
			}
		}()
		result, err := r.deps.Backend.Verify(r.ctx, ticket)
		c.onVerified(result, err)
	}()
}

// attach は、照合に成功した接続を、取り込みセッションの送信元にする。次を、試行ごとに行う（閉じている最中の取り込みセッションに
// 当たって、その終了を待ったあとの作り直しでも、1 から行い直す）。
//  1. 受信量の超過で切った配信なら、受け付けない（fatal(bitrate_exceeded)）。禁止は、取り込みセッションが閉じる手順に入った
//     時点で成立する（完全に終わるのを待たない）ので、待っている間に成立した禁止も、ここで見直される
//  2. 取り込みセッションを引く。無ければ（中継の再起動後・初回）、新たに作って登録する
//  3. 同一アカウントの他の取り込みセッションを、すべて閉じる（10.5。完了を待つ）
//  4. 送信元を差し替える（古い世代の接続は、直ちに閉じる）。accepted は、そのあとで返る
func (r *Registry) attach(c *Connection, result backend.VerifyResult) {
	for attempt := 0; attempt < maxAttachAttempts; attempt++ {
		if r.isBanned(result.BroadcastID) {
			r.deps.Logger.Warn("a banned broadcast tried to reconnect", slog.String("broadcast_id", result.BroadcastID))
			c.fatalAndClose(contract.FatalCodeBitrateExceeded, CloseNormal)
			return
		}
		s, err := r.sessionFor(result)
		if err != nil {
			r.deps.Logger.Error("an ingest session could not be prepared", slog.String("broadcast_id", result.BroadcastID), slog.String("class", errorClass(err)))
			c.fatalAndClose(contract.FatalCodeInternalError, CloseNormal)
			return
		}
		r.CloseOthers(result.AccountKey, result.BroadcastID)
		err = s.SwapSource(c, result)
		if err == nil {
			return
		}
		if !errors.Is(err, ErrSessionClosed) {
			c.fatalAndClose(contract.FatalCodeInternalError, CloseNormal)
			return
		}
		<-s.Done() // 閉じている最中だった。終わるのを待って、作り直す
	}
	c.fatalAndClose(contract.FatalCodeInternalError, CloseNormal)
}

// sessionFor は、照合の結果の配信の取り込みセッションを返す。無ければ、作って、登録して、動かす。
func (r *Registry) sessionFor(result backend.VerifyResult) (*IngestSession, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.shuttingDown {
		return nil, ErrShuttingDown
	}
	if existing, ok := r.sessions[result.BroadcastID]; ok {
		if existing.accountKey != result.AccountKey {
			return nil, ErrInvalidParams // 同じ配信が、別のアカウントのものになることは無い
		}
		return existing, nil
	}
	s, err := NewIngestSession(Params{
		BroadcastID: result.BroadcastID,
		AccountKey:  result.AccountKey,
		State:       result.State,
		Profile:     result.Profile,
	}, r.deps)
	if err != nil {
		return nil, err
	}
	s.registryRef.Store(r)
	r.sessions[result.BroadcastID] = s
	s.Start()
	return s, nil
}

// ---- 受信量の超過で切った配信 ----

// ban は、配信への再接続を、一定の期間、受け付けないことにする（取り込みセッションが、閉じる手順に入った時点で呼ぶ）。
func (r *Registry) ban(broadcastID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.banLocked(broadcastID)
}

func (r *Registry) isBanned(broadcastID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	until, ok := r.banned[broadcastID]
	if !ok {
		return false
	}
	if r.deps.Clock.Now().Before(until) {
		return true
	}
	delete(r.banned, broadcastID)
	return false
}

// banLocked は、配信への再接続を、一定の期間、受け付けないことにする。記録の数に上限を置き、超えたら、期限の最も早いものから外す。
func (r *Registry) banLocked(broadcastID string) {
	now := r.deps.Clock.Now()
	for id, until := range r.banned {
		if !now.Before(until) {
			delete(r.banned, id)
		}
	}
	r.banned[broadcastID] = now.Add(r.opts.BanTTL)
	for len(r.banned) > r.opts.MaxBanned {
		var oldest string
		var oldestUntil time.Time
		for id, until := range r.banned {
			if oldest == "" || until.Before(oldestUntil) {
				oldest, oldestUntil = id, until
			}
		}
		delete(r.banned, oldest)
	}
}

// String は、件数だけを示す（取り込みセッションの中身を出さない）。
func (r *Registry) String() string {
	return fmt.Sprintf("session.Registry{sessions=%d}", r.Count())
}

// GoString は、String と同じ。
func (r *Registry) GoString() string { return r.String() }

// Format は、どの書式動詞でも、String だけを書く。
func (r *Registry) Format(f fmt.State, _ rune) { _, _ = io.WriteString(f, r.String()) }

// isFinished は、取り込みセッションが完全に終わったか。
func (s *IngestSession) isFinished() bool {
	select {
	case <-s.done:
		return true
	default:
		return false
	}
}
