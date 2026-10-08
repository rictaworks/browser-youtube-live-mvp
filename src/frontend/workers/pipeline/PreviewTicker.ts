// PreviewTicker（requirements.md 11.6・16.2。issue #27）。配信前（プレビューだけの間）の、ワーカーのタイマによる 30 fps の駆動。
//
//   重要な区別: このタイマは、プレビューの描画にだけ使う。配信の送出（合成・エンコード・時刻の採番）には、使わない。
//   配信中は、音声の処理周期（累積サンプル数）から MediaClock が決めるフレーム番号ごとに合成する（AudioClockDriver）。
//   配信前は、音声のクロックが無いので、ここだけ、ワーカーのタイマで駆動する。実時計で時刻を採番しない
//   （このタイマは、符号化へ渡すフレームの時刻に関わらない。プレビューは符号化しない）。
//   タイマは、ワーカーの中に置く（メインスレッドのタイマは、タブが非表示のとき間引かれる。画面の描画周期 requestAnimationFrame にも依存しない）。
//
//   コールバックの例外は、タイマの外へ漏らさず（ワーカーの未処理の例外は、メインスレッドで「ワーカーの異常終了」に見える）、onError へ渡す。

import { PREVIEW_INTERVAL_MS } from "@/lib/pipeline/config";

/** タイマ（注入。ワーカーの setInterval・clearInterval）。 */
export interface IntervalScheduler {
  setInterval(callback: () => void, intervalMs: number): unknown;
  clearInterval(handle: unknown): void;
}

export class PreviewTicker {
  private readonly scheduler: IntervalScheduler;
  private readonly onError: (error: unknown) => void;
  private readonly intervalMs: number;
  private handle: unknown = null;
  private callback: (() => void) | null = null;

  constructor(scheduler: IntervalScheduler, onError: (error: unknown) => void, intervalMs: number = PREVIEW_INTERVAL_MS) {
    this.scheduler = scheduler;
    this.onError = onError;
    this.intervalMs = intervalMs;
  }

  get running(): boolean {
    return this.callback !== null;
  }

  /** プレビューの描画を始める。すでに動いていれば、タイマはそのままで、コールバックだけを差し替える。 */
  start(callback: () => void): void {
    this.callback = callback;
    if (this.handle !== null) {
      return;
    }
    this.handle = this.scheduler.setInterval(() => this.tick(), this.intervalMs);
  }

  /** 止める。何度呼んでもよい。 */
  stop(): void {
    this.callback = null;
    if (this.handle !== null) {
      this.scheduler.clearInterval(this.handle);
      this.handle = null;
    }
  }

  private tick(): void {
    const callback = this.callback;
    if (callback === null) {
      return;
    }
    try {
      callback();
    } catch (error) {
      this.onError(error);
    }
  }
}
