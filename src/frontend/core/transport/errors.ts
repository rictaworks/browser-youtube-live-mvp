// フレームの符号化・復号の失敗（型付きのエラー。黙って捨てない）。
//
// 先頭の 7 種は、ws-protocol.md の 4 章（検証の順）の符号で、中継（src/relay/core/frame）の ErrorCode と同じ名前・同じ順。
// 続く 2 種は、ブラウザ側で足す：
//   invalid_body     本文（JSON）の不備（UTF-8 でない・JSON でない・必須の項目が無い・値が不正）。受信では、そのメッセージを破棄する（4.1）
//   invalid_message  送ろうとする内容の不備（未知でない種別でも、時刻・本文の型・本文の値が不正）。呼び出しの誤り
// 詳細（detail）は、長さ・符号・項目の名前だけで、本文の中身（接続チケットなど）を含めない。

export const FRAME_ERROR_CODES = Object.freeze([
  "truncated_header",
  "invalid_magic",
  "unsupported_version",
  "unknown_type",
  "wrong_direction",
  "too_large",
  "length_mismatch",
  "invalid_body",
  "invalid_message",
] as const);

export type FrameErrorCode = (typeof FRAME_ERROR_CODES)[number];

export class FrameError extends Error {
  readonly code: FrameErrorCode;
  readonly detail: string;

  constructor(code: FrameErrorCode, detail: string) {
    super(`frame: ${code}: ${detail}`);
    this.name = "FrameError";
    this.code = code;
    this.detail = detail;
  }
}

/** FrameError か（符号で分けるときに使う）。 */
export function isFrameError(value: unknown): value is FrameError {
  return value instanceof FrameError;
}
