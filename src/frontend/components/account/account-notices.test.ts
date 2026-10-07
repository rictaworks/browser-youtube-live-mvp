/**
 * @jest-environment node
 */
import { CONNECT_RESULT_VALUES } from "@/core/contract";
import {
  ApiAbortedError,
  ApiNetworkError,
  ApiTimeoutError,
  createApiError,
  UnexpectedResponse,
} from "@/lib/api";
import { RecaptchaConfigurationError, RecaptchaExecuteError, RecaptchaLoadError } from "@/lib/recaptcha";
import { t } from "@/messages";
import { noticeForConnectResult, outcomeForFailure, viewOfAccountNotice, type AccountNotice } from "./account-notices";

// アカウント画面の通知。接続の結果（URL の connect）と、操作の失敗を、通知（種類）や次の動作へ対応づける。

describe("noticeForConnectResult: /account?connect=<結果>", () => {
  it("成功（connected・live_not_enabled）は、通知を出さない（状態の表示が変わるため）", () => {
    expect(noticeForConnectResult("connected")).toBeNull();
    expect(noticeForConnectResult("live_not_enabled")).toBeNull();
  });

  it.each([
    ["scope_denied", "connect_scope_denied"],
    ["no_refresh_token", "connect_no_refresh_token"],
    ["no_channel", "connect_no_channel"],
    ["unverifiable", "unverifiable"],
  ] as const)("不成立 %s は、通知 %s", (result, kind) => {
    expect(noticeForConnectResult(result)).toEqual({ kind, retryAt: null });
  });

  it("契約の 6 つの結果すべてを、扱う（成功 2・不成立 4）", () => {
    const handled = CONNECT_RESULT_VALUES.map((result) => noticeForConnectResult(result)?.kind ?? "success");

    expect(handled).toEqual(["success", "success", "connect_scope_denied", "connect_no_refresh_token", "connect_no_channel", "unverifiable"]);
  });
});

describe("outcomeForFailure: 操作の失敗への対応", () => {
  const notLoggedIn = createApiError(401, "not_logged_in", {});
  const csrf = createApiError(403, "csrf_invalid", {});

  it("401（セッション切れ）は、どの操作でも、ランディングへ戻す", () => {
    for (const action of ["recheck", "connect", "disconnect", "delete", "logout"] as const) {
      expect(outcomeForFailure(notLoggedIn, action)).toEqual({ type: "redirect_home" });
    }
  });

  it("403 csrf_invalid は、状態を取得し直して（トークンの更新）、一般的な失敗の通知を出す", () => {
    expect(outcomeForFailure(csrf, "recheck")).toEqual({ type: "refresh", notice: { kind: "failed", retryAt: null } });
  });

  it("409 broadcast_in_progress は、状態を取得し直す（進行中の配信の案内が出る）。通知は出さない", () => {
    for (const action of ["connect", "disconnect", "delete"] as const) {
      expect(outcomeForFailure(createApiError(409, "broadcast_in_progress", {}), action)).toEqual({ type: "refresh", notice: null });
    }
  });

  it("409 not_connected（再確認）は、状態を取得し直す（未接続の表示になる）。通知は出さない", () => {
    expect(outcomeForFailure(createApiError(409, "not_connected", {}), "recheck")).toEqual({ type: "refresh", notice: null });
  });

  it("再確認の 429 は、再確認の頻度超過の通知（再試行の目安時刻つき）", () => {
    expect(outcomeForFailure(createApiError(429, "rate_limited", { retry_at: "2026-10-07T13:31:00+09:00" }), "recheck")).toEqual({
      type: "notice",
      notice: { kind: "recheck_rate_limited", retryAt: "2026-10-07T13:31:00+09:00" },
    });
  });

  it("接続の開始の 429 は、接続の頻度超過の通知（再試行の目安時刻つき）", () => {
    expect(outcomeForFailure(createApiError(429, "rate_limited", { retry_at: "2026-10-07T14:30:00+09:00" }), "connect")).toEqual({
      type: "notice",
      notice: { kind: "connect_rate_limited", retryAt: "2026-10-07T14:30:00+09:00" },
    });
  });

  it("接続の開始の 403 bot_check_failed と、bot 判定の取得の失敗は、bot 判定の通知。サイトキーの設定エラーは、設定エラーの通知", () => {
    expect(outcomeForFailure(createApiError(403, "bot_check_failed", {}), "connect")).toEqual({
      type: "notice",
      notice: { kind: "bot_check_failed", retryAt: null },
    });
    expect(outcomeForFailure(new RecaptchaLoadError("script_error"), "connect")).toEqual({
      type: "notice",
      notice: { kind: "bot_check_failed", retryAt: null },
    });
    expect(outcomeForFailure(new RecaptchaExecuteError("x"), "connect")).toEqual({
      type: "notice",
      notice: { kind: "bot_check_failed", retryAt: null },
    });
    expect(outcomeForFailure(new RecaptchaConfigurationError("missing"), "connect")).toEqual({
      type: "notice",
      notice: { kind: "recaptcha_not_configured", retryAt: null },
    });
  });

  it("再確認の 503 unverifiable は、確認できなかった旨の通知（接続の状態は変わらない）", () => {
    expect(outcomeForFailure(createApiError(503, "unverifiable", {}), "recheck")).toEqual({
      type: "notice",
      notice: { kind: "unverifiable", retryAt: null },
    });
  });

  it.each([
    ["契約に無い応答", new UnexpectedResponse(404, "x")],
    ["通信の失敗", new ApiNetworkError(new TypeError("x"))],
    ["時間切れ", new ApiTimeoutError(35_000)],
    ["中継の 502", createApiError(502, "bad_gateway", {})],
    ["500", createApiError(500, "internal_error", {})],
    ["想定外の Error", new Error("x")],
  ])("%s は、一般的な失敗の通知", (_title, error) => {
    expect(outcomeForFailure(error, "disconnect")).toEqual({ type: "notice", notice: { kind: "failed", retryAt: null } });
  });

  it("再確認以外の 503 unverifiable・429 は、一般的な失敗（契約に無い組み合わせを、別の通知へ倒さない）", () => {
    expect(outcomeForFailure(createApiError(503, "unverifiable", {}), "disconnect")).toEqual({
      type: "notice",
      notice: { kind: "failed", retryAt: null },
    });
    expect(outcomeForFailure(createApiError(429, "rate_limited", {}), "logout")).toEqual({
      type: "notice",
      notice: { kind: "failed", retryAt: null },
    });
  });

  it("呼び出し側の中断（ApiAbortedError）は、何もしない", () => {
    expect(outcomeForFailure(new ApiAbortedError(), "recheck")).toEqual({ type: "ignore" });
  });
});

describe("viewOfAccountNotice: 通知の表示（色・文言。断定と対処）", () => {
  it.each([
    ["connect_scope_denied", "error", "connectResult.scopeDenied"],
    ["connect_no_refresh_token", "error", "connectResult.noRefreshToken"],
    ["connect_no_channel", "warning", "connectResult.noChannel"],
    ["unverifiable", "warning", "connectResult.unverifiable"],
  ] as const)("%s: 色 %s・モックの文言（%s）", (kind, tone, path) => {
    const view = viewOfAccountNotice({ kind, retryAt: null });
    const keys = {
      "connectResult.scopeDenied": ["provisional.account.connectResult.scopeDenied.title", "provisional.account.connectResult.scopeDenied.body"],
      "connectResult.noRefreshToken": [
        "provisional.account.connectResult.noRefreshToken.title",
        "provisional.account.connectResult.noRefreshToken.body",
      ],
      "connectResult.noChannel": ["provisional.account.connectResult.noChannel.title", "provisional.account.connectResult.noChannel.body"],
      "connectResult.unverifiable": [
        "provisional.account.connectResult.unverifiable.title",
        "provisional.account.connectResult.unverifiable.body",
      ],
    } as const;
    const [titleKey, bodyKey] = keys[path];

    expect(view).toEqual({ tone, title: t(titleKey), body: t(bodyKey) });
  });

  it("bot 判定: 警告（共通の文言）。設定エラー: エラー。一般的な失敗: エラー（システムの文言）", () => {
    expect(viewOfAccountNotice({ kind: "bot_check_failed", retryAt: null })).toEqual({
      tone: "warning",
      title: t("provisional.apiNotice.botCheckFailed.title"),
      body: t("provisional.apiNotice.botCheckFailed.body"),
    });
    expect(viewOfAccountNotice({ kind: "recaptcha_not_configured", retryAt: null })).toEqual({
      tone: "error",
      title: t("provisional.apiNotice.recaptchaNotConfigured.title"),
      body: t("provisional.apiNotice.recaptchaNotConfigured.body"),
    });
    expect(viewOfAccountNotice({ kind: "failed", retryAt: null })).toEqual({
      tone: "error",
      title: t("provisional.error.notice.title"),
      body: t("provisional.error.notice.body"),
    });
  });

  it("頻度超過（接続・再確認）: 警告。再試行の目安時刻（JST）を、本文へ添える。時刻が無ければ添えない", () => {
    const connect: AccountNotice = { kind: "connect_rate_limited", retryAt: "2026-10-07T14:30:00+09:00" };
    const recheck: AccountNotice = { kind: "recheck_rate_limited", retryAt: "2026-10-07T13:31:00+09:00" };

    expect(viewOfAccountNotice(connect)).toEqual({
      tone: "warning",
      title: t("provisional.account.notice.connectRateLimited.title"),
      body: `${t("provisional.account.notice.connectRateLimited.body")} ${t("provisional.apiNotice.retryAt", { time: "2026-10-07 14:30" })}`,
    });
    expect(viewOfAccountNotice(recheck)).toEqual({
      tone: "warning",
      title: t("provisional.account.notice.recheckRateLimited.title"),
      body: `${t("provisional.account.notice.recheckRateLimited.body")} ${t("provisional.apiNotice.retryAt", { time: "2026-10-07 13:31" })}`,
    });
    expect(viewOfAccountNotice({ kind: "recheck_rate_limited", retryAt: null }).body).toBe(t("provisional.account.notice.recheckRateLimited.body"));
  });
});
