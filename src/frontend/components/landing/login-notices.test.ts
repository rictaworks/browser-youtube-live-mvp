/**
 * @jest-environment node
 */
import {
  ApiAbortedError,
  ApiNetworkError,
  ApiTimeoutError,
  createApiError,
  UnexpectedResponse,
  UnsafeAuthorizationUrlError,
} from "@/lib/api";
import { RecaptchaConfigurationError, RecaptchaExecuteError, RecaptchaLoadError } from "@/lib/recaptcha";
import { t } from "@/messages";
import { noticeForFailure, noticeForLoginError, viewOfLoginNotice } from "./login-notices";

// ログインの失敗・拒否を、通知の種類（kind）にする。種類ごとの表示（色・図形・文言）は、viewOfLoginNotice。

describe("noticeForLoginError（/?login_error=<符号>）", () => {
  it("registration_held（再登録の保留）と oauth_failed を、通知の種類にする", () => {
    expect(noticeForLoginError("registration_held")).toEqual({ kind: "registration_held", retryAt: null });
    expect(noticeForLoginError("oauth_failed")).toEqual({ kind: "oauth_failed", retryAt: null });
  });
});

describe("noticeForFailure（ログイン開始の失敗）", () => {
  it("403 bot_check_failed は、bot 判定の通知", () => {
    expect(noticeForFailure(createApiError(403, "bot_check_failed", {}))).toEqual({ kind: "bot_check_failed", retryAt: null });
  });

  it("429 rate_limited は、頻度超過の通知（再試行の目安時刻を持つ）", () => {
    expect(noticeForFailure(createApiError(429, "rate_limited", { retry_at: "2026-10-07T14:30:00+09:00" }))).toEqual({
      kind: "rate_limited",
      retryAt: "2026-10-07T14:30:00+09:00",
    });
    expect(noticeForFailure(createApiError(429, "rate_limited", {}))).toEqual({ kind: "rate_limited", retryAt: null });
  });

  it("サイトキーの設定エラーは、設定エラーの通知", () => {
    expect(noticeForFailure(new RecaptchaConfigurationError("missing"))).toEqual({ kind: "recaptcha_not_configured", retryAt: null });
    expect(noticeForFailure(new RecaptchaConfigurationError("invalid"))).toEqual({ kind: "recaptcha_not_configured", retryAt: null });
  });

  it("bot 判定のスクリプトの読み込み・トークンの取得の失敗は、bot 判定の通知", () => {
    expect(noticeForFailure(new RecaptchaLoadError("script_error"))).toEqual({ kind: "bot_check_failed", retryAt: null });
    expect(noticeForFailure(new RecaptchaExecuteError("reCAPTCHA execute failed"))).toEqual({ kind: "bot_check_failed", retryAt: null });
  });

  it.each([
    ["契約に無い応答", new UnexpectedResponse(404, "error response is not JSON")],
    ["通信の失敗", new ApiNetworkError(new TypeError("fetch failed"))],
    ["時間切れ", new ApiTimeoutError(35_000)],
    ["中継の 502（bad_gateway）", createApiError(502, "bad_gateway", {})],
    ["500 internal_error", createApiError(500, "internal_error", {})],
    ["422 invalid_input", createApiError(422, "invalid_input", {})],
    ["403 csrf_invalid", createApiError(403, "csrf_invalid", {})],
    ["認可 URL の検査の失敗", new UnsafeAuthorizationUrlError()],
    ["想定外の Error", new Error("unexpected")],
    ["Error でない値", "boom"],
  ])("%s は、一般的な失敗の通知", (_title, error) => {
    expect(noticeForFailure(error)).toEqual({ kind: "failed", retryAt: null });
  });

  it("呼び出し側の中断（ApiAbortedError）は、通知にしない（null）", () => {
    expect(noticeForFailure(new ApiAbortedError())).toBeNull();
  });
});

describe("viewOfLoginNotice（通知の表示: 色・図形・文言）", () => {
  it("再登録の保留: 情報（モックの文言。断定と対処）", () => {
    expect(viewOfLoginNotice({ kind: "registration_held", retryAt: null })).toEqual({
      tone: "info",
      title: t("provisional.landing.notice.registrationHeld.title"),
      body: t("provisional.landing.notice.registrationHeld.body"),
    });
  });

  it("bot 判定: 警告", () => {
    expect(viewOfLoginNotice({ kind: "bot_check_failed", retryAt: null })).toEqual({
      tone: "warning",
      title: t("provisional.apiNotice.botCheckFailed.title"),
      body: t("provisional.apiNotice.botCheckFailed.body"),
    });
  });

  it("頻度超過: 警告。再試行の目安時刻（JST）を、本文へ添える", () => {
    const view = viewOfLoginNotice({ kind: "rate_limited", retryAt: "2026-10-07T14:30:00+09:00" });

    expect(view.tone).toBe("warning");
    expect(view.title).toBe(t("provisional.landing.notice.rateLimited.title"));
    expect(view.body).toBe(
      `${t("provisional.landing.notice.rateLimited.body")} ${t("provisional.apiNotice.retryAt", { time: "2026-10-07 14:30" })}`,
    );
  });

  it("頻度超過で、目安時刻が無い（または解釈できない）ときは、時刻を添えない", () => {
    expect(viewOfLoginNotice({ kind: "rate_limited", retryAt: null }).body).toBe(t("provisional.landing.notice.rateLimited.body"));
    expect(viewOfLoginNotice({ kind: "rate_limited", retryAt: "garbage" }).body).toBe(t("provisional.landing.notice.rateLimited.body"));
  });

  it("oauth_failed: エラー", () => {
    expect(viewOfLoginNotice({ kind: "oauth_failed", retryAt: null })).toEqual({
      tone: "error",
      title: t("provisional.landing.notice.oauthFailed.title"),
      body: t("provisional.landing.notice.oauthFailed.body"),
    });
  });

  it("サイトキーの設定エラー: エラー（運用者向けの事実の文）", () => {
    expect(viewOfLoginNotice({ kind: "recaptcha_not_configured", retryAt: null })).toEqual({
      tone: "error",
      title: t("provisional.apiNotice.recaptchaNotConfigured.title"),
      body: t("provisional.apiNotice.recaptchaNotConfigured.body"),
    });
  });

  it("一般的な失敗: エラー（断定と対処。システムのエラーの文言）", () => {
    expect(viewOfLoginNotice({ kind: "failed", retryAt: null })).toEqual({
      tone: "error",
      title: t("provisional.error.notice.title"),
      body: t("provisional.error.notice.body"),
    });
  });
});
