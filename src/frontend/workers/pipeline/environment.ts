// 配信パイプラインのワーカーの実行環境（issue #27）。ホスト（PipelineHost）が使う、ワーカーの大域のもの（WebCodecs・OffscreenCanvas・タイマ）を、
// 注入できる形にまとめる。テストは、疑似のものを渡す。実際のワーカーは、createWorkerEnvironment(self) で作る。
//
// 必要な機能が無い実行環境は、推測して続けず、environment_unsupported で失敗する（能力検出（#24）を通った環境なら、起きない）。
// タイマは、プレビューの描画（PreviewTicker）と、応答の期限（priming_timeout）にだけ使う。時刻の採番には使わない（11.6）。

import { PipelineError } from "@/lib/pipeline/errors";

/** タイマ。ハンドルの型は不透明（ワーカーでは数）。 */
export interface Scheduler {
  setInterval(callback: () => void, intervalMs: number): unknown;
  clearInterval(handle: unknown): void;
  setTimeout(callback: () => void, delayMs: number): unknown;
  clearTimeout(handle: unknown): void;
}

export interface PipelineEnvironment {
  readonly VideoEncoder: typeof VideoEncoder;
  readonly AudioEncoder: typeof AudioEncoder;
  readonly VideoFrame: typeof VideoFrame;
  readonly AudioData: typeof AudioData;
  /** 合成用のキャンバスを作る（ワーカーでは new OffscreenCanvas(width, height)） */
  createCanvas(width: number, height: number): OffscreenCanvas;
  readonly scheduler: Scheduler;
}

/** ワーカーの大域（self）のうち、使うもの。どれも、無いことがある（その機能が無い実行環境）。 */
export interface WorkerGlobals {
  readonly VideoEncoder?: unknown;
  readonly AudioEncoder?: unknown;
  readonly VideoFrame?: unknown;
  readonly AudioData?: unknown;
  readonly OffscreenCanvas?: unknown;
  readonly setInterval?: unknown;
  readonly clearInterval?: unknown;
  readonly setTimeout?: unknown;
  readonly clearTimeout?: unknown;
}

function requireFunction<T>(value: unknown): T {
  if (typeof value !== "function") {
    throw new PipelineError("environment_unsupported");
  }
  return value as T;
}

/** ワーカーの大域から、実行環境を作る。必要な機能が 1 つでも無ければ environment_unsupported。 */
export function createWorkerEnvironment(scope: WorkerGlobals): PipelineEnvironment {
  const OffscreenCanvasConstructor = requireFunction<typeof OffscreenCanvas>(scope.OffscreenCanvas);
  const setIntervalFunction = requireFunction<(callback: () => void, intervalMs: number) => unknown>(scope.setInterval);
  const clearIntervalFunction = requireFunction<(handle: unknown) => void>(scope.clearInterval);
  const setTimeoutFunction = requireFunction<(callback: () => void, delayMs: number) => unknown>(scope.setTimeout);
  const clearTimeoutFunction = requireFunction<(handle: unknown) => void>(scope.clearTimeout);
  return {
    VideoEncoder: requireFunction<typeof VideoEncoder>(scope.VideoEncoder),
    AudioEncoder: requireFunction<typeof AudioEncoder>(scope.AudioEncoder),
    VideoFrame: requireFunction<typeof VideoFrame>(scope.VideoFrame),
    AudioData: requireFunction<typeof AudioData>(scope.AudioData),
    createCanvas: (width, height) => new OffscreenCanvasConstructor(width, height),
    // ワーカーの大域の関数は、this が大域でないと呼べない環境がある。呼び出しごとに、scope を this にして呼ぶ
    scheduler: {
      setInterval: (callback, intervalMs) => Reflect.apply(setIntervalFunction, scope, [callback, intervalMs]),
      clearInterval: (handle) => {
        Reflect.apply(clearIntervalFunction, scope, [handle]);
      },
      setTimeout: (callback, delayMs) => Reflect.apply(setTimeoutFunction, scope, [callback, delayMs]),
      clearTimeout: (handle) => {
        Reflect.apply(clearTimeoutFunction, scope, [handle]);
      },
    },
  };
}
