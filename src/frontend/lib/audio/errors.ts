// 音声の混合の型付きのエラー（issue #26）。メッセージは、符号と、元のエラーの名前だけ（元のエラーの文面は、デバイス名などを含み得るので、
// メッセージに入れない。cause に残す）。利用者へ表示する文言は、画面が、符号から、文言カタログの文言を選ぶ（ここに文言を持たない）。

import { nameOf } from "@/lib/sources/error-name";

/**
 *   invalid_state            状態に合わない呼び出し（開始済みの混合器の start など）
 *   unsupported              AudioContext・AudioWorklet・MediaStream が無い環境
 *   sample_rate_unsupported  AudioContext が、要求した 44,100 Hz で作られなかった（11.5 は 44.1 kHz。別の周波数のまま続けない）
 *   worklet_load_failed      Worklet のモジュールを読み込めない
 *   worklet_create_failed    Worklet のノードを作れない
 *   context_not_running      AudioContext が、期限内に実行状態にならない（開始の操作の後に resume しても、自動再生の制限などで止まっている）
 *   aborted                  開始の途中で、stop が呼ばれた
 *   invalid_track            混合に加えられない、トラック（音声でない・すでに終了している）
 *   unexpected               想定していない失敗
 */
export const AUDIO_MIXER_ERROR_CODES = [
  "invalid_state",
  "unsupported",
  "sample_rate_unsupported",
  "worklet_load_failed",
  "worklet_create_failed",
  "context_not_running",
  "aborted",
  "invalid_track",
  "unexpected",
] as const;
export type AudioMixerErrorCode = (typeof AUDIO_MIXER_ERROR_CODES)[number];

export class AudioMixerError extends Error {
  readonly code: AudioMixerErrorCode;

  constructor(code: AudioMixerErrorCode, cause?: unknown) {
    const causeName = nameOf(cause);
    super(`audio mixer error: ${code}${causeName === null ? "" : ` (${causeName})`}`, cause === undefined ? undefined : { cause });
    this.name = "AudioMixerError";
    this.code = code;
  }
}

/**
 * メディアクロックの基準（音声の累積サンプル数）が、食い違った。ブロックの先頭の累積サンプル数が、クロックの累積と一致しない
 * （ブロックの欠落・重複・順序の入れ替わり。メッセージポートでは起きないはずなので、起きたら、継続できない障害として扱う）。
 */
export class AudioContinuityError extends Error {
  readonly expectedSample: number;
  readonly actualSample: number;

  constructor(expectedSample: number, actualSample: number) {
    super(`audio continuity error: expected sample ${expectedSample}, got ${actualSample}`);
    this.name = "AudioContinuityError";
    this.expectedSample = expectedSample;
    this.actualSample = actualSample;
  }
}

export const WORKLET_PROTOCOL_ERROR_REASONS = [
  "not_an_object",
  "unknown_type",
  "invalid_first_sample",
  "invalid_frames",
  "invalid_pcm",
  "invalid_reason",
  "invalid_command",
] as const;
export type WorkletProtocolErrorReason = (typeof WORKLET_PROTOCOL_ERROR_REASONS)[number];

/** Worklet から届いたメッセージが、決められた形でない（受け取った値は、メッセージに入れない）。 */
export class WorkletProtocolError extends Error {
  readonly reason: WorkletProtocolErrorReason;

  constructor(reason: WorkletProtocolErrorReason) {
    super(`worklet protocol error: ${reason}`);
    this.name = "WorkletProtocolError";
    this.reason = reason;
  }
}
