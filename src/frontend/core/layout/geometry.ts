// 映像合成の幾何（requirements.md 11.4）の共通部品。画素の大きさは正の整数で、整数だけで厳密に丸める。

/** 長方形（画素。左上が原点）。 */
export interface Rect {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/**
 * 画素の大きさ（出力・入力の幅と高さ）として受け付ける最大の値（2^20）。
 * 幅 × 高さ、幅 × 1,000 などの積が 2^41 に収まり、安全整数の範囲で厳密に計算できる。
 */
export const MAX_DIMENSION = 1_048_576;

/** 画素の大きさ（正の整数で、MAX_DIMENSION 以下）であることを確かめる。そうでなければ RangeError。 */
export function assertDimension(value: number, name: string): void {
  if (!Number.isInteger(value) || value < 1 || value > MAX_DIMENSION) {
    throw new RangeError(`${name} must be an integer from 1 to ${MAX_DIMENSION}: ${String(value)}`);
  }
}

/**
 * round(numerator ÷ denominator)（四捨五入・0.5 は切り上げ）を、整数だけで厳密に求める。
 * numerator は 0 以上の安全整数、denominator は 1 以上の安全整数。浮動小数点の除算の切り捨てに頼らず、剰余で数える。
 */
export function roundDivide(numerator: number, denominator: number): number {
  const remainder = numerator % denominator;
  const quotient = (numerator - remainder) / denominator;
  return 2 * remainder >= denominator ? quotient + 1 : quotient;
}
