package session

import (
	"context"
	"log/slog"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps"
)

// 外部との境界。WebSocket・HTTP・RTMPS は、インターフェース越しにする（実物の結線は #21）。
// 試験は、疑似の実装を注入する（実時間を待たず、実際の YouTube・アプリケーションを呼ばない）。

// Clock は、時計。取り込みセッションと台帳の時刻・タイマーは、すべてここから取る（time.Now などを直接呼ばない）。
type Clock interface {
	// Now は、現在の時刻。
	Now() time.Time
	// AfterFunc は、d が経ったら f を（別のゴルーチンで）呼ぶタイマーを返す。
	AfterFunc(d time.Duration, f func()) Timer
}

// Timer は、Clock.AfterFunc のタイマー（*time.Timer と同じ意味）。
type Timer interface {
	// Stop は、タイマーを止める。止められた（まだ f を呼んでいなかった）なら true。
	Stop() bool
	// Reset は、タイマーを d 後に鳴るよう再設定する。再設定の前に有効だったなら true。
	Reset(d time.Duration) bool
}

// Backend は、アプリケーションとの内部通信のうち、要求と応答（*backend.Client が満たす）。
// 事象は、保持と再送が要るので、EventSink に分ける。
type Backend interface {
	// Verify は、照合。接続チケットを 1 回限りで消費し、送出世代を 1 進める。
	Verify(ctx context.Context, ticket backend.Ticket) (backend.VerifyResult, error)
	// Provision は、準備。取り込み先と配信キーを得る。数十秒かかり得る。
	Provision(ctx context.Context, broadcastID string, epoch int, profile contract.Profile) (backend.ProvisionResult, error)
	// Heartbeat は、心拍。応答で、指示（継続・停止）と状態の通知を受ける。
	Heartbeat(ctx context.Context, broadcastID string, request backend.HeartbeatRequest) (backend.HeartbeatResponse, error)
}

// EventSink は、事象の送り先（*backend.EventQueue が満たす）。アプリケーションへ到達できない間は、保持して再送する。
type EventSink interface {
	// Enqueue は、事象を積む。呼び出し元をブロックしない。
	Enqueue(broadcastID string, event backend.EventRequest)
}

// Publisher は、RTMPS の接続への送出（*rtmps.Publisher が満たす）。書き込みは、積むだけで、呼び出し元をブロックしない。
type Publisher interface {
	WriteMeta(payload []byte) error
	WriteVideo(timestampMs uint32, payload []byte) error
	WriteAudio(timestampMs uint32, payload []byte) error
	// PendingMs は、送出待ちのメディア時間の幅（ミリ秒）。
	PendingMs() int
	// SentBytes は、RTMP へ書いた本文の合計（バイト）。
	SentBytes() uint64
	// Closed は、終了したとき（切断・書き込みの失敗・送出待ちの上限・Close・Abort）に閉じるチャネル。理由は Err。
	Closed() <-chan struct{}
	// Err は、終了の原因（終了するまでは nil）。errors.Is で、rtmps.ErrBufferOverflow・ErrDisconnected・ErrPublishRejected を判定する。
	Err() error
	// Close は、送出待ちを送り切ってから切断する（最悪で 17 秒ほどかかる）。利用者の停止と時間上限で使う。
	Close() error
	// Abort は、バッファを破棄して直ちに切る。送出世代の交代・同一アカウントの別セッションの排他・心拍の喪失で使う。
	Abort()
}

// OpenRequest は、RTMPS の接続の要求。
type OpenRequest struct {
	// URL は、取り込み先（準備の応答。配信キーを含まない）。
	URL backend.IngestURL
	// StreamKey は、配信キー。メモリにのみ置く。
	StreamKey rtmps.StreamKey
	// Logger は、この接続の記録の出力先（配信レコードの識別子つき）。nil なら、捨てる。
	Logger *slog.Logger
}

// PublisherFactory は、RTMPS の接続を作る。取り込み先を検証し（YouTube の取り込み口に限る）、接続して publish する。
type PublisherFactory interface {
	// Open は、検証・接続・publish まで行う。取り込み先が検証に通らなければ ErrDestinationRejected を包んだエラー
	// （接続を試みない。再試行しても変わらない）。それ以外の失敗は、再試行の対象。
	Open(ctx context.Context, request OpenRequest) (Publisher, error)
}

// BrowserLink は、ブラウザとの WebSocket の接続 1 本への送信と切断（#21 の wsapi が実装する）。
type BrowserLink interface {
	// Send は、符号化済みのフレーム（制御メッセージ 1 つ）を送る。呼び出し元をブロックしない（実装が、書き込みを直列化し、
	// 待ち行列に上限を持つ）。閉じていれば ErrLinkClosed。
	Send(message []byte) error
	// Close は、Close コード code で接続を閉じる。すでに Send したメッセージ（致命通知）を送ってから閉じる。何度呼んでもよい。
	Close(code int)
}

// WebSocket の Close コード（ws-protocol.md の 7.4）。
const (
	// CloseNormal は、通常の切断（致命通知のあとも、これ）。
	CloseNormal = 1000
	// CloseMessageTooBig は、1 メッセージが上限を超えた（致命通知 message_too_large のあと）。
	CloseMessageTooBig = 1009
)

// Deps は、取り込みセッションと台帳の依存。
type Deps struct {
	Backend    Backend
	Events     EventSink
	Publishers PublisherFactory
	Clock      Clock
	// Logger は、異常の記録の出力先（必須）。nil は拒否する（記録が黙って捨てられ、異常に気づけなくならないように。
	// 捨ててよい試験は、捨てる出力先を明示して渡す）。メッセージごとのログは出さない。秘密値・チケット・配信キー・取り込み先を出さない。
	Logger  *slog.Logger
	Options Options
}

// normalized は、依存を検査し、設定値を整える。Backend・Events・Publishers・Clock・Logger のどれかが無ければ ErrInvalidDeps。
func (d Deps) normalized() (Deps, error) {
	if d.Backend == nil || d.Events == nil || d.Publishers == nil || d.Clock == nil || d.Logger == nil {
		return Deps{}, ErrInvalidDeps
	}
	options, err := d.Options.normalized()
	if err != nil {
		return Deps{}, err
	}
	d.Options = options
	return d, nil
}
