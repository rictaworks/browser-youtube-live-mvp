// 描画命令の計算（requirements.md 11.3・11.4。issue #27）。レイアウトと入力の大きさから、1 枚の完成フレームを描く命令の列を決める純粋な関数。
// 実際の描画（OffscreenCanvas の 2D コンテキスト）は、ワーカーの VideoCompositor が、この命令の列を実行して行う。
//
//   - 出力解像度は入力に依存せず、プロファイルの解像度に固定（呼び出し側が出力の大きさを渡す）
//   - 最初の命令は、出力の全体を単色で埋める（余白の色。前のフレームの描画が残らない）
//   - 主映像は縦横比を保って出力枠に内接させる（core の containRect）。ワイプは右下（core の wipeRect。幅 22%・外側の余白 2.5%・角の丸め 6%）で、主映像の上に描く
//   - 代替スレートは、文字を描かない。単色の背景と、簡素な図形（中央の角丸の枠と、円）だけ（利用者の文言を含めない）
//   - 時刻・乱数・環境を参照しない（入力が同じなら、結果は同じ）

import { LAYOUT_VALUES } from "@/core/contract";
import type { Layout } from "@/core/contract";
import { containRect, wipeRect } from "@/core/layout";
import type { Rect } from "@/core/layout";
import { assertDimension, roundDivide } from "@/core/layout/geometry";
import { COMPOSITION_LETTERBOX_COLOR, SLATE } from "./config";

/** 映像ソースの置き場所。画面共有（主映像）とカメラ（主映像またはワイプ）。 */
export type SourceSlot = "screen" | "camera";

/** 映像ソースのフレームの大きさ（表示される大きさ。画素）。 */
export interface SourceSize {
  readonly width: number;
  readonly height: number;
}

export type DrawCommand =
  | { readonly op: "fill_rect"; readonly color: string; readonly rect: Rect }
  | { readonly op: "fill_round_rect"; readonly color: string; readonly rect: Rect; readonly cornerRadius: number }
  | { readonly op: "fill_circle"; readonly color: string; readonly centerX: number; readonly centerY: number; readonly radius: number }
  | { readonly op: "draw_source"; readonly slot: SourceSlot; readonly rect: Rect }
  | { readonly op: "draw_source_rounded"; readonly slot: SourceSlot; readonly rect: Rect; readonly cornerRadius: number };

export interface FramePlanInput {
  readonly layout: Layout;
  readonly outputWidth: number;
  readonly outputHeight: number;
  /** 画面共有のフレームの大きさ。無ければ null */
  readonly screen: SourceSize | null;
  /** カメラのフレームの大きさ。無ければ null */
  readonly camera: SourceSize | null;
}

const PERMILLE = 1_000;

function freezeRect(rect: Rect): Rect {
  return Object.freeze({ x: rect.x, y: rect.y, width: rect.width, height: rect.height });
}

function requireSize(size: SourceSize | null, slot: SourceSlot, layout: Layout): SourceSize {
  if (size === null) {
    throw new RangeError(`layout ${layout} needs the ${slot} frame size, but it is missing`);
  }
  assertDimension(size.width, `${slot}.width`);
  assertDimension(size.height, `${slot}.height`);
  return size;
}

function fillLetterbox(outputWidth: number, outputHeight: number): DrawCommand {
  return Object.freeze({ op: "fill_rect", color: COMPOSITION_LETTERBOX_COLOR, rect: freezeRect({ x: 0, y: 0, width: outputWidth, height: outputHeight }) });
}

function drawMain(slot: SourceSlot, size: SourceSize, outputWidth: number, outputHeight: number): DrawCommand {
  return Object.freeze({ op: "draw_source", slot, rect: freezeRect(containRect(size.width, size.height, outputWidth, outputHeight)) });
}

function drawWipe(size: SourceSize, outputWidth: number, outputHeight: number): DrawCommand {
  const wipe = wipeRect(outputWidth, outputHeight, size.width / size.height);
  return Object.freeze({ op: "draw_source_rounded", slot: "camera", rect: freezeRect(wipe), cornerRadius: wipe.cornerRadius });
}

/** 代替スレート: 単色の背景・中央の角丸の枠・中央の円。文字を描かない。 */
function slatePlan(outputWidth: number, outputHeight: number): DrawCommand[] {
  const boxWidth = roundDivide(outputWidth * SLATE.frameWidthPermille, PERMILLE);
  // 枠は 16:9 で、幅は出力幅の 30%。極端に横長の出力で、高さに収まらないときは、高さで制限する
  const fitted = containRect(SLATE.frameAspectWidth, SLATE.frameAspectHeight, Math.max(1, boxWidth), outputHeight);
  const frame = freezeRect({
    x: Math.floor((outputWidth - fitted.width) / 2),
    y: Math.floor((outputHeight - fitted.height) / 2),
    width: fitted.width,
    height: fitted.height,
  });
  const markRadius = Math.max(1, Math.min(roundDivide(outputWidth * SLATE.markRadiusPermille, PERMILLE), Math.floor(Math.min(frame.width, frame.height) / 2)));
  return [
    Object.freeze({ op: "fill_rect", color: SLATE.backgroundColor, rect: freezeRect({ x: 0, y: 0, width: outputWidth, height: outputHeight }) }),
    Object.freeze({ op: "fill_round_rect", color: SLATE.frameColor, rect: frame, cornerRadius: roundDivide(frame.width * SLATE.frameCornerRadiusPermille, PERMILLE) }),
    Object.freeze({ op: "fill_circle", color: SLATE.markColor, centerX: outputWidth / 2, centerY: outputHeight / 2, radius: markRadius }),
  ];
}

/**
 * 1 枚の完成フレームを描く命令の列を返す。レイアウトが要するソースの大きさが無い・不正、出力の大きさが不正、未知のレイアウトは RangeError。
 * 結果は凍結している（実行側が書き換えない）。
 */
export function planFrame(input: FramePlanInput): readonly DrawCommand[] {
  const { layout, outputWidth, outputHeight } = input;
  assertDimension(outputWidth, "outputWidth");
  assertDimension(outputHeight, "outputHeight");
  if (!(LAYOUT_VALUES as readonly string[]).includes(layout)) {
    throw new RangeError(`unknown layout: ${String(layout)}`);
  }

  switch (layout) {
    case "screen_with_wipe": {
      const screen = requireSize(input.screen, "screen", layout);
      const camera = requireSize(input.camera, "camera", layout);
      return Object.freeze([fillLetterbox(outputWidth, outputHeight), drawMain("screen", screen, outputWidth, outputHeight), drawWipe(camera, outputWidth, outputHeight)]);
    }
    case "screen_only": {
      const screen = requireSize(input.screen, "screen", layout);
      return Object.freeze([fillLetterbox(outputWidth, outputHeight), drawMain("screen", screen, outputWidth, outputHeight)]);
    }
    case "camera_only": {
      const camera = requireSize(input.camera, "camera", layout);
      return Object.freeze([fillLetterbox(outputWidth, outputHeight), drawMain("camera", camera, outputWidth, outputHeight)]);
    }
    case "slate":
      return Object.freeze(slatePlan(outputWidth, outputHeight));
  }
}
