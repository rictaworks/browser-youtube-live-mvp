import type { ConnectResult } from "@/core/contract";
import type { NoticeTone } from "@/components/ui";
import { ApiAbortedError, ApiError, formatApiTimestamp } from "@/lib/api";
import { RecaptchaConfigurationError, RecaptchaExecuteError, RecaptchaLoadError } from "@/lib/recaptcha";
import { t } from "@/messages";

// アカウント画面の通知と、操作の失敗への対応。要因（URL の connect・API のエラー・bot 判定のエラー）を、通知の種類や次の動作にする。
// 文言は、断定（何が起きたか）と対処（次に何をすればよいか）の構成（要件 17.1）。

export type AccountNoticeKind =
  | "connect_scope_denied"
  | "connect_no_refresh_token"
  | "connect_no_channel"
  | "unverifiable"
  | "bot_check_failed"
  | "recaptcha_not_configured"
  | "connect_rate_limited"
  | "recheck_rate_limited"
  | "failed";

export interface AccountNotice {
  readonly kind: AccountNoticeKind;
  /** 頻度超過のときの、再試行の目安時刻（ISO 8601）。無ければ null */
  readonly retryAt: string | null;
}

export interface AccountNoticeView {
  readonly tone: NoticeTone;
  readonly title: string;
  readonly body: string;
}

const FAILED: AccountNotice = { kind: "failed", retryAt: null };

/**
 * /account?connect=<結果>（YouTube 接続の戻り先）の通知。成功（connected・live_not_enabled）は、状態の表示が変わるため、通知を出さない（null）。
 * 不成立の 4 つ（権限の拒否・更新トークンなし・チャンネルなし・確認不能）は、通知にする。
 */
export function noticeForConnectResult(result: ConnectResult): AccountNotice | null {
  switch (result) {
    case "connected":
    case "live_not_enabled":
      return null;
    case "scope_denied":
      return { kind: "connect_scope_denied", retryAt: null };
    case "no_refresh_token":
      return { kind: "connect_no_refresh_token", retryAt: null };
    case "no_channel":
      return { kind: "connect_no_channel", retryAt: null };
    case "unverifiable":
      return { kind: "unverifiable", retryAt: null };
  }
}

/** 操作（アカウント画面のボタン）の種類 */
export type AccountAction = "recheck" | "connect" | "disconnect" | "delete" | "logout";

/** 失敗したあとの動作 */
export type FailureOutcome =
  /** セッションが無い。ランディングへ戻す */
  | { readonly type: "redirect_home" }
  /** 状態を取得し直す（CSRF トークンの更新・進行中の配信の反映・接続状態の反映）。通知があれば出す */
  | { readonly type: "refresh"; readonly notice: AccountNotice | null }
  /** 通知を出す */
  | { readonly type: "notice"; readonly notice: AccountNotice }
  /** 何もしない（呼び出し側が中断した） */
  | { readonly type: "ignore" };

function noticeOutcome(notice: AccountNotice): FailureOutcome {
  return { type: "notice", notice };
}

function outcomeForApiError(error: ApiError, action: AccountAction): FailureOutcome {
  switch (error.code) {
    case "not_logged_in":
      return { type: "redirect_home" };
    case "csrf_invalid":
      // トークンの期限切れ・不一致。状態を取得し直して、新しいトークンを受け取る（操作は、利用者がやり直す）
      return { type: "refresh", notice: FAILED };
    case "broadcast_in_progress":
      return { type: "refresh", notice: null };
    case "not_connected":
      return action === "recheck" ? { type: "refresh", notice: null } : noticeOutcome(FAILED);
    case "bot_check_failed":
      return action === "connect" ? noticeOutcome({ kind: "bot_check_failed", retryAt: null }) : noticeOutcome(FAILED);
    case "rate_limited":
      if (action === "connect") {
        return noticeOutcome({ kind: "connect_rate_limited", retryAt: error.retryAt });
      }
      return action === "recheck" ? noticeOutcome({ kind: "recheck_rate_limited", retryAt: error.retryAt }) : noticeOutcome(FAILED);
    case "unverifiable":
      return action === "recheck" ? noticeOutcome({ kind: "unverifiable", retryAt: null }) : noticeOutcome(FAILED);
    default:
      return noticeOutcome(FAILED);
  }
}

/**
 * 操作の失敗への対応。契約の組み合わせ（操作ごとの、返りうるエラー）に当てはまるものだけを、個別の通知にし、
 * 契約に無い応答・通信の失敗・時間切れ・契約に無い組み合わせは、一般的な失敗の通知にする（成功にも、別の理由にもしない）。
 */
export function outcomeForFailure(error: unknown, action: AccountAction): FailureOutcome {
  if (error instanceof ApiAbortedError) {
    return { type: "ignore" };
  }
  if (error instanceof RecaptchaConfigurationError) {
    return noticeOutcome({ kind: "recaptcha_not_configured", retryAt: null });
  }
  if (error instanceof RecaptchaLoadError || error instanceof RecaptchaExecuteError) {
    return noticeOutcome({ kind: "bot_check_failed", retryAt: null });
  }
  if (error instanceof ApiError) {
    return outcomeForApiError(error, action);
  }
  return noticeOutcome(FAILED);
}

function withRetryTime(body: string, retryAt: string | null): string {
  const time = formatApiTimestamp(retryAt);
  return time === null ? body : `${body} ${t("provisional.apiNotice.retryAt", { time })}`;
}

/** 通知の種類ごとの、色（情報・警告・エラー）と文言 */
export function viewOfAccountNotice(notice: AccountNotice): AccountNoticeView {
  switch (notice.kind) {
    case "connect_scope_denied":
      return {
        tone: "error",
        title: t("provisional.account.connectResult.scopeDenied.title"),
        body: t("provisional.account.connectResult.scopeDenied.body"),
      };
    case "connect_no_refresh_token":
      return {
        tone: "error",
        title: t("provisional.account.connectResult.noRefreshToken.title"),
        body: t("provisional.account.connectResult.noRefreshToken.body"),
      };
    case "connect_no_channel":
      return {
        tone: "warning",
        title: t("provisional.account.connectResult.noChannel.title"),
        body: t("provisional.account.connectResult.noChannel.body"),
      };
    case "unverifiable":
      return {
        tone: "warning",
        title: t("provisional.account.connectResult.unverifiable.title"),
        body: t("provisional.account.connectResult.unverifiable.body"),
      };
    case "bot_check_failed":
      return {
        tone: "warning",
        title: t("provisional.apiNotice.botCheckFailed.title"),
        body: t("provisional.apiNotice.botCheckFailed.body"),
      };
    case "recaptcha_not_configured":
      return {
        tone: "error",
        title: t("provisional.apiNotice.recaptchaNotConfigured.title"),
        body: t("provisional.apiNotice.recaptchaNotConfigured.body"),
      };
    case "connect_rate_limited":
      return {
        tone: "warning",
        title: t("provisional.account.notice.connectRateLimited.title"),
        body: withRetryTime(t("provisional.account.notice.connectRateLimited.body"), notice.retryAt),
      };
    case "recheck_rate_limited":
      return {
        tone: "warning",
        title: t("provisional.account.notice.recheckRateLimited.title"),
        body: withRetryTime(t("provisional.account.notice.recheckRateLimited.body"), notice.retryAt),
      };
    case "failed":
      return {
        tone: "error",
        title: t("provisional.error.notice.title"),
        body: t("provisional.error.notice.body"),
      };
  }
}
