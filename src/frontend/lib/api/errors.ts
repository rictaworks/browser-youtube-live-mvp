import { isEndReason, type EndReason, type RejectionReason, type Resolution } from "@/core/contract";
import type { ApiErrorCode } from "./error-codes";

// API クライアントのエラー。メッセージは、符号・ステータス・位置だけを持つ（トークン・応答の本文・URL を含めない）。
// 利用者へ表示する文言は、これらの型を見て、画面が文言カタログから選ぶ（ここに文言を持たない）。

/** すべてのエラーの親。API クライアントが投げるものを、まとめて受けられる */
export abstract class ApiClientError extends Error {}

/** 契約 1.6 のエラー（{"error":{"code":"<符号>","details":{...}}}）。HTTP ステータスと符号を持つ */
export class ApiError extends ApiClientError {
  readonly status: number;
  readonly code: ApiErrorCode;
  /** 符号ごとの補足（rate_limited の retry_at など）。画面へ出す前に、型を確かめて使う（アクセサを使う） */
  readonly details: Readonly<Record<string, unknown>>;

  constructor(status: number, code: ApiErrorCode, details: Readonly<Record<string, unknown>>) {
    super(`API error ${status} ${code}`);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.details = details;
  }

  /** 頻度の枠が空く時刻（rate_limited の details.retry_at）。無い・文字列でなければ null */
  get retryAt(): string | null {
    const value = this.details.retry_at;
    return typeof value === "string" ? value : null;
  }

  /** 終了理由（broadcast_ended の details.end_reason）。無い・列挙の値でなければ null */
  get endReason(): EndReason | null {
    const value = this.details.end_reason;
    return isEndReason(value) ? value : null;
  }

  /** 不備のある項目名（invalid_input の details.fields）。無い・文字列の配列でなければ null */
  get fields(): readonly string[] | null {
    const value = this.details.fields;
    return Array.isArray(value) && value.every((item): item is string => typeof item === "string") ? value : null;
  }
}

/** 401 not_logged_in。セッションが無い・切れた。ログインへ誘導する */
export class NotLoggedInError extends ApiError {
  constructor(status: number, details: Readonly<Record<string, unknown>>) {
    super(status, "not_logged_in", details);
    this.name = "NotLoggedInError";
  }
}

/** 403 csrf_invalid。CSRF トークンの期限切れ・不一致。状態を取得し直して、操作をやり直す */
export class CsrfInvalidError extends ApiError {
  constructor(status: number, details: Readonly<Record<string, unknown>>) {
    super(status, "csrf_invalid", details);
    this.name = "CsrfInvalidError";
  }
}

/** 符号に応じた型付きのエラーを作る */
export function createApiError(status: number, code: ApiErrorCode, details: Readonly<Record<string, unknown>>): ApiError {
  if (code === "not_logged_in") {
    return new NotLoggedInError(status, details);
  }
  if (code === "csrf_invalid") {
    return new CsrfInvalidError(status, details);
  }
  return new ApiError(status, code, details);
}

export interface ApiRejectedInit {
  readonly status: number;
  readonly reason: RejectionReason;
  readonly resolution: Resolution;
  readonly retryAt: string | null;
  readonly fields: readonly string[] | null;
}

/** 受付の拒否（POST /api/broadcasts の {"rejected":{...}}。契約 4 章）。通常のエラー（ApiError）とは、別の型 */
export class ApiRejected extends ApiClientError {
  readonly status: number;
  readonly reason: RejectionReason;
  readonly resolution: Resolution;
  /** 再試行の目安時刻（ISO 8601、JST）。無ければ null */
  readonly retryAt: string | null;
  /** invalid_input のときの、不備のある項目名。無ければ null */
  readonly fields: readonly string[] | null;

  constructor(init: ApiRejectedInit) {
    super(`request rejected ${init.status} ${init.reason}`);
    this.name = "ApiRejected";
    this.status = init.status;
    this.reason = init.reason;
    this.resolution = init.resolution;
    this.retryAt = init.retryAt;
    this.fields = init.fields;
  }
}

/** 契約に無い応答（JSON でない・形が違う・未知の符号）。成功にも、既知のエラーにもしない */
export class UnexpectedResponse extends ApiClientError {
  /** HTTP ステータス（応答を得られなかった場合は null） */
  readonly status: number | null;
  /** 何が合わなかったか（位置・種類の符号だけ。応答の値を含めない） */
  readonly detail: string;

  constructor(status: number | null, detail: string) {
    super(status === null ? `unexpected response: ${detail}` : `unexpected response (status ${status}): ${detail}`);
    this.name = "UnexpectedResponse";
    this.status = status;
    this.detail = detail;
  }
}

/** 通信に失敗した（接続できない・途中で切れた）。原因は cause に持つ（メッセージには、URL・原因の文面を含めない） */
export class ApiNetworkError extends ApiClientError {
  constructor(cause: unknown) {
    super("network request failed", { cause });
    this.name = "ApiNetworkError";
  }
}

/** 待ち時間の上限を超えた */
export class ApiTimeoutError extends ApiClientError {
  readonly timeoutMs: number;

  constructor(timeoutMs: number) {
    super(`request timed out after ${timeoutMs} ms`);
    this.name = "ApiTimeoutError";
    this.timeoutMs = timeoutMs;
  }
}

/** 呼び出し側が、AbortSignal で中断した */
export class ApiAbortedError extends ApiClientError {
  constructor() {
    super("request aborted");
    this.name = "ApiAbortedError";
  }
}

/** CSRF トークンが無いまま、ログインが要る操作を呼んだ（先に getState を呼ぶ。実装の誤り）。要求は送っていない */
export class MissingCsrfTokenError extends ApiClientError {
  readonly operation: string;

  constructor(operation: string) {
    super(`CSRF token is not available for ${operation} (call getState first)`);
    this.name = "MissingCsrfTokenError";
    this.operation = operation;
  }
}
