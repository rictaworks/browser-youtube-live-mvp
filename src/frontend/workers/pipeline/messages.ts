// メインスレッド <-> ワーカーの型付きメッセージ（issue #27）。境界を越える値は信用せず、決められた形でなければ invalid_message で拒否する。
//
//   メインスレッド -> ワーカー（PipelineCommand）
//     attach_preview / detach_preview  プレビュー用の canvas（transferControlToOffscreen した OffscreenCanvas）を渡す・外す
//     add_source / remove_source       映像ソース（画面共有・カメラ）の追加・解除。メインスレッドで MediaStreamTrackProcessor を作り、その readable
//                                      （VideoFrame のストリーム）を転送する（Chrome では、ワーカー内で MediaStreamTrackProcessor は使えず、
//                                      MediaStreamTrack も転送できない。WORK/factcheck/20261007_external-facts.md の項目 12）
//     configure                        エンコーダの設定（配信の開始）。プロファイル・映像のコーデック・映像ビットレートの開始値。応答は復号器設定
//     connect_audio                    音声のポート（#26 のミキサーが送るブロックを、メインスレッドを経由せず、直接受ける。MessagePort の転送）
//     audio_stalled / audio_resumed    AudioContext の停止・再開の通知（メインスレッドから転送。MediaClock の停止・再開へつなぐ）
//     set_bitrate / request_keyframe   適応制御の目標・キーフレーム要求
//     begin_delivery / pause_delivery  符号化結果を渡す・渡さない（開始時は送出開始の通知のあと、復帰時はキーフレーム要求のあと）
//     get_config / get_stats           復号器設定の再取得・統計
//     end_session / shutdown           配信の終了（エンコーダを閉じ、プレビューだけの状態へ戻る）・ワーカーの終了
//   ワーカー -> メインスレッド（PipelineEvent）
//     ready / reply / chunk / decoder_config / layout / source_ended / fault
//
// 応答のある要求は、requestId（正の整数）で対応づける。未知のキーは無視する（前方互換）。

import { isLayout, isProfile } from "@/core/contract";
import type { Layout, Profile } from "@/core/contract";
import { LIMITS } from "@/core/contract";
import type { VideoCodec } from "@/core/transport";
import { createEncodedChunk, isDecoderConfigChunk, isEncodedChunk } from "@/lib/pipeline/chunks";
import type { DecoderConfigChunk, EncodedChunk } from "@/lib/pipeline/chunks";
import { PipelineError, isPipelineErrorCode } from "@/lib/pipeline/errors";
import type { PipelineFault } from "@/lib/pipeline/errors";
import type { ChunkGateCounters } from "./ChunkGate";
import { isVideoSourceKind } from "./FrameStore";
import type { VideoSourceKind } from "./FrameStore";

// ---------------------------------------------------------------------------
// 型
// ---------------------------------------------------------------------------

export const COMMAND_TYPES = [
  "attach_preview",
  "detach_preview",
  "add_source",
  "remove_source",
  "configure",
  "connect_audio",
  "audio_stalled",
  "audio_resumed",
  "set_bitrate",
  "request_keyframe",
  "begin_delivery",
  "pause_delivery",
  "get_config",
  "get_stats",
  "end_session",
  "shutdown",
] as const;
export type CommandType = (typeof COMMAND_TYPES)[number];

export type PipelineCommand =
  | { readonly type: "attach_preview"; readonly canvas: OffscreenCanvas }
  | { readonly type: "detach_preview" }
  | { readonly type: "add_source"; readonly kind: VideoSourceKind; readonly readable: ReadableStream<VideoFrame> }
  | { readonly type: "remove_source"; readonly kind: VideoSourceKind }
  | { readonly type: "configure"; readonly requestId: number; readonly profile: Profile; readonly videoCodec: VideoCodec; readonly videoBitrateKbps: number }
  | { readonly type: "connect_audio"; readonly port: MessagePort }
  | { readonly type: "audio_stalled" }
  | { readonly type: "audio_resumed" }
  | { readonly type: "set_bitrate"; readonly kbps: number }
  | { readonly type: "request_keyframe" }
  | { readonly type: "begin_delivery" }
  | { readonly type: "pause_delivery" }
  | { readonly type: "get_config"; readonly requestId: number }
  | { readonly type: "get_stats"; readonly requestId: number }
  | { readonly type: "end_session"; readonly requestId: number }
  | { readonly type: "shutdown" };

/** ワーカーの統計。健全性の「破棄フレーム数」（droppedBeforeEncode）・解放漏れの検査（framesReceived = framesClosed + framesRetained）などに使う。 */
export interface PipelineStats {
  /** preview: 配信前のプレビューだけ（ワーカーのタイマで駆動）。clock: 音声の処理周期で駆動（配信中） */
  readonly mode: "preview" | "clock";
  readonly profile: Profile | null;
  readonly videoBitrateKbps: number | null;
  readonly layout: Layout | null;
  readonly composedFrames: number;
  readonly composeFailures: number;
  /** ワーカーが遅れて（音声のブロックの処理が積み上がって）、合成を飛ばしたフレームの数。符号化の前に飛ばしたもので、入力待ちの破棄とは別 */
  readonly skippedForLag: number;
  /** 音声のブロックの処理待ちの深さ（ミリ秒。直近のブロックの時点の推定。0 = 遅れていない）。適応制御・健全性の表示が、ワーカーの余裕を知るため */
  readonly audioBacklogMs: number;
  readonly encodedVideoFrames: number;
  /** 入力待ちが 2 フレームを超えたため、符号化せず捨てた映像フレームの数 */
  readonly droppedBeforeEncode: number;
  readonly deliveredVideoChunks: number;
  readonly deliveredAudioChunks: number;
  readonly gateOpen: boolean;
  readonly gate: ChunkGateCounters;
  readonly framesReceived: number;
  readonly framesClosed: number;
  readonly framesRetained: number;
  readonly videoEncodeQueueSize: number;
  readonly videoFaulted: boolean;
  readonly audioFaulted: boolean;
  readonly clock: { readonly sampleCount: number; readonly frameIndex: number; readonly stalled: boolean } | null;
}

export type ReplyResult =
  | { readonly kind: "configured"; readonly video: DecoderConfigChunk; readonly audio: DecoderConfigChunk }
  | { readonly kind: "config"; readonly video: DecoderConfigChunk | null; readonly audio: DecoderConfigChunk | null }
  | { readonly kind: "stats"; readonly stats: PipelineStats }
  | { readonly kind: "ended" };

export const EVENT_TYPES = ["ready", "reply", "chunk", "decoder_config", "layout", "source_ended", "fault"] as const;
export type EventType = (typeof EVENT_TYPES)[number];

export type PipelineEvent =
  | { readonly type: "ready" }
  | { readonly type: "reply"; readonly requestId: number; readonly ok: true; readonly result: ReplyResult }
  | { readonly type: "reply"; readonly requestId: number; readonly ok: false; readonly fault: PipelineFault }
  | { readonly type: "chunk"; readonly chunk: EncodedChunk }
  | { readonly type: "decoder_config"; readonly config: DecoderConfigChunk }
  | { readonly type: "layout"; readonly layout: Layout }
  | { readonly type: "source_ended"; readonly kind: VideoSourceKind }
  | { readonly type: "fault"; readonly fault: PipelineFault };

// ---------------------------------------------------------------------------
// 検証の部品
// ---------------------------------------------------------------------------

function invalid(): PipelineError {
  return new PipelineError("invalid_message");
}

function asRecord(data: unknown): Record<string, unknown> {
  if (typeof data !== "object" || data === null) {
    throw invalid();
  }
  return data as Record<string, unknown>;
}

function isFunctionMember(value: unknown, name: string): boolean {
  return typeof value === "object" && value !== null && typeof (value as Record<string, unknown>)[name] === "function";
}

function requestIdOf(record: Record<string, unknown>): number {
  const value = record.requestId;
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) {
    throw invalid();
  }
  return value;
}

function integerOf(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    throw invalid();
  }
  return value;
}

function nonNegativeIntegerOf(value: unknown): number {
  const integer = integerOf(value);
  if (integer < 0) {
    throw invalid();
  }
  return integer;
}

function booleanOf(value: unknown): boolean {
  if (typeof value !== "boolean") {
    throw invalid();
  }
  return value;
}

function isVideoCodec(value: unknown): value is VideoCodec {
  return value === LIMITS.video.codec_main || value === LIMITS.video.codec_constrained_baseline;
}

function videoSourceKindOf(value: unknown): VideoSourceKind {
  if (!isVideoSourceKind(value)) {
    throw invalid();
  }
  return value;
}

// ---------------------------------------------------------------------------
// コマンド
// ---------------------------------------------------------------------------

/** メインスレッドから届いた値を、検査して、コマンドにする。形が違えば invalid_message。 */
export function parseCommand(data: unknown): PipelineCommand {
  const record = asRecord(data);
  switch (record.type) {
    case "attach_preview":
      if (!isFunctionMember(record.canvas, "getContext")) {
        throw invalid();
      }
      return { type: "attach_preview", canvas: record.canvas as OffscreenCanvas };
    case "detach_preview":
      return { type: "detach_preview" };
    case "add_source":
      if (!isFunctionMember(record.readable, "getReader")) {
        throw invalid();
      }
      return { type: "add_source", kind: videoSourceKindOf(record.kind), readable: record.readable as ReadableStream<VideoFrame> };
    case "remove_source":
      return { type: "remove_source", kind: videoSourceKindOf(record.kind) };
    case "configure": {
      const requestId = requestIdOf(record);
      if (!isProfile(record.profile) || !isVideoCodec(record.videoCodec)) {
        throw invalid();
      }
      return { type: "configure", requestId, profile: record.profile, videoCodec: record.videoCodec, videoBitrateKbps: integerOf(record.videoBitrateKbps) };
    }
    case "connect_audio":
      if (!isFunctionMember(record.port, "close")) {
        throw invalid();
      }
      return { type: "connect_audio", port: record.port as MessagePort };
    case "audio_stalled":
      return { type: "audio_stalled" };
    case "audio_resumed":
      return { type: "audio_resumed" };
    case "set_bitrate":
      if (typeof record.kbps !== "number" || !Number.isFinite(record.kbps)) {
        throw invalid();
      }
      return { type: "set_bitrate", kbps: record.kbps };
    case "request_keyframe":
      return { type: "request_keyframe" };
    case "begin_delivery":
      return { type: "begin_delivery" };
    case "pause_delivery":
      return { type: "pause_delivery" };
    case "get_config":
      return { type: "get_config", requestId: requestIdOf(record) };
    case "get_stats":
      return { type: "get_stats", requestId: requestIdOf(record) };
    case "end_session":
      return { type: "end_session", requestId: requestIdOf(record) };
    case "shutdown":
      return { type: "shutdown" };
    default:
      throw invalid();
  }
}

/** コマンドを postMessage するときの転送対象。canvas・readable・ポートは、コピーせず転送する。 */
export function transferablesOfCommand(command: PipelineCommand): Transferable[] {
  switch (command.type) {
    case "attach_preview":
      return [command.canvas];
    case "add_source":
      return [command.readable];
    case "connect_audio":
      return [command.port];
    default:
      return [];
  }
}

// ---------------------------------------------------------------------------
// イベント
// ---------------------------------------------------------------------------

function faultOf(value: unknown): PipelineFault {
  const record = asRecord(value);
  if (!isPipelineErrorCode(record.code) || (record.detail !== null && typeof record.detail !== "string")) {
    throw invalid();
  }
  return { code: record.code, detail: record.detail };
}

function decoderConfigOf(value: unknown): DecoderConfigChunk {
  if (!isDecoderConfigChunk(value)) {
    throw invalid();
  }
  return value;
}

function gateCountersOf(value: unknown): ChunkGateCounters {
  const record = asRecord(value);
  return {
    closedDiscardedVideo: nonNegativeIntegerOf(record.closedDiscardedVideo),
    closedDiscardedAudio: nonNegativeIntegerOf(record.closedDiscardedAudio),
    skippedBeforeKeyframe: nonNegativeIntegerOf(record.skippedBeforeKeyframe),
  };
}

function clockOf(value: unknown): PipelineStats["clock"] {
  if (value === null) {
    return null;
  }
  const record = asRecord(value);
  return { sampleCount: nonNegativeIntegerOf(record.sampleCount), frameIndex: nonNegativeIntegerOf(record.frameIndex), stalled: booleanOf(record.stalled) };
}

function statsOf(value: unknown): PipelineStats {
  const record = asRecord(value);
  if (record.mode !== "preview" && record.mode !== "clock") {
    throw invalid();
  }
  const profile = record.profile === null ? null : isProfile(record.profile) ? record.profile : undefined;
  const layout = record.layout === null ? null : isLayout(record.layout) ? record.layout : undefined;
  if (profile === undefined || layout === undefined) {
    throw invalid();
  }
  return {
    mode: record.mode,
    profile,
    videoBitrateKbps: record.videoBitrateKbps === null ? null : nonNegativeIntegerOf(record.videoBitrateKbps),
    layout,
    composedFrames: nonNegativeIntegerOf(record.composedFrames),
    composeFailures: nonNegativeIntegerOf(record.composeFailures),
    skippedForLag: nonNegativeIntegerOf(record.skippedForLag),
    audioBacklogMs: nonNegativeIntegerOf(record.audioBacklogMs),
    encodedVideoFrames: nonNegativeIntegerOf(record.encodedVideoFrames),
    droppedBeforeEncode: nonNegativeIntegerOf(record.droppedBeforeEncode),
    deliveredVideoChunks: nonNegativeIntegerOf(record.deliveredVideoChunks),
    deliveredAudioChunks: nonNegativeIntegerOf(record.deliveredAudioChunks),
    gateOpen: booleanOf(record.gateOpen),
    gate: gateCountersOf(record.gate),
    framesReceived: nonNegativeIntegerOf(record.framesReceived),
    framesClosed: nonNegativeIntegerOf(record.framesClosed),
    framesRetained: nonNegativeIntegerOf(record.framesRetained),
    videoEncodeQueueSize: nonNegativeIntegerOf(record.videoEncodeQueueSize),
    videoFaulted: booleanOf(record.videoFaulted),
    audioFaulted: booleanOf(record.audioFaulted),
    clock: clockOf(record.clock),
  };
}

function replyResultOf(value: unknown): ReplyResult {
  const record = asRecord(value);
  switch (record.kind) {
    case "configured":
      return { kind: "configured", video: decoderConfigOf(record.video), audio: decoderConfigOf(record.audio) };
    case "config":
      return {
        kind: "config",
        video: record.video === null ? null : decoderConfigOf(record.video),
        audio: record.audio === null ? null : decoderConfigOf(record.audio),
      };
    case "stats":
      return { kind: "stats", stats: statsOf(record.stats) };
    case "ended":
      return { kind: "ended" };
    default:
      throw invalid();
  }
}

/** ワーカーから届いた値を、検査して、イベントにする。形が違えば invalid_message。 */
export function parseEvent(data: unknown): PipelineEvent {
  const record = asRecord(data);
  switch (record.type) {
    case "ready":
      return { type: "ready" };
    case "reply": {
      const requestId = requestIdOf(record);
      if (record.ok === true) {
        return { type: "reply", requestId, ok: true, result: replyResultOf(record.result) };
      }
      if (record.ok === false) {
        return { type: "reply", requestId, ok: false, fault: faultOf(record.fault) };
      }
      throw invalid();
    }
    case "chunk":
      if (!isEncodedChunk(record.chunk)) {
        throw invalid();
      }
      return { type: "chunk", chunk: record.chunk };
    case "decoder_config":
      return { type: "decoder_config", config: decoderConfigOf(record.config) };
    case "layout":
      if (!isLayout(record.layout)) {
        throw invalid();
      }
      return { type: "layout", layout: record.layout };
    case "source_ended":
      return { type: "source_ended", kind: videoSourceKindOf(record.kind) };
    case "fault":
      return { type: "fault", fault: faultOf(record.fault) };
    default:
      throw invalid();
  }
}

/**
 * イベントを postMessage するときの、メッセージと転送対象。符号化結果は、ArrayBuffer を転送する（コピーしない）。
 * バッファの一部だけを指すビューは、転送すると他のデータを巻き込むので、正確な大きさの新しいバッファへ複写してから転送する。
 */
export function prepareEventForPost(event: PipelineEvent): { readonly message: PipelineEvent; readonly transfer: Transferable[] } {
  if (event.type !== "chunk") {
    return { message: event, transfer: [] };
  }
  const data = event.chunk.data;
  if (data.byteOffset === 0 && data.byteLength === data.buffer.byteLength) {
    return { message: event, transfer: [data.buffer as ArrayBuffer] };
  }
  const exact = new Uint8Array(data);
  const chunk = createEncodedChunk({ kind: event.chunk.kind, timestampUs: event.chunk.timestampUs, keyframe: event.chunk.keyframe, data: exact });
  return { message: { type: "chunk", chunk }, transfer: [exact.buffer] };
}
