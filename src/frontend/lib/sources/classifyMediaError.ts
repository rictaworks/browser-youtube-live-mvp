// getUserMedia・getDisplayMedia の失敗を、状態で表すもの（拒否・取り消し・デバイスが無い）と、型付きのエラーに分ける。
// 判断の根拠は、WORK/factcheck/20261007_external-facts.md の項目 13（W3C Screen Capture・MDN）。
//   - getUserMedia の NotAllowedError は、利用者の拒否（または Permissions Policy による不許可）。カメラ・マイクは、拒否（denied）
//   - getDisplayMedia の NotAllowedError は、拒否と選択の取り消し（選択画面を閉じた）の両方。ブラウザは、この 2 つを区別できない。
//     どちらかを推測して拒否と決めつけず、画面共有は、未取得（detached）へ戻す。権限の拒否として扱うのは、getUserMedia だけ
//   - NotFoundError は、デバイス（共有できる画面）が無い
//   - OverconstrainedError は、指定したデバイスの識別子（exact）が無いとき（constraint が deviceId）だけ、デバイスが無い。それ以外は想定外
//   - InvalidStateError・NotSupportedError・NotReadableError・AbortError などは、型付きのエラー

import { nameOf } from "./error-name";
import type { SourceErrorCode } from "./errors";
import type { ManagedSourceKind } from "./types";

export type MediaFailure =
  /** カメラ・マイクの権限の拒否（denied） */
  | { readonly outcome: "denied" }
  /** 画面共有の選択の取り消し（拒否と区別できないため、未取得へ戻す） */
  | { readonly outcome: "cancelled" }
  /** デバイスが無い（未取得 + 理由 device_not_found） */
  | { readonly outcome: "not_found" }
  /** 型付きのエラー（SourceError にして、呼び出し元へ投げる） */
  | { readonly outcome: "error"; readonly code: SourceErrorCode; readonly errorName: string };

const UNKNOWN_ERROR_NAME = "unknown";

/** 名前を読めない値は、"unknown"（分類を推測しない）。 */
function errorNameOf(error: unknown): string {
  return nameOf(error) ?? UNKNOWN_ERROR_NAME;
}

/** OverconstrainedError が、指定したデバイスの識別子（exact）に合うデバイスが無い、という意味か。 */
function isDeviceIdConstraint(error: unknown): boolean {
  return typeof error === "object" && error !== null && (error as { constraint?: unknown }).constraint === "deviceId";
}

function typedError(code: SourceErrorCode, errorName: string): MediaFailure {
  return { outcome: "error", code, errorName };
}

/** 型付きのエラーにする失敗の名前と符号（Map: 名前が Object.prototype の物（constructor など）に当たらないように）。 */
const TYPED_ERROR_CODES: ReadonlyMap<string, SourceErrorCode> = new Map<string, SourceErrorCode>([
  ["InvalidStateError", "invalid_state"],
  ["NotSupportedError", "unsupported"],
  ["NotReadableError", "not_readable"],
  ["AbortError", "aborted"],
]);

/** 取得の失敗を分類する。kind は、失敗した取得の種別（画面共有だけ、NotAllowedError の意味が違う）。 */
export function classifyMediaError(kind: ManagedSourceKind, error: unknown): MediaFailure {
  const name = errorNameOf(error);
  if (name === "NotAllowedError") {
    return kind === "screen" ? { outcome: "cancelled" } : { outcome: "denied" };
  }
  if (name === "NotFoundError" || (name === "OverconstrainedError" && isDeviceIdConstraint(error))) {
    return { outcome: "not_found" };
  }
  return typedError(TYPED_ERROR_CODES.get(name) ?? "unexpected", name);
}
