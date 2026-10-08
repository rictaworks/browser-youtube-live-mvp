// 既定のタイマ（実行環境の setTimeout・clearTimeout）。クライアント（PipelineClient）の応答の期限と、起動の期限にだけ使う。
// メディアの時刻の採番には使わない（時刻は、音声の累積サンプル数から算出する。11.6）。テストは、疑似のタイマを注入する。
// 実行環境の大域の参照は、この 1 か所に集める（ほかのファイルは、注入された TimerApi を使う）。

import type { TimerApi } from "./PipelineClient";

export const defaultTimers: TimerApi = {
  setTimeout: (callback, delayMs) => globalThis.setTimeout(callback, delayMs),
  clearTimeout: (handle) => {
    globalThis.clearTimeout(handle as ReturnType<typeof globalThis.setTimeout>);
  },
};
