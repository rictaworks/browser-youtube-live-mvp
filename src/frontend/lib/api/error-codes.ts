// エラーの符号（契約 1.6 の表）。符号に無い値の応答は、UnexpectedResponse として扱う（contract-conformance.test.ts が、表との一致を保証する）。

export const API_ERROR_CODES = [
  "forbidden",
  "csrf_invalid",
  "not_logged_in",
  "not_found",
  "invalid_input",
  "unsupported_event",
  "bot_check_failed",
  "rate_limited",
  "broadcast_in_progress",
  "broadcast_ended",
  "not_resumable",
  "already_live",
  "not_connected",
  "unverifiable",
  "internal_error",
  "bad_gateway",
] as const;

export type ApiErrorCode = (typeof API_ERROR_CODES)[number];

export function isApiErrorCode(value: unknown): value is ApiErrorCode {
  return typeof value === "string" && (API_ERROR_CODES as readonly string[]).includes(value);
}
