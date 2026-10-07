// ワイプ（requirements.md 11.4）。主映像の上に重ねる小窓映像を、出力枠の右下に置く。
//   - 幅 = 出力幅の 22%、外側の余白 = 出力幅の 2.5%（右・下とも）、角の丸め = ワイプ幅の 6%。絶対値を使わず、出力の大きさに対する比だけで決める
//   - 高さは、カメラの縦横比（幅 ÷ 高さ）で決める（ワイプの中で、カメラの映像を切り取らず・余白も作らない）
//   - 整数への丸めは四捨五入（0.5 は切り上げ）。割合は、千分率の整数（220・25・60）で持ち、整数だけで厳密に丸める
//   - はみ出さない：右・下は外側の余白を保って置く。縦長のカメラで高さが収まらないときは、上にも外側の余白を保つ高さまで縮め、
//     縦横比を保つために幅も縮める（幅は 22% を下回る）。角の丸めは、短い辺の半分を超えない

import { assertDimension, roundDivide } from "./geometry";
import type { Rect } from "./geometry";

const PERMILLE = 1_000;
const WIPE_WIDTH_PERMILLE = 220;
const WIPE_MARGIN_PERMILLE = 25;
const WIPE_CORNER_RADIUS_PERMILLE = 60;

/** ワイプの長方形。cornerRadius は角の丸めの半径（画素）。 */
export interface WipeRect extends Rect {
  readonly cornerRadius: number;
}

/**
 * 出力（outWidth × outHeight）の右下に置くワイプの長方形を返す。
 * cameraAspect はカメラの縦横比（幅 ÷ 高さ。正の有限な数）。
 * 引数が不正なとき、または出力が低すぎて外側の余白を取るとワイプの置き場が無いときは、RangeError。
 */
export function wipeRect(outWidth: number, outHeight: number, cameraAspect: number): WipeRect {
  assertDimension(outWidth, "outWidth");
  assertDimension(outHeight, "outHeight");
  if (!Number.isFinite(cameraAspect) || cameraAspect <= 0) {
    throw new RangeError(`cameraAspect must be a positive finite number: ${String(cameraAspect)}`);
  }

  const margin = roundDivide(outWidth * WIPE_MARGIN_PERMILLE, PERMILLE);
  const maxHeight = outHeight - 2 * margin;
  if (maxHeight < 1) {
    throw new RangeError(`output ${String(outWidth)}x${String(outHeight)} is too short to place a wipe inside its outer margin of ${String(margin)}`);
  }

  const ratioWidth = roundDivide(outWidth * WIPE_WIDTH_PERMILLE, PERMILLE);
  const ratioHeight = Math.max(1, Math.round(ratioWidth / cameraAspect));
  const limitedByHeight = ratioHeight > maxHeight;
  const height = limitedByHeight ? maxHeight : ratioHeight;
  const width = limitedByHeight ? Math.max(1, Math.round(height * cameraAspect)) : ratioWidth;

  const cornerRadius = Math.min(roundDivide(width * WIPE_CORNER_RADIUS_PERMILLE, PERMILLE), Math.floor(Math.min(width, height) / 2));
  return Object.freeze({
    x: outWidth - margin - width,
    y: outHeight - margin - height,
    width,
    height,
    cornerRadius,
  });
}
