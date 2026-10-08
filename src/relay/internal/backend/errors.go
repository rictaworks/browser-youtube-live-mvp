package backend

import (
	"fmt"
	"net/http"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// Error は、このパッケージのエラー（定数。errors.Is で判定できる）。
type Error string

func (e Error) Error() string { return string(e) }

// 呼び出しの前の失敗（設定・引数）と、通信そのものの失敗。
const (
	// ErrInvalidConfig は、設定が不正（URL・秘密値・期限）。文言は、設定の値を含まない。
	ErrInvalidConfig Error = "backend: invalid config"
	// ErrInvalidArgument は、呼び出しの引数が不正（配信の識別子・世代・プロファイル・事象の内容）。要求は送らない。
	ErrInvalidArgument Error = "backend: invalid argument"
	// ErrUnavailable は、アプリケーションへ到達できない（接続の失敗・期限切れ・5xx）。再送の対象。
	// 呼び出し側の取り消し（context.Canceled）は、これではない。
	ErrUnavailable Error = "backend: the application is unreachable or failed"
	// ErrInvalidResponse は、アプリケーションの応答が、契約の形ではない（JSON でない・必須の項目が無い・値が不正・大きすぎる）。
	ErrInvalidResponse Error = "backend: invalid response from the application"
	// ErrUnexpectedStatus は、契約に無い HTTP ステータス（リダイレクトを含む）、または契約に無い符号とステータスの組。
	ErrUnexpectedStatus Error = "backend: unexpected HTTP status"
)

// アプリケーションが返すエラー（契約 internal-api.md の 2 章）。errors.Is で判定でき、*APIError が詳細を持つ。
const (
	// ErrUnauthorized は、X-Relay-Secret が欠落している、または一致しない（401）。
	ErrUnauthorized Error = "backend: unauthorized"
	// ErrNotFound は、配信が存在しない（404 not_found）。
	ErrNotFound Error = "backend: broadcast not found"
	// ErrInvalidInput は、JSON を解釈できない・必須の項目が無い・値が不正（422）。
	ErrInvalidInput Error = "backend: the application rejected the input"
	// ErrTicketInvalid は、接続チケットが、未知・失効・使用済みのいずれか（404 ticket_invalid）。
	ErrTicketInvalid Error = "backend: ticket is invalid"
	// ErrBroadcastNotAttachable は、配信が終了済み、または状態が不適（409 broadcast_not_attachable）。
	ErrBroadcastNotAttachable Error = "backend: broadcast is not attachable"
	// ErrStaleEpoch は、送出世代が最新と一致しない（409 stale_epoch）。
	ErrStaleEpoch Error = "backend: stale epoch"
	// ErrBroadcastEnded は、配信が終了済み（409 broadcast_ended）。*APIError.EndReason に終了理由。
	ErrBroadcastEnded Error = "backend: broadcast has ended"
	// ErrPriorUnsettled は、先行配信が未清算で、準備を中止し、配信を終了した（422 prior_unsettled）。
	ErrPriorUnsettled Error = "backend: prior broadcast is unsettled"
	// ErrPrepareFailed は、準備に失敗し、配信を終了した（502 prepare_failed）。
	ErrPrepareFailed Error = "backend: preparation failed"
	// ErrAuthorizationRevoked は、認可が失効していて、配信を終了した（409 authorization_revoked）。
	ErrAuthorizationRevoked Error = "backend: authorization revoked"
	// ErrLiveNotEnabled は、ライブ配信が有効でない（制限中を含む）ため、配信を終了した（409 live_not_enabled）。
	ErrLiveNotEnabled Error = "backend: live streaming is not enabled"
)

// codeSpec は、契約の 2 章の、符号に対応するエラーと HTTP ステータス。
type codeSpec struct {
	err    Error
	status int
}

// codeSpecOf は、符号（契約の語彙）の仕様を返す。契約に無い符号は false。
func codeSpecOf(code string) (codeSpec, bool) {
	switch code {
	case "unauthorized":
		return codeSpec{ErrUnauthorized, http.StatusUnauthorized}, true
	case "not_found":
		return codeSpec{ErrNotFound, http.StatusNotFound}, true
	case "invalid_input":
		return codeSpec{ErrInvalidInput, http.StatusUnprocessableEntity}, true
	case "ticket_invalid":
		return codeSpec{ErrTicketInvalid, http.StatusNotFound}, true
	case "broadcast_not_attachable":
		return codeSpec{ErrBroadcastNotAttachable, http.StatusConflict}, true
	case "stale_epoch":
		return codeSpec{ErrStaleEpoch, http.StatusConflict}, true
	case "broadcast_ended":
		return codeSpec{ErrBroadcastEnded, http.StatusConflict}, true
	case "prior_unsettled":
		return codeSpec{ErrPriorUnsettled, http.StatusUnprocessableEntity}, true
	case "prepare_failed":
		return codeSpec{ErrPrepareFailed, http.StatusBadGateway}, true
	case "authorization_revoked":
		return codeSpec{ErrAuthorizationRevoked, http.StatusConflict}, true
	case "live_not_enabled":
		return codeSpec{ErrLiveNotEnabled, http.StatusConflict}, true
	}
	return codeSpec{}, false
}

// APIError は、アプリケーションが返したエラー（成功ではない応答）。errors.Is(err, ErrXxx) で種類を判定する。
//
// Code は、契約の語彙の符号だけ（契約に無い符号、または契約のステータスと合わない符号は空。応答の本文を写さない）。
// 符号が空のとき、5xx は ErrUnavailable、それ以外は ErrUnexpectedStatus として扱う。
// EndReason は、provision の失敗の details の end_reason（列挙 end_reason の値だけ。それ以外は空）。
type APIError struct {
	Call      contract.InternalCall
	Status    int
	Code      string
	EndReason contract.EndReason

	kind Error
}

// NewAPIError は、アプリケーションが返したエラーを再現する *APIError を作る（他のパッケージの疑似の実装・試験が、
// 型付きのエラーを返すため）。符号は、契約の語彙で、ステータスと合うものだけを採る。それ以外は、Client と同じ扱い
// （5xx は ErrUnavailable、それ以外は ErrUnexpectedStatus）。endReason は、列挙 end_reason の値だけを採る。
func NewAPIError(call contract.InternalCall, status int, code string, endReason contract.EndReason) *APIError {
	return buildAPIError(call, status, code, endReason)
}

// buildAPIError は、Client の応答の処理と NewAPIError が共有する、*APIError の組み立て。
func buildAPIError(call contract.InternalCall, status int, code string, endReason contract.EndReason) *APIError {
	result := &APIError{Call: call, Status: status}
	if spec, known := codeSpecOf(code); known && spec.status == status {
		result.Code = code
		result.kind = spec.err
		if endReason.Valid() {
			result.EndReason = endReason
		}
	}
	if result.kind == "" {
		if status >= http.StatusInternalServerError {
			result.kind = ErrUnavailable
		} else {
			result.kind = ErrUnexpectedStatus
		}
	}
	return result
}

// Error は、呼び出し・ステータス・符号（契約の語彙）だけを示す。応答の本文・ヘッダを含まない。
func (e *APIError) Error() string {
	if e.Code != "" {
		return fmt.Sprintf("backend: %s: HTTP %d %s", e.Call, e.Status, e.Code)
	}
	return fmt.Sprintf("backend: %s: HTTP %d", e.Call, e.Status)
}

// Unwrap は、種類のエラー（ErrXxx）を返す。
func (e *APIError) Unwrap() error { return e.kind }
