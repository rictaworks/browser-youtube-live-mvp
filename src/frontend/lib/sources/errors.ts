// ソースの取得の型付きのエラー（requirements.md 11.2・issue #26）。
// 権限の拒否・選択の取り消し・デバイスが無い、は、エラーではなく、状態（denied・detached）で表す（SourceManager）。ここは、それ以外の失敗。
// メッセージは、符号・種別・元のエラーの名前だけ。元のエラーの文面（デバイス名・ラベルを含み得る）は、メッセージに入れない（cause に残す）。
// 利用者へ表示する文言は、画面が、符号から、文言カタログの文言を選ぶ（ここに文言を持たない）。

import { nameOf } from "./error-name";
import type { ManagedSourceKind } from "./types";

/**
 *   unsupported                   API が無い・使えない（画面共有 API が無い環境・NotSupportedError）
 *   invalid_state                 InvalidStateError。画面共有（getDisplayMedia）は、利用者のクリック等（一時的なアクティベーション）の直後に、
 *                                 最初の非同期呼び出しとして呼ばないと、この失敗になる
 *   not_readable                  デバイスを読み取れない（他のアプリが使用中・OS の権限・ハードウェアの不具合）
 *   aborted                       取得が中断された（AbortError）
 *   unexpected                    想定していない失敗（元のエラーの名前を errorName に残す）
 *   shared_audio_requires_screen  共有音声を単独で取得しようとした（共有音声は、画面共有の取得（attach("screen")）で得る）
 *   no_track                      取得に成功したが、期待したトラックが含まれていない
 *   disposed                      SourceManager が、すでに破棄されている
 */
export const SOURCE_ERROR_CODES = [
  "unsupported",
  "invalid_state",
  "not_readable",
  "aborted",
  "unexpected",
  "shared_audio_requires_screen",
  "no_track",
  "disposed",
] as const;
export type SourceErrorCode = (typeof SOURCE_ERROR_CODES)[number];

export class SourceError extends Error {
  readonly code: SourceErrorCode;
  readonly kind: ManagedSourceKind;
  /** 元のエラー（DOMException など）の名前。元のエラーが無い・名前を読めないときは null */
  readonly errorName: string | null;

  constructor(code: SourceErrorCode, kind: ManagedSourceKind, cause?: unknown) {
    const errorName = nameOf(cause);
    super(`source error: ${code} (${kind}${errorName === null ? "" : `, ${errorName}`})`, cause === undefined ? undefined : { cause });
    this.name = "SourceError";
    this.code = code;
    this.kind = kind;
    this.errorName = errorName;
  }
}

export function isSourceError(value: unknown): value is SourceError {
  return value instanceof SourceError;
}
