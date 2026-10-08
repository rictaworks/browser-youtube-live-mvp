// PreviewSurface（requirements.md 16.2・11.4。issue #27）。スタジオ画面のプレビュー用の canvas へ、合成した 1 枚を写す。
//
//   - プレビューは、実際に送出するものと同一の構図であること。そのため、別の合成をせず、合成した 1 枚のキャンバスを、そのまま（拡縮せず、1:1 で）写す
//     （符号化へ渡すフレームと、プレビューが、同じキャンバスの同じ画素になる）
//   - 方式: メインスレッドでプレビュー用の <canvas> を transferControlToOffscreen し、OffscreenCanvas をワーカーへ渡して、ワーカーで描く。
//     メインスレッドは描画に関わらない（メインスレッドが忙しくても、非表示でも、配信を妨げず、メッセージが溜まらない）。
//     フレームを ImageBitmap で返す方式は、メインスレッドが忙しい間にビットマップが溜まる（1 枚が 720p で約 3.7 MB）ので採らない。
//     実測（test/ の probe）で確かめた根拠は、test/pr<番号>/README.md
//   - キャンバスの大きさ（width・height）を設定するとキャンバスが消えるので、合成の大きさと違うときだけ設定する
//
// 時刻・環境を参照しない。

import { PipelineError } from "@/lib/pipeline/errors";

export class PreviewSurface {
  private canvas: OffscreenCanvas | null = null;
  private context: OffscreenCanvasRenderingContext2D | null = null;

  /** プレビュー用のキャンバスが、渡されている。 */
  get isAttached(): boolean {
    return this.context !== null;
  }

  /**
   * プレビュー用のキャンバスを受け取る。すでに受け取っていれば、差し替える。
   * 2D コンテキストを得られなければ preview_unavailable（メインスレッドで getContext 済みのキャンバスは、転送後に得られない）。
   */
  attach(canvas: OffscreenCanvas): void {
    let context: OffscreenCanvasRenderingContext2D | null;
    try {
      context = canvas.getContext("2d", { alpha: false });
    } catch (error) {
      throw new PipelineError("preview_unavailable", error);
    }
    if (context === null) {
      throw new PipelineError("preview_unavailable");
    }
    this.canvas = canvas;
    this.context = context;
  }

  /** プレビュー用のキャンバスを手放す。何度呼んでもよい。 */
  detach(): void {
    this.canvas = null;
    this.context = null;
  }

  /**
   * 合成した 1 枚を、プレビューへ写す（1:1）。プレビューが無ければ何もせず偽を返す。描画に失敗したら preview_unavailable
   * （配信を続けるかは、呼び出し側が決める。プレビューの失敗で、符号化を止めない）。
   */
  present(composite: OffscreenCanvas): boolean {
    const canvas = this.canvas;
    const context = this.context;
    if (canvas === null || context === null) {
      return false;
    }
    try {
      if (canvas.width !== composite.width) {
        canvas.width = composite.width;
      }
      if (canvas.height !== composite.height) {
        canvas.height = composite.height;
      }
      context.drawImage(composite, 0, 0);
      return true;
    } catch (error) {
      throw new PipelineError("preview_unavailable", error);
    }
  }
}
