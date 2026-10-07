package rtmps

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"sync/atomic"
	"time"

	rtmp "github.com/yutopp/go-rtmp"
	"github.com/yutopp/go-rtmp/message"
)

// 接続の段階（DialError の Phase）。
const (
	phaseStart        = "start"        // 接続を始める前（context が、すでに終わっていた）
	phaseTransport    = "transport"    // TCP・TLS・RTMP のハンドシェイク
	phaseConnect      = "connect"      // RTMP の connect
	phaseCreateStream = "createStream" // RTMP の createStream
	phasePublish      = "publish"      // RTMP の publish
)

// RTMP の connect の内容。OBS・FMLE と同じ値（YouTube は、これらを検査しないが、互換のある値にしておく）。
const (
	publishingType       = "live"
	connectType          = "nonprivate"
	flashVersion         = "FMLE/3.0 (compatible; browser-youtube-live-mvp)"
	connectCapabilities  = 15
	connectAudioCodecs   = 3191
	connectVideoCodecs   = 252
	connectVideoFunction = 1

	// outChunkSize は、送るチャンクの大きさ（バイト）。既定の 128 では、チャンクごとに TLS のレコードと書き込みが生じ、
	// 送信量（1 GB あたり課金）と CPU が余計にかかる。OBS と同じ 4,096。
	outChunkSize = 4096
)

// DialError は、接続の失敗。Phase は、どの段階か（start・transport・connect・createStream・publish）。原因は Unwrap で得る
// （errors.Is・errors.As で、証明書の検証の失敗・ErrDialTimeout・ErrDisconnected・context.Canceled などを判定できる）。
// errors.Is(err, ErrDialFailed) が、すべての失敗で真になる。
type DialError struct {
	Phase string
	Err   error
}

func (e *DialError) Error() string {
	return fmt.Sprintf("%s during %s: %v", ErrDialFailed, e.Phase, e.Err)
}

func (e *DialError) Unwrap() error { return e.Err }

// Is は、ErrDialFailed との一致を答える。
func (e *DialError) Is(target error) bool { return target == ErrDialFailed }

// tlsConfigFor は、接続の TLS の設定。TLS 1.2 以上。サーバーの名前（SNI と証明書の照合）は、ホスト名（IP アドレスで接続しない）。
// 証明書は、roots（nil なら、OS の証明書ストア）で検証する。検証を省略するのは、送出先が、その印を持つときだけ
// （PolicyFor が、開発・試験の環境の、疑似の取り込み口にだけ付ける）。
func tlsConfigFor(dest ValidatedDestination, roots *x509.CertPool) *tls.Config {
	return &tls.Config{
		ServerName: dest.host,
		MinVersion: tls.VersionTLS12,
		RootCAs:    roots,
		// 開発・試験の疑似の取り込み口（自己署名の証明書）に限る。YouTube の取り込み口には、決して付かない（destination.go）
		InsecureSkipVerify: dest.skipTLSVerify,
	}
}

// Dial は、検証済みの送出先へ、RTMPS で接続し、connect -> createStream -> publish（live）まで行い、Publisher を返す。
// 配信キー（key）は、publish の呼び出しに 1 回使うだけで、Publisher は保持しない。URL とは別に受け取る。
//
// 接続全体（TCP・TLS・RTMP のハンドシェイク・connect・createStream・publish）は、cfg.DialTimeout（既定 10 秒）と、ctx の
// 期限・取り消しの、早い方で打ち切る。go-rtmp の Dial 系は、context を取らず、RTMP のハンドシェイクにタイムアウトが無く、
// connect・createStream は応答を待ち続けるため、期限が来たら、接続のソケットを shutdown で壊して（killSwitch）、戻る。
// 接続の途中で、受け口が接続を閉じたときも、期限を待たずに戻る。
//
// 失敗は *DialError（errors.Is(err, ErrDialFailed)）。期限は ErrDialTimeout を、取り消しは context.Canceled を包む。
// 引数が不正なら、接続を始める前に、ErrInvalidDestination（Validate を通っていない）・ErrInvalidStreamKey・ErrInvalidConfig。
//
// 既知の制約：go-rtmp の connect・createStream は、応答が来ないと、接続を閉じても戻らない。そのため、そのような受け口との
// 接続の試行は、期限・切断で Dial が戻ったあとも、ゴルーチンを 1 つ残す（接続のソケットは、閉じる。ゴルーチンは、プロセスの終わりまで残る）。
//
// publish の成否は、go-rtmp が応答（onStatus）を処理しないので、Dial は知らない。publish の直後に接続が切れたら、Publisher が、
// ErrPublishRejected として知らせる。
func Dial(ctx context.Context, dest ValidatedDestination, key StreamKey, cfg Config) (*Publisher, error) {
	if !dest.valid() {
		return nil, ErrInvalidDestination
	}
	if err := key.Validate(); err != nil {
		return nil, err
	}
	normalized, err := cfg.normalized()
	if err != nil {
		return nil, err
	}
	log := normalized.Logger
	if err := ctx.Err(); err != nil {
		return nil, &DialError{Phase: phaseStart, Err: err}
	}

	start := time.Now()
	log.Debug("rtmps dial started")
	guard := newKillSwitch()
	dialCtx, cancel := context.WithTimeout(ctx, normalized.DialTimeout)
	defer cancel()
	attempt := newDialAttempt(dest, key, normalized, guard)
	go attempt.run()

	outcome := attempt.wait(dialCtx, normalized.PollInterval)
	if outcome.err != nil {
		guard.release()
		failure := newDialError(dialCtx, outcome)
		attrs := append(failureAttrs(failure), slog.String("phase", failure.Phase), slog.Duration("elapsed", time.Since(start)))
		log.Warn("rtmps dial failed", attrs...)
		return nil, failure
	}

	guard.closeUnconnected()
	publisher, err := newPublisher(&rtmpSink{conn: outcome.conn, stream: outcome.stream, guard: guard, linger: normalized.CloseLinger}, normalized)
	if err != nil {
		// 設定は、検査済みなので、ここへは来ない。来たら、接続を閉じて、エラーを返す
		guard.shutdown()
		_ = outcome.conn.Close()
		guard.release()
		return nil, err
	}
	log.Debug("rtmps dial succeeded", slog.Duration("elapsed", time.Since(start)))
	return publisher, nil
}

// newDialError は、失敗の結果から、*DialError を作る。期限の失敗は ErrDialTimeout を、取り消しの失敗は context.Canceled を包む。
// 試行の中で、下の層（TCP・TLS）の期限が先に切れて、context deadline exceeded が返ることもあるので、それも期限の失敗とみなす
// （接続全体の期限と、下の層の期限は、同時に切れる。どちらが先でも、同じ失敗として扱う）。
func newDialError(dialCtx context.Context, outcome dialOutcome) *DialError {
	cause := outcome.err
	switch {
	case errors.Is(cause, ErrDialTimeout), errors.Is(cause, context.Canceled):
		// すでに、期限・取り消しの印がある
	case errors.Is(cause, context.DeadlineExceeded), errors.Is(dialCtx.Err(), context.DeadlineExceeded):
		cause = fmt.Errorf("%w: %w", ErrDialTimeout, cause)
	case dialCtx.Err() != nil:
		cause = fmt.Errorf("%w: %w", dialCtx.Err(), cause)
	}
	return &DialError{Phase: outcome.phase, Err: cause}
}

// dialOutcome は、接続の試行の結果。成功なら conn・stream、失敗なら phase（どの段階か）と err（原因）。
type dialOutcome struct {
	conn   *rtmp.ClientConn
	stream *rtmp.Stream
	phase  string
	err    error
}

const (
	attemptRunning int32 = iota
	attemptFinished
	attemptAbandoned
)

// dialAttempt は、1 回の接続の試行。go-rtmp の呼び出し（止まり得る）を、別のゴルーチン（run）で行い、Dial が、期限・取り消し・
// 切断を見張って、必要なら見放す（abandon）。結果を渡すのは、試行が終わるのと、見放すのと、先に済んだ方 1 つだけ（state の CAS）。
type dialAttempt struct {
	dest    ValidatedDestination
	key     StreamKey
	roots   *x509.CertPool
	timeout time.Duration
	guard   *killSwitch

	state  atomic.Int32
	phase  atomic.Value // string。いまの段階
	conn   atomic.Pointer[rtmp.ClientConn]
	result chan dialOutcome
}

func newDialAttempt(dest ValidatedDestination, key StreamKey, cfg Config, guard *killSwitch) *dialAttempt {
	a := &dialAttempt{
		dest:    dest,
		key:     key,
		roots:   cfg.RootCAs,
		timeout: cfg.DialTimeout,
		guard:   guard,
		result:  make(chan dialOutcome, 1),
	}
	a.phase.Store(phaseTransport)
	return a
}

func (a *dialAttempt) setPhase(phase string) { a.phase.Store(phase) }

func (a *dialAttempt) currentPhase() string {
	phase, _ := a.phase.Load().(string)
	return phase
}

// run は、接続から publish までを行い、結果を渡す（別のゴルーチンで動く）。
func (a *dialAttempt) run() {
	a.finish(a.connectAndPublish())
}

func (a *dialAttempt) connectAndPublish() dialOutcome {
	fail := func(phase string, err error, conn *rtmp.ClientConn) dialOutcome {
		if conn != nil {
			_ = conn.Close()
		}
		return dialOutcome{phase: phase, err: err}
	}

	a.setPhase(phaseTransport)
	dialer := &tls.Dialer{
		// FallbackDelay の負の値は、複数のアドレスを、並行ではなく、順に試す（killSwitch が、試行ごとのソケットを数えやすい）
		NetDialer: &net.Dialer{Timeout: a.timeout, FallbackDelay: -1, Control: a.guard.control},
		Config:    tlsConfigFor(a.dest, a.roots),
	}
	conn, err := rtmp.DialWithTLSDialer(dialer, schemeRTMPS, a.dest.addr(), &rtmp.ConnConfig{})
	if err != nil {
		return fail(phaseTransport, err, nil)
	}
	a.conn.Store(conn)

	a.setPhase(phaseConnect)
	if err := conn.Connect(connectCommand(a.dest)); err != nil {
		return fail(phaseConnect, err, conn)
	}
	a.setPhase(phaseCreateStream)
	stream, err := conn.CreateStream(&message.NetConnectionCreateStream{}, outChunkSize)
	if err != nil {
		return fail(phaseCreateStream, err, conn)
	}
	a.setPhase(phasePublish)
	if err := stream.Publish(&message.NetStreamPublish{PublishingName: a.key.reveal(), PublishingType: publishingType}); err != nil {
		return fail(phasePublish, err, conn)
	}
	return dialOutcome{conn: conn, stream: stream}
}

func connectCommand(dest ValidatedDestination) *message.NetConnectionConnect {
	return &message.NetConnectionConnect{Command: message.NetConnectionConnectCommand{
		App:           dest.app,
		Type:          connectType,
		FlashVer:      flashVersion,
		TCURL:         dest.tcURL(),
		Capabilities:  connectCapabilities,
		AudioCodecs:   connectAudioCodecs,
		VideoCodecs:   connectVideoCodecs,
		VideoFunction: connectVideoFunction,
	}}
}

// finish は、試行の結果を渡す。すでに見放されていれば、作った接続を閉じる（ソケットは、見放すときに壊してあるので、速やかに済む）。
func (a *dialAttempt) finish(outcome dialOutcome) {
	if a.state.CompareAndSwap(attemptRunning, attemptFinished) {
		a.result <- outcome
		return
	}
	if outcome.conn != nil {
		_ = outcome.conn.Close()
	}
}

// abandon は、試行を見放す（まだ終わっていなければ）。ソケットを壊して、止まっている go-rtmp の呼び出しを解き、作った接続を閉じる。
// 見放せたら true。試行が、すでに終わっていたら false（結果を読むこと）。
func (a *dialAttempt) abandon() bool {
	if !a.state.CompareAndSwap(attemptRunning, attemptAbandoned) {
		return false
	}
	a.guard.shutdown()
	if conn := a.conn.Load(); conn != nil {
		// go-rtmp の Close は、書き込み中のものを待つので、別のゴルーチンで行う
		go func() { _ = conn.Close() }()
	}
	return true
}

// wait は、試行の結果を待つ。ctx（期限・取り消し）が終わったら、見放して、その原因を返す。接続ができたあとに、受け口が接続を
// 閉じたら（go-rtmp の connect・createStream は、応答が来ないと待ち続けるため）、期限を待たずに見放して、ErrDisconnected を返す。
func (a *dialAttempt) wait(ctx context.Context, poll time.Duration) dialOutcome {
	ticker := time.NewTicker(poll)
	defer ticker.Stop()
	for {
		select {
		case outcome := <-a.result:
			return outcome
		case <-ctx.Done():
			if a.abandon() {
				return dialOutcome{phase: a.currentPhase(), err: ctx.Err()}
			}
			return <-a.result // 見放す直前に、試行が終わっていた
		case <-ticker.C:
			conn := a.conn.Load()
			if conn == nil {
				continue
			}
			if lastErr := conn.LastError(); lastErr != nil && a.abandon() {
				return dialOutcome{phase: a.currentPhase(), err: fmt.Errorf("%w: %w", ErrDisconnected, lastErr)}
			}
		}
	}
}
