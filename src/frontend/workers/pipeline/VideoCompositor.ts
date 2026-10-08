// VideoCompositor（requirements.md 11.3・11.4。issue #27）。OffscreenCanvas の 2D コンテキストで、映像ソースを 1 枚の完成フレームに合成する。
// ワーカーの上で動く（画面の描画周期に依存しない。タブが非表示・最小化されても続く）。
//
//   - 出力解像度は、入力に依存せず、プロファイルの解像度に固定する（配信の開始時に確定。配信中に変更しない）
//   - レイアウトは、有効な映像ソース（フレームを持つもの）の組から、resolveLayout（core）で一意に決まる
//   - 何をどこへ描くかは、純粋な関数 planFrame（lib/pipeline/drawPlan.ts）が決める。ここは、その命令を 2D コンテキストで実行するだけ
//   - compose は、背景の塗りから最後の図形まで、同期的に 1 回で描き切る（途中で他の処理が割り込まない）。成功したときだけ、完成したフレームとして
//     確定し、snapshot で符号化用の VideoFrame にできる。失敗したら（描きかけ）、snapshot できない（描きかけを符号化しない）
//   - 入力のフレームは、閉じない・保持しない（所有と解放は FrameStore）。描画に使うだけ
//   - 代替スレートは、文字を描かない（fillText を使わない）
//
// 時刻・環境を参照しない。VideoFrame のコンストラクタは、注入される（ワーカーの大域のものを、環境から渡す）。

import { LIMITS, isProfile } from "@/core/contract";
import type { Layout, Profile } from "@/core/contract";
import { resolveLayout } from "@/core/layout";
import { planFrame } from "@/lib/pipeline/drawPlan";
import type { DrawCommand, SourceSize, SourceSlot } from "@/lib/pipeline/drawPlan";
import { PipelineError } from "@/lib/pipeline/errors";

export interface VideoCompositorOptions {
  /** 合成先のキャンバス。大きさは、プロファイルの解像度に設定される */
  readonly canvas: OffscreenCanvas;
  /** 配信の開始時に確定したプロファイル（プレビューだけの間は、プレビュー用のプロファイル） */
  readonly profile: Profile;
  /** new VideoFrame(canvas, { timestamp }) のコンストラクタ（注入） */
  readonly VideoFrame: typeof VideoFrame;
}

/** 合成の入力。映像ソースごとの、最新のフレーム。無ければ null。 */
export interface CompositionSources {
  readonly screen: VideoFrame | null;
  readonly camera: VideoFrame | null;
}

export interface CompositionResult {
  readonly layout: Layout;
}

function sizeOf(frame: VideoFrame | null): SourceSize | null {
  return frame === null ? null : { width: frame.displayWidth, height: frame.displayHeight };
}

export class VideoCompositor {
  readonly profile: Profile;
  readonly width: number;
  readonly height: number;
  /** 合成先のキャンバス。プレビューは、この同じキャンバスを写す（符号化へ渡すものと、同じ合成の結果） */
  readonly canvas: OffscreenCanvas;

  private readonly context: OffscreenCanvasRenderingContext2D;
  private readonly VideoFrameConstructor: typeof VideoFrame;
  /** 直近の compose が、最後まで描き切った */
  private composed = false;

  constructor(options: VideoCompositorOptions) {
    if (!isProfile(options.profile)) {
      throw new RangeError(`unknown profile: ${String(options.profile)}`);
    }
    this.profile = options.profile;
    this.width = LIMITS.profiles[options.profile].width;
    this.height = LIMITS.profiles[options.profile].height;
    this.canvas = options.canvas;
    this.VideoFrameConstructor = options.VideoFrame;
    this.canvas.width = this.width;
    this.canvas.height = this.height;
    // 余白を単色で塗るので、透過は要らない（不透明なキャンバスのほうが、合成も符号化への受け渡しも軽い）
    const context = this.canvas.getContext("2d", { alpha: false });
    if (context === null) {
      throw new PipelineError("compose_failed");
    }
    this.context = context;
  }

  /**
   * 1 枚の完成フレームを描く。レイアウトは、フレームを持つソースの組から決まる。背景から描き直す（前のフレームの描画が残らない）。
   * 失敗（描画の例外・閉じられたフレーム・寸法の不正）は compose_failed。そのフレームは確定せず、snapshot できない。
   */
  compose(sources: CompositionSources): CompositionResult {
    this.composed = false;
    try {
      const layout = resolveLayout({ screen: sources.screen === null ? "detached" : "active", camera: sources.camera === null ? "detached" : "active" });
      const plan = planFrame({ layout, outputWidth: this.width, outputHeight: this.height, screen: sizeOf(sources.screen), camera: sizeOf(sources.camera) });
      for (const command of plan) {
        this.execute(command, sources);
      }
      this.composed = true;
      return { layout };
    } catch (error) {
      throw error instanceof PipelineError ? error : new PipelineError("compose_failed", error);
    }
  }

  /**
   * 直近に確定した（最後まで描き切った）フレームを、符号化へ渡す VideoFrame にする。時刻（マイクロ秒）は、呼び出し側が、メディアクロックから算出して渡す。
   * 合成の前・失敗のあとは invalid_state（描きかけを符号化しない）。時刻が 0 以上の安全整数でなければ RangeError。
   * 返した VideoFrame は、呼び出し側（エンコーダへ渡す側）が close する。
   */
  snapshot(timestampUs: number): VideoFrame {
    if (!Number.isSafeInteger(timestampUs) || timestampUs < 0) {
      throw new RangeError(`timestampUs must be a non-negative safe integer: ${String(timestampUs)}`);
    }
    if (!this.composed) {
      throw new PipelineError("invalid_state");
    }
    try {
      return new this.VideoFrameConstructor(this.canvas, { timestamp: timestampUs });
    } catch (error) {
      throw new PipelineError("compose_failed", error);
    }
  }

  /** 描くフレームを、入力から取り出す（入力は保持しない）。計画が要するソースが無ければ、計画と入力の食い違いなので compose_failed。 */
  private frameFor(sources: CompositionSources, slot: SourceSlot): VideoFrame {
    const frame = sources[slot];
    if (frame === null) {
      throw new PipelineError("compose_failed");
    }
    return frame;
  }

  private execute(command: DrawCommand, sources: CompositionSources): void {
    const context = this.context;
    switch (command.op) {
      case "fill_rect": {
        context.fillStyle = command.color;
        context.fillRect(command.rect.x, command.rect.y, command.rect.width, command.rect.height);
        return;
      }
      case "fill_round_rect": {
        context.fillStyle = command.color;
        context.beginPath();
        context.roundRect(command.rect.x, command.rect.y, command.rect.width, command.rect.height, command.cornerRadius);
        context.fill();
        return;
      }
      case "fill_circle": {
        context.fillStyle = command.color;
        context.beginPath();
        context.arc(command.centerX, command.centerY, command.radius, 0, Math.PI * 2);
        context.fill();
        return;
      }
      case "draw_source": {
        context.drawImage(this.frameFor(sources, command.slot), command.rect.x, command.rect.y, command.rect.width, command.rect.height);
        return;
      }
      case "draw_source_rounded": {
        // 角を丸くクリップして描く。クリップは、描画のあとに必ず戻す（失敗しても残さない）
        context.save();
        try {
          context.beginPath();
          context.roundRect(command.rect.x, command.rect.y, command.rect.width, command.rect.height, command.cornerRadius);
          context.clip();
          context.drawImage(this.frameFor(sources, command.slot), command.rect.x, command.rect.y, command.rect.width, command.rect.height);
        } finally {
          context.restore();
        }
        return;
      }
    }
  }
}
