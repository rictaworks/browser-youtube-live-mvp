package backend

import (
	"encoding/json"
	"fmt"
	"net/url"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps"
)

// 内部通信の要求・応答の型（契約 internal-api.md の 4 章）。応答は、受け取ったときに検査し、契約の形でなければ ErrInvalidResponse。

const (
	// MaxTicketBytes は、接続チケットの長さの上限（バイト）。チケットは URL 安全な文字の 43 文字ほど。
	MaxTicketBytes = 512

	// maxURLBytes は、応答に含まれる URL（取り込み先・視聴 URL）の長さの上限（バイト）。
	maxURLBytes = 2048

	// jstOffsetSeconds は、事象の時刻の表記（JST）。
	jstOffsetSeconds = 9 * 60 * 60
	timeLayout       = "2006-01-02T15:04:05-07:00"

	uuidLength       = 36
	accountKeyLength = 64

	firstPrintable = 0x21
	lastPrintable  = 0x7E
)

// WarningYouTubeStreamUnhealthy は、通知の警告の値（YouTube のストリームの健全性に問題がある）。
const WarningYouTubeStreamUnhealthy = "youtube_stream_unhealthy"

// NewTicket は、hello の本文（接続チケット）から Ticket を作る。長さ（1 から MaxTicketBytes）と文字（空白・制御文字・非 ASCII を含まない）
// を検査し、不正なら ErrTicketInvalid（アプリケーションを呼ばずに、無効として扱える）。エラーは、チケットの内容を含まない。
func NewTicket(raw []byte) (Ticket, error) {
	if len(raw) == 0 || len(raw) > MaxTicketBytes {
		return "", fmt.Errorf("%w: length %d (want 1..%d)", ErrTicketInvalid, len(raw), MaxTicketBytes)
	}
	for i, b := range raw {
		if b < firstPrintable || b > lastPrintable {
			return "", fmt.Errorf("%w: unexpected character at position %d", ErrTicketInvalid, i)
		}
	}
	return Ticket(raw), nil
}

// ---- 照合 ----

// Limits は、1 配信の上限。
type Limits struct {
	// TimeLimitSeconds は、1 配信の時間上限（秒）。
	TimeLimitSeconds int
}

// VerifyResult は、照合の結果。
type VerifyResult struct {
	// BroadcastID は、配信レコードの識別子（UUID）。
	BroadcastID string
	// State は、配信レコードの状態（reserved・awaiting_media・confirming・live・interrupted のどれか）。
	State contract.BroadcastState
	// Epoch は、新しい送出世代（照合のたびに 1 進めた値）。
	Epoch int
	// AccountKey は、アカウントを区別する不透明な値（64 文字の小文字の 16 進数）。等値の比較だけに使う。
	AccountKey string
	// Profile は、確定済みのプロファイル。準備の前（reserved）は空。
	Profile contract.Profile
	// Limits は、1 配信の上限。
	Limits Limits
}

type verifyWire struct {
	BroadcastID string  `json:"broadcast_id"`
	State       string  `json:"state"`
	Epoch       int     `json:"epoch"`
	AccountKey  string  `json:"account_key"`
	Profile     *string `json:"profile"`
	Limits      struct {
		TimeLimitSeconds int `json:"time_limit_seconds"`
	} `json:"limits"`
}

func (w verifyWire) result() (VerifyResult, error) {
	state := contract.BroadcastState(w.State)
	switch state {
	case contract.BroadcastStateReserved, contract.BroadcastStateAwaitingMedia, contract.BroadcastStateConfirming,
		contract.BroadcastStateLive, contract.BroadcastStateInterrupted:
	default:
		return VerifyResult{}, invalidResponse("verify: state is not attachable")
	}
	if !isUUID(w.BroadcastID) {
		return VerifyResult{}, invalidResponse("verify: broadcast_id is not a UUID")
	}
	if w.Epoch < 1 {
		return VerifyResult{}, invalidResponse("verify: epoch is not positive")
	}
	if !isLowerHex(w.AccountKey, accountKeyLength) {
		return VerifyResult{}, invalidResponse("verify: account_key is not 64 lower-case hex digits")
	}
	var profile contract.Profile
	if w.Profile != nil {
		profile = contract.Profile(*w.Profile)
		if !profile.Valid() {
			return VerifyResult{}, invalidResponse("verify: unknown profile")
		}
	}
	if w.Limits.TimeLimitSeconds < 1 {
		return VerifyResult{}, invalidResponse("verify: time_limit_seconds is not positive")
	}
	return VerifyResult{
		BroadcastID: w.BroadcastID,
		State:       state,
		Epoch:       w.Epoch,
		AccountKey:  w.AccountKey,
		Profile:     profile,
		Limits:      Limits{TimeLimitSeconds: w.Limits.TimeLimitSeconds},
	}, nil
}

// ---- 準備 ----

// Ingest は、取り込み先と配信キー。どちらも、ログ・エラー・%v・JSON に中身を出さない型。
type Ingest struct {
	// URL は、取り込み先（RTMPS。配信キーを含まない）。
	URL IngestURL `json:"url"`
	// StreamKey は、配信キー。この応答でのみ返る。アプリケーションは保存せず、中継はメモリにのみ保持する。
	StreamKey rtmps.StreamKey `json:"stream_key"`
}

// ProvisionResult は、準備の結果。
type ProvisionResult struct {
	Ingest Ingest `json:"ingest"`
	// WatchURL は、視聴 URL（https）。
	WatchURL string `json:"watch_url"`
	// State は、準備のあとの配信レコードの状態。初回は awaiting_media。復帰での再要求では、現在の状態。
	State contract.BroadcastState `json:"state"`
}

func (r ProvisionResult) validate() error {
	if r.Ingest.URL == "" || len(r.Ingest.URL) > maxURLBytes {
		return invalidResponse("provision: ingest.url is empty or too long")
	}
	if err := r.Ingest.StreamKey.Validate(); err != nil {
		return invalidResponse("provision: ingest.stream_key is not usable")
	}
	if err := checkHTTPSURL(r.WatchURL); err != nil {
		return invalidResponse("provision: watch_url is not an https URL")
	}
	if !r.State.Valid() || r.State == contract.BroadcastStateEnded {
		return invalidResponse("provision: state is not valid")
	}
	return nil
}

type provisionRequest struct {
	Epoch   int              `json:"epoch"`
	Profile contract.Profile `json:"profile"`
}

// ---- 心拍 ----

// BrowserEvent は、ブラウザ側の出来事（状態報告の events の 1 要素）。
type BrowserEvent struct {
	Kind contract.BrowserEventKind `json:"kind"`
	// Detail は、符号と数値だけの JSON のオブジェクト（検査済み）。無ければ空。
	Detail json.RawMessage `json:"detail,omitempty"`
}

// BrowserReport は、ブラウザの直近の状態報告（心拍に載せる）。
type BrowserReport struct {
	BacklogMs          int64                `json:"backlog_ms"`
	DroppedVideoFrames int64                `json:"dropped_video_frames"`
	TargetKbps         int                  `json:"target_kbps"`
	State              contract.StudioState `json:"state"`
	// Events は、前回の成功した心拍以降に、ブラウザから届いた出来事すべて（欠落なく）。
	Events []BrowserEvent `json:"events"`
}

// MarshalJSON は、events が空のときも、null ではなく空の配列にする（契約の例のとおり）。
func (r BrowserReport) MarshalJSON() ([]byte, error) {
	type plain BrowserReport
	if r.Events == nil {
		r.Events = []BrowserEvent{}
	}
	return json.Marshal(plain(r))
}

// HeartbeatRequest は、心拍の要求。
type HeartbeatRequest struct {
	// Epoch は、送出世代。
	Epoch int `json:"epoch"`
	// Seq は、心拍の連番（取り込みセッションごと。最初の心拍が 1）。応答を得られなかった心拍は、同じ Seq・同じ内容で再送する。
	Seq int `json:"seq"`
	// Publishing は、RTMPS で送出中なら true（中断中は false）。
	Publishing bool `json:"publishing"`
	// OutKbps は、中継の送出ビットレート（kbps）。
	OutKbps int `json:"out_kbps"`
	// SentBytesDelta は、前回の心拍から、RTMPS へ送った量（バイト）。
	SentBytesDelta uint64 `json:"sent_bytes_delta"`
	// Browser は、ブラウザの直近の状態報告。まだ 1 つも受けていなければ nil。
	Browser *BrowserReport `json:"browser"`
}

// Command は、心拍の応答の指示。
type Command string

const (
	// CommandContinue は、継続。
	CommandContinue Command = "continue"
	// CommandStop は、送出を止める。
	CommandStop Command = "stop"
)

// StopReason は、停止の指示の理由（送出世代が古いときだけ）。
type StopReason string

// ReasonStaleEpoch は、送出世代が古い。
const ReasonStaleEpoch StopReason = "stale_epoch"

// Notice は、ブラウザへ伝える状態の通知（status の全体のスナップショット）。空の文字列・0 は、null を表す。
type Notice struct {
	State contract.BroadcastState
	// WatchURL は、視聴 URL。無ければ空。
	WatchURL string
	// Warning は、WarningYouTubeStreamUnhealthy または空。
	Warning string
	// TimeLimitNoticeSeconds は、時間上限の予告の残り秒数。予告でなければ 0。
	TimeLimitNoticeSeconds int
	// EndReason は、State が ended のときの終了理由。それ以外は空。
	EndReason contract.EndReason
}

// HeartbeatResponse は、心拍の応答。
type HeartbeatResponse struct {
	Command Command
	// Reason は、送出世代が古いときだけ（ReasonStaleEpoch）。
	Reason StopReason
	// EndReason は、停止で、配信が終了しているとき。
	EndReason contract.EndReason
	Notices   []Notice
}

type noticeWire struct {
	Kind                   string  `json:"kind"`
	State                  string  `json:"state"`
	WatchURL               *string `json:"watch_url"`
	Warning                *string `json:"warning"`
	TimeLimitNoticeSeconds *int    `json:"time_limit_notice_seconds"`
	EndReason              *string `json:"end_reason"`
}

type heartbeatWire struct {
	Command   string            `json:"command"`
	Reason    string            `json:"reason"`
	EndReason string            `json:"end_reason"`
	Notices   []json.RawMessage `json:"notices"`
}

func (w heartbeatWire) response() (HeartbeatResponse, error) {
	response := HeartbeatResponse{Command: Command(w.Command), Reason: StopReason(w.Reason), EndReason: contract.EndReason(w.EndReason)}
	switch response.Command {
	case CommandContinue, CommandStop:
	default:
		return HeartbeatResponse{}, invalidResponse("heartbeat: unknown command")
	}
	if response.Reason != "" && response.Reason != ReasonStaleEpoch {
		return HeartbeatResponse{}, invalidResponse("heartbeat: unknown reason")
	}
	if response.EndReason != "" && !response.EndReason.Valid() {
		return HeartbeatResponse{}, invalidResponse("heartbeat: unknown end_reason")
	}
	for _, raw := range w.Notices {
		notice, known, err := parseNotice(raw)
		if err != nil {
			return HeartbeatResponse{}, err
		}
		if known {
			response.Notices = append(response.Notices, notice)
		}
	}
	return response, nil
}

// parseNotice は、通知を 1 つ読む。kind が status ではないものは、前方互換のため無視する（known が false）。
func parseNotice(raw json.RawMessage) (Notice, bool, error) {
	var wire noticeWire
	if err := json.Unmarshal(raw, &wire); err != nil {
		return Notice{}, false, invalidResponse("heartbeat: a notice is not an object")
	}
	if wire.Kind != "status" {
		return Notice{}, false, nil
	}
	notice := Notice{State: contract.BroadcastState(wire.State)}
	if !notice.State.Valid() {
		return Notice{}, false, invalidResponse("heartbeat: a notice has an unknown state")
	}
	if wire.WatchURL != nil {
		if err := checkHTTPSURL(*wire.WatchURL); err != nil {
			return Notice{}, false, invalidResponse("heartbeat: a notice has a watch_url that is not an https URL")
		}
		notice.WatchURL = *wire.WatchURL
	}
	if wire.Warning != nil {
		if *wire.Warning != WarningYouTubeStreamUnhealthy {
			return Notice{}, false, invalidResponse("heartbeat: a notice has an unknown warning")
		}
		notice.Warning = *wire.Warning
	}
	if wire.TimeLimitNoticeSeconds != nil {
		if *wire.TimeLimitNoticeSeconds < 1 {
			return Notice{}, false, invalidResponse("heartbeat: a notice has a time limit notice that is not positive")
		}
		notice.TimeLimitNoticeSeconds = *wire.TimeLimitNoticeSeconds
	}
	if wire.EndReason != nil {
		notice.EndReason = contract.EndReason(*wire.EndReason)
		if !notice.EndReason.Valid() {
			return Notice{}, false, invalidResponse("heartbeat: a notice has an unknown end_reason")
		}
	}
	return notice, true, nil
}

// ---- 事象 ----

// EventRequest は、事象（中継が観測した出来事）の要求。
type EventRequest struct {
	// Epoch は、事象が起きたときの送出世代。
	Epoch int
	// Kind は、事象の種類（列挙 relay_event_kind）。
	Kind contract.RelayEventKind
	// At は、中継が出来事を観測した時刻。アプリケーションが停止している間は、古い時刻のまま再送される。JST で送る。
	At time.Time
	// Cause は、中断（interrupted）では必須。送出失敗（publish_failed）では、rtmps_disconnected・buffer_overflow のときに付ける。
	// それ以外の種類は、空。
	Cause contract.InterruptCause
}

func (e EventRequest) validate() error {
	if e.Epoch < 1 {
		return invalidArgument("event: epoch is not positive")
	}
	if !e.Kind.Valid() {
		return invalidArgument("event: unknown kind")
	}
	if e.At.IsZero() {
		return invalidArgument("event: time is missing")
	}
	switch e.Kind {
	case contract.RelayEventKindInterrupted:
		if !e.Cause.Valid() {
			return invalidArgument("event: interrupted needs a cause")
		}
	case contract.RelayEventKindPublishFailed:
		if e.Cause != "" && e.Cause != contract.InterruptCauseRTMPSDisconnected && e.Cause != contract.InterruptCauseBufferOverflow {
			return invalidArgument("event: publish_failed takes only rtmps_disconnected or buffer_overflow as its cause")
		}
	default:
		if e.Cause != "" {
			return invalidArgument("event: this kind takes no cause")
		}
	}
	return nil
}

// MarshalJSON は、契約の形（at は JST、detail は原因があるときだけ）にする。
func (e EventRequest) MarshalJSON() ([]byte, error) {
	type detail struct {
		Cause contract.InterruptCause `json:"cause"`
	}
	wire := struct {
		Epoch  int                     `json:"epoch"`
		Kind   contract.RelayEventKind `json:"kind"`
		At     string                  `json:"at"`
		Detail *detail                 `json:"detail,omitempty"`
	}{Epoch: e.Epoch, Kind: e.Kind, At: e.At.In(time.FixedZone("JST", jstOffsetSeconds)).Format(timeLayout)}
	if e.Cause != "" {
		wire.Detail = &detail{Cause: e.Cause}
	}
	return json.Marshal(wire)
}

// ---- 検査の補助 ----

func invalidResponse(reason string) error { return fmt.Errorf("%w: %s", ErrInvalidResponse, reason) }

func invalidArgument(reason string) error { return fmt.Errorf("%w: %s", ErrInvalidArgument, reason) }

// isUUID は、8-4-4-4-12 の 16 進数の形か（大文字・小文字を問わない）。パスに入れても安全な文字だけ。
func isUUID(s string) bool {
	if len(s) != uuidLength {
		return false
	}
	for i := 0; i < len(s); i++ {
		switch i {
		case 8, 13, 18, 23:
			if s[i] != '-' {
				return false
			}
		default:
			if !isHexDigit(s[i]) {
				return false
			}
		}
	}
	return true
}

func isHexDigit(b byte) bool {
	return (b >= '0' && b <= '9') || (b >= 'a' && b <= 'f') || (b >= 'A' && b <= 'F')
}

// isLowerHex は、長さが length の、小文字の 16 進数か。
func isLowerHex(s string, length int) bool {
	if len(s) != length {
		return false
	}
	for i := 0; i < len(s); i++ {
		if !((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f')) {
			return false
		}
	}
	return true
}

// checkHTTPSURL は、https で、ホストを持つ URL か（視聴 URL を、画面の href にするため。javascript: などを通さない）。
func checkHTTPSURL(raw string) error {
	if raw == "" || len(raw) > maxURLBytes {
		return ErrInvalidResponse
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.Opaque != "" {
		return ErrInvalidResponse
	}
	return nil
}
