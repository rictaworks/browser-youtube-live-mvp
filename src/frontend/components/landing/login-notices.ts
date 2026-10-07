import type { LoginError } from "@/core/contract";
import type { NoticeTone } from "@/components/ui";
import { ApiAbortedError, ApiError, formatApiTimestamp } from "@/lib/api";
import { RecaptchaConfigurationError, RecaptchaExecuteError, RecaptchaLoadError } from "@/lib/recaptcha";
import { t } from "@/messages";

// ログインの拒否・失敗の通知。要因（URL の login_error・API のエラー・bot 判定のエラー）を通知の種類にし、種類ごとの表示（色・文言）を返す。
// 文言は、断定（何が起きたか）と対処（次に何をすればよいか）の構成（要件 17.1）。

export type LoginNoticeKind =
  | LoginError
  | "bot_check_failed"
  | "rate_limited"
  | "recaptcha_not_configured"
  | "failed";

export interface LoginNotice {
  readonly kind: LoginNoticeKind;
  /** 頻度超過のときの、再試行の目安時刻（ISO 8601）。無ければ null */
  readonly retryAt: string | null;
}

export interface LoginNoticeView {
  readonly tone: NoticeTone;
  readonly title: string;
  readonly body: string;
}

/** /?login_error=<符号>（認可コードのコールバックの失敗）の通知 */
export function noticeForLoginError(error: LoginError): LoginNotice {
  return { kind: error, retryAt: null };
}

/**
 * ログインの開始に失敗したときの通知。呼び出し側が中断した（ApiAbortedError）ときは、通知しない（null）。
 * 契約に無い応答・通信の失敗・時間切れ・遷移を許さない認可 URL などは、一般的な失敗の通知にする（成功にも、別の理由にもしない）。
 */
export function noticeForFailure(error: unknown): LoginNotice | null {
  if (error instanceof ApiAbortedError) {
    return null;
  }
  if (error instanceof RecaptchaConfigurationError) {
    return { kind: "recaptcha_not_configured", retryAt: null };
  }
  if (error instanceof RecaptchaLoadError || error instanceof RecaptchaExecuteError) {
    return { kind: "bot_check_failed", retryAt: null };
  }
  if (error instanceof ApiError) {
    if (error.code === "bot_check_failed") {
      return { kind: "bot_check_failed", retryAt: null };
    }
    if (error.code === "rate_limited") {
      return { kind: "rate_limited", retryAt: error.retryAt };
    }
  }
  return { kind: "failed", retryAt: null };
}

/** 通知の種類ごとの、色（情報・警告・エラー）と文言 */
export function viewOfLoginNotice(notice: LoginNotice): LoginNoticeView {
  switch (notice.kind) {
    case "registration_held":
      return {
        tone: "info",
        title: t("provisional.landing.notice.registrationHeld.title"),
        body: t("provisional.landing.notice.registrationHeld.body"),
      };
    case "oauth_failed":
      return {
        tone: "error",
        title: t("provisional.landing.notice.oauthFailed.title"),
        body: t("provisional.landing.notice.oauthFailed.body"),
      };
    case "bot_check_failed":
      return {
        tone: "warning",
        title: t("provisional.apiNotice.botCheckFailed.title"),
        body: t("provisional.apiNotice.botCheckFailed.body"),
      };
    case "rate_limited": {
      const time = formatApiTimestamp(notice.retryAt);
      const body = t("provisional.landing.notice.rateLimited.body");
      return {
        tone: "warning",
        title: t("provisional.landing.notice.rateLimited.title"),
        body: time === null ? body : `${body} ${t("provisional.apiNotice.retryAt", { time })}`,
      };
    }
    case "recaptcha_not_configured":
      return {
        tone: "error",
        title: t("provisional.apiNotice.recaptchaNotConfigured.title"),
        body: t("provisional.apiNotice.recaptchaNotConfigured.body"),
      };
    case "failed":
      return {
        tone: "error",
        title: t("provisional.error.notice.title"),
        body: t("provisional.error.notice.body"),
      };
  }
}
