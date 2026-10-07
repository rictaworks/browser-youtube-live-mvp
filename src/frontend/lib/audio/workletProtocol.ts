// Worklet（public/worklets/stream-mixer-processor.js）とのメッセージの形。Worklet のファイルの冒頭に、同じ定義がある。
//
// コマンド（メインスレッド -> Worklet。node.port.postMessage）
//   { type: "gain", index, value }   入力 index の目標の音量を変える
//   { type: "start" }                ブロックの送信を始める（累積サンプル数は 0 から）。転送された MessagePort があれば、そこへ送る
// ブロック（Worklet -> 送り先）
//   { type: "block", firstSample, frames, pcm }   処理周期ごと。pcm は、インターリーブ（L R L R ...）の Float32Array
// 拒否（Worklet -> node.port）
//   { type: "rejected", command, reason }         不正なコマンド（例外にせず、通知して、処理を続ける）

import { MIXER_CHANNEL_COUNT } from "./config";
import { WorkletProtocolError } from "./errors";
import type { MixerParameters } from "./MixerCore";
import { assertGain } from "./MixerCore";

/** Worklet の作成時の設定（AudioWorkletNode の processorOptions）。パラメータと、入力ごとの初期の音量。 */
export interface MixerProcessorOptions extends MixerParameters {
  readonly gains: readonly number[];
}

/** 設定を作る。音量は、検査して、コピーする。不正な音量・空の配列は RangeError。 */
export function createProcessorOptions(parameters: MixerParameters, gains: readonly number[]): MixerProcessorOptions {
  if (gains.length === 0) {
    throw new RangeError("a mixer needs at least one input");
  }
  for (const gain of gains) {
    assertGain(gain, parameters.gainMax);
  }
  return { ...parameters, gains: [...gains] };
}

export type WorkletCommand = { readonly type: "gain"; readonly index: number; readonly value: number } | { readonly type: "start" };

/**
 * 混合した音声の 1 ブロック（音声の処理周期 1 回分）。pcm は、受け取った側のもの（コピーしていない）。
 * エンコーダ（#27）へは、AudioData({format: "f32", sampleRate: 44100, numberOfChannels: 2, numberOfFrames: frames, timestamp: MediaClock.audioTime(firstSample), data: pcm})
 * として渡せる（f32 はインターリーブ。時刻は、累積サンプル数から導く）。
 */
export interface MixedAudioBlock {
  /** このブロックの先頭までの累積サンプル数（このブロックを含まない）。時刻は MediaClock.audioTime(firstSample) */
  readonly firstSample: number;
  /** サンプル数（チャンネルあたり。通常は 128） */
  readonly frames: number;
  /** インターリーブ（L R L R ...）の PCM。長さ = frames × チャンネル数 */
  readonly pcm: Float32Array;
}

export interface WorkletBlockMessage extends MixedAudioBlock {
  readonly type: "block";
}

export const WORKLET_REJECT_REASONS = ["malformed", "unknown_command", "invalid_index", "invalid_value", "already_started"] as const;
export type WorkletRejectReason = (typeof WORKLET_REJECT_REASONS)[number];

export interface WorkletRejectedMessage {
  readonly type: "rejected";
  readonly command: string | null;
  readonly reason: WorkletRejectReason;
}

export type WorkletMessage = WorkletBlockMessage | WorkletRejectedMessage;

/**
 * Float32Array か。instanceof は、別の実行領域（realm）で作られた配列（疑似の Worklet のスコープなど）を、偽にする。
 * 型の名前で判定する（構造化複製で届く値は、受け取った側の領域の物だが、領域をまたぐ値でも、同じ判定になる）。
 */
function isFloat32Array(value: unknown): value is Float32Array {
  return ArrayBuffer.isView(value) && Object.prototype.toString.call(value) === "[object Float32Array]";
}

function isRejectReason(value: unknown): value is WorkletRejectReason {
  return typeof value === "string" && (WORKLET_REJECT_REASONS as readonly string[]).includes(value);
}

/** 0 以上の安全な整数か（累積サンプル数・サンプル数）。 */
function isSafeNonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function parseBlock(record: Record<string, unknown>, channelCount: number): WorkletBlockMessage {
  const { firstSample, frames, pcm } = record;
  if (!isSafeNonNegativeInteger(firstSample)) {
    throw new WorkletProtocolError("invalid_first_sample");
  }
  if (!isSafeNonNegativeInteger(frames) || frames === 0) {
    throw new WorkletProtocolError("invalid_frames");
  }
  if (!isFloat32Array(pcm) || pcm.length !== frames * channelCount) {
    throw new WorkletProtocolError("invalid_pcm");
  }
  return { type: "block", firstSample, frames, pcm };
}

function parseRejected(record: Record<string, unknown>): WorkletRejectedMessage {
  const { command, reason } = record;
  if (command !== null && typeof command !== "string") {
    throw new WorkletProtocolError("invalid_command");
  }
  if (!isRejectReason(reason)) {
    throw new WorkletProtocolError("invalid_reason");
  }
  return { type: "rejected", command, reason };
}

/**
 * Worklet から届いたメッセージを検査して、型のついた値にする。形を信用しない（決められた形でなければ、WorkletProtocolError）。
 * channelCount は、ブロックの PCM のチャンネル数（既定は 2）。
 */
export function parseWorkletMessage(data: unknown, channelCount: number = MIXER_CHANNEL_COUNT): WorkletMessage {
  if (typeof data !== "object" || data === null) {
    throw new WorkletProtocolError("not_an_object");
  }
  const record = data as Record<string, unknown>;
  switch (record.type) {
    case "block":
      return parseBlock(record, channelCount);
    case "rejected":
      return parseRejected(record);
    default:
      throw new WorkletProtocolError("unknown_type");
  }
}
