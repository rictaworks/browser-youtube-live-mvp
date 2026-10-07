// バイト列の小さな道具（環境に依存しない部分だけ）。
//   - Uint8Array かの判定は、instanceof ではなく、型の印（Object.prototype.toString）で行う（Node の Buffer・別の実行環境で作られた配列も、
//     Uint8Array として扱う。instanceof は、実行環境をまたぐと偽になり得る）
//   - UTF-8 の符号化・復号は、標準の TextEncoder・TextDecoder を、呼び出しごとに作って使う（状態を持ち越さない）。
//     復号は厳密（不正なバイト列は失敗する。BOM は取り除かず、JSON の解釈で拒否される）

import { FrameError } from "./errors";

/** Uint8Array か（Node の Buffer も真）。 */
export function isUint8Array(value: unknown): value is Uint8Array {
  return Object.prototype.toString.call(value) === "[object Uint8Array]";
}

/** 文字列を UTF-8 のバイト列にする（本文長は、文字数ではなく、このバイト数）。 */
export function encodeUtf8(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

/** UTF-8 のバイト列を文字列にする。UTF-8 として不正なバイト列は、invalid_body（バイト列の中身を、エラーに含めない）。 */
export function decodeUtf8(bytes: Uint8Array): string {
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
  } catch {
    throw new FrameError("invalid_body", "body is not valid UTF-8");
  }
}
