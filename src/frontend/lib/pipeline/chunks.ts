// 符号化結果（EncodedChunk）と、復号器設定（DecoderConfigChunk）の型（requirements.md 11.7・11.9、契約 ws-protocol.md の 5.3・5.4）。
//
//   EncodedChunk        映像: AVCC 形式のまま（各 NAL の前に 4 バイトの長さ。開始コードなし）。音声: 生の AAC のまま（ADTS なし）。
//                       中継は中身を見ず、FLV のタグへ詰め替える（再エンコードしない。11.1）。#25 の SendQueue の ChunkMeta を満たし、
//                       FrameCodec の video / audio の本文（payload）へ、そのまま入れられる
//   DecoderConfigChunk  エンコーダが最初の出力で返す decoderConfig.description（映像 = AVCDecoderConfigurationRecord・音声 = AudioSpecificConfig）。
//                       開始通知（start）の description_b64 になる。最初のメディアフレームより前に送る（呼び出しの順は #28）
//
// 時刻は、メディアクロックのマイクロ秒（0 以上の安全整数）。実時計で採番しない。映像 = 入力フレームの timestamp（videoTime(フレーム番号)）、
// 音声 = audioTime(累積サンプル数)。

import { PipelineError } from "./errors";

export type MediaKind = "video" | "audio";

export interface EncodedChunk {
  readonly kind: MediaKind;
  /** メディア時刻（マイクロ秒）。0 以上の安全整数。同じ種別の中で、逆行しない */
  readonly timestampUs: number;
  /** キーフレームか。音声は、常に false（AAC の全フレームが独立だが、キーフレームの属性は映像のもの） */
  readonly keyframe: boolean;
  /** 符号化データのバイト数（data.length） */
  readonly byteLength: number;
  readonly data: Uint8Array;
}

export interface DecoderConfigChunk {
  readonly kind: MediaKind;
  /** コーデック文字列（映像: avc1.4D401F など。音声: mp4a.40.2） */
  readonly codec: string;
  /** 復号器設定。映像 = AVCDecoderConfigurationRecord、音声 = AudioSpecificConfig */
  readonly description: Uint8Array;
}

export interface EncodedChunkInput {
  readonly kind: MediaKind;
  readonly timestampUs: number;
  readonly keyframe: boolean;
  readonly data: Uint8Array;
}

/** AVCDecoderConfigurationRecord の、固定部分の長さ（版・プロファイル・互換性・レベル・NAL 長の大きさ・SPS の数・PPS の数）と、版の値。 */
const AVCC_MINIMUM_BYTES = 7;
const AVCC_CONFIGURATION_VERSION = 1;
/** AudioSpecificConfig の最小の長さ（AAC-LC は 2 バイト）。 */
const AUDIO_SPECIFIC_CONFIG_MINIMUM_BYTES = 2;

function isUint8Array(value: unknown): value is Uint8Array {
  return Object.prototype.toString.call(value) === "[object Uint8Array]";
}

function isMediaKind(value: unknown): value is MediaKind {
  return value === "video" || value === "audio";
}

function isMediaTime(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

/**
 * 符号化結果を作る。種別・時刻・キーフレームの指定・バイト列が不正なら RangeError（推測せず、続けない）。
 * バイト列は、コピーしない（呼び出し側が渡した、新しい領域をそのまま持つ。ワーカーからの転送で、ArrayBuffer ごと渡すため）。
 */
export function createEncodedChunk(input: EncodedChunkInput): EncodedChunk {
  if (!isMediaKind(input.kind)) {
    throw new RangeError(`chunk kind must be video or audio: ${String(input.kind)}`);
  }
  if (!isMediaTime(input.timestampUs)) {
    throw new RangeError(`chunk timestampUs must be a non-negative safe integer: ${String(input.timestampUs)}`);
  }
  if (typeof input.keyframe !== "boolean") {
    throw new RangeError(`chunk keyframe must be a boolean: ${typeof input.keyframe}`);
  }
  if (input.kind === "audio" && input.keyframe) {
    throw new RangeError("an audio chunk cannot be a keyframe");
  }
  if (!isUint8Array(input.data)) {
    throw new RangeError("chunk data must be a Uint8Array");
  }
  return Object.freeze({ kind: input.kind, timestampUs: input.timestampUs, keyframe: input.keyframe, byteLength: input.data.length, data: input.data });
}

/** ワーカーから届いた値が、符号化結果の形か（形を信用しない）。 */
export function isEncodedChunk(value: unknown): value is EncodedChunk {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const candidate = value as Partial<Record<keyof EncodedChunk, unknown>>;
  return (
    isMediaKind(candidate.kind) &&
    isMediaTime(candidate.timestampUs) &&
    typeof candidate.keyframe === "boolean" &&
    !(candidate.kind === "audio" && candidate.keyframe) &&
    isUint8Array(candidate.data) &&
    candidate.byteLength === candidate.data.length
  );
}

function assertDescription(kind: MediaKind, description: Uint8Array): void {
  if (kind === "video") {
    if (description.length < AVCC_MINIMUM_BYTES || description[0] !== AVCC_CONFIGURATION_VERSION) {
      throw new PipelineError("decoder_config_missing");
    }
    return;
  }
  if (description.length < AUDIO_SPECIFIC_CONFIG_MINIMUM_BYTES) {
    throw new PipelineError("decoder_config_missing");
  }
}

/**
 * 復号器設定を作る。形が正しくなければ decoder_config_missing（黙って空の設定を送らない。中継は、設定がそろうまで publish を開始しない。11.10）。
 * 映像は AVCDecoderConfigurationRecord（先頭が版 1・7 バイト以上）、音声は AudioSpecificConfig（2 バイト以上）。
 * バイト列は、コピーして持つ（エンコーダが返したバッファを、あとから書き換えられても変わらない）。
 */
export function createDecoderConfigChunk(input: { readonly kind: MediaKind; readonly codec: string; readonly description: Uint8Array }): DecoderConfigChunk {
  if (!isMediaKind(input.kind) || typeof input.codec !== "string" || input.codec === "" || !isUint8Array(input.description)) {
    throw new PipelineError("decoder_config_missing");
  }
  assertDescription(input.kind, input.description);
  return Object.freeze({ kind: input.kind, codec: input.codec, description: new Uint8Array(input.description) });
}

/** ワーカーから届いた値が、復号器設定の形か。 */
export function isDecoderConfigChunk(value: unknown): value is DecoderConfigChunk {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const candidate = value as Partial<Record<keyof DecoderConfigChunk, unknown>>;
  return isMediaKind(candidate.kind) && typeof candidate.codec === "string" && candidate.codec !== "" && isUint8Array(candidate.description) && candidate.description.length > 0;
}
