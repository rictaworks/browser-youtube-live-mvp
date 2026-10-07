// 音声の混合の設定値（requirements.md 11.5・11.6）。名前と数値は、ここへ集める（実装へ直書きしない）。
// 契約の値（サンプリング周波数・チャンネル数）は、core/contract の LIMITS から取る（実行時に src/contracts は読まない）。

import { LIMITS } from "@/core/contract";
import type { SourceKind } from "@/core/contract";

/** AudioWorklet のプロセッサの登録名。public/worklets/stream-mixer-processor.js の registerProcessor と同じ（テストが一致を保証する）。 */
export const MIXER_PROCESSOR_NAME = "stream-mixer";

/**
 * Worklet のモジュールの URL。Next.js は public/ の下のファイルを、ルート（/）から配信する。
 * Worklet のコードを TypeScript からバンドルせず、プレーンな JavaScript として配る理由は、Worklet のファイルの冒頭に書いてある。
 */
export const MIXER_WORKLET_MODULE_URL = "/worklets/stream-mixer-processor.js";

/** 混合のサンプリング周波数（44.1 kHz。11.5）。AudioContext は、この値で作る。 */
export const MIXER_SAMPLE_RATE_HZ: number = LIMITS.audio.sample_rate_hz;

/** 混合後のチャンネル数（2。11.5）。 */
export const MIXER_CHANNEL_COUNT: number = LIMITS.audio.channels;

/**
 * 混合の入力の種別。並びが Worklet の入力の番号（0 = マイク・1 = 共有音声）になる。
 * マイクを基準の音量とし、共有音声を副の音量とする（11.2・11.5）。
 */
export const MIXER_INPUT_KINDS = ["microphone", "shared_audio"] as const satisfies readonly SourceKind[];
export type MixerInputKind = (typeof MIXER_INPUT_KINDS)[number];

/** 入力の種別が Worklet の何番目の入力か。 */
export function mixerInputIndex(kind: MixerInputKind): number {
  const index = MIXER_INPUT_KINDS.indexOf(kind);
  if (index < 0) {
    throw new RangeError(`unknown mixer input kind (expected one of ${MIXER_INPUT_KINDS.join(", ")}): ${String(kind)}`);
  }
  return index;
}

/** 入力の種別として正しいか（型ガード）。 */
export function isMixerInputKind(value: unknown): value is MixerInputKind {
  return typeof value === "string" && (MIXER_INPUT_KINDS as readonly string[]).includes(value);
}

/** 既定の音量。マイクが 1.0（基準）、共有音声はマイクの 0.6 倍（11.5）。 */
export const DEFAULT_MIXER_GAINS: Readonly<Record<MixerInputKind, number>> = Object.freeze({
  microphone: 1,
  shared_audio: 0.6,
});

/** 音量（倍率）の上限。これを超える値は、設定できない（上限を超えた信号は、リミッタが抑える）。 */
export const MIXER_GAIN_MAX = 4;

/** 混合後の信号の上限（絶対値。フルスケール）。これを超えないよう、リミッタが抑える（11.5）。 */
export const MIXER_LIMITER_CEILING = 1;

/** リミッタの復帰の時定数（秒）。抑えたあと、この時定数で、元の音量へ戻る。 */
export const MIXER_LIMITER_RELEASE_SECONDS = 0.1;

/** 音量の変更を、この時定数（秒）でなだらかに反映する（急な変更による、ぶつ切りの雑音を避ける）。 */
export const MIXER_GAIN_SMOOTHING_SECONDS = 0.01;

/** start() が、AudioContext の実行状態と Worklet の準備を待つ上限（ミリ秒）。超えたら、typed なエラーで失敗する。 */
export const MIXER_START_TIMEOUT_MS = 5_000;
