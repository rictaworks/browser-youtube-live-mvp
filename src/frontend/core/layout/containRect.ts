// 主映像の内接（requirements.md 11.4）。主映像は、縦横比を保ったまま出力枠に内接させる。余白は、呼び出し側が単色で埋める。
//
// 規則（すべて整数。浮動小数点の誤差が出ない）:
//   - 拡大も縮小もする（入力が出力より小さくても、出力に内接する大きさまで拡大する）
//   - 幅で制限されるか高さで制限されるかは、交差乗算（入力の幅 × 出力の高さ と 入力の高さ × 出力の幅）で決める
//   - もう一方の辺は、四捨五入（0.5 は切り上げ）で整数にする。極端な縦横比でも、どちらの辺も 1 画素以上を保つ
//   - 余白が奇数なら、左・上の余白を切り捨て、右・下の余白を 1 画素大きくする

import { assertDimension, roundDivide } from "./geometry";
import type { Rect } from "./geometry";

/**
 * 入力（srcWidth × srcHeight）を、出力（outWidth × outHeight）の中央に、縦横比を保って内接させた長方形を返す。
 * 引数は 1 以上 MAX_DIMENSION 以下の整数。そうでなければ（0・負・小数・NaN・無限大・大きすぎる値）RangeError。
 */
export function containRect(srcWidth: number, srcHeight: number, outWidth: number, outHeight: number): Rect {
  assertDimension(srcWidth, "srcWidth");
  assertDimension(srcHeight, "srcHeight");
  assertDimension(outWidth, "outWidth");
  assertDimension(outHeight, "outHeight");

  // 入力の方が出力より横長（または同じ縦横比）なら、幅で制限される
  const limitedByWidth = srcWidth * outHeight >= srcHeight * outWidth;
  const fittedWidth = limitedByWidth ? outWidth : roundDivide(srcWidth * outHeight, srcHeight);
  const fittedHeight = limitedByWidth ? roundDivide(srcHeight * outWidth, srcWidth) : outHeight;

  const width = Math.min(Math.max(fittedWidth, 1), outWidth);
  const height = Math.min(Math.max(fittedHeight, 1), outHeight);
  return Object.freeze({
    x: Math.floor((outWidth - width) / 2),
    y: Math.floor((outHeight - height) / 2),
    width,
    height,
  });
}
