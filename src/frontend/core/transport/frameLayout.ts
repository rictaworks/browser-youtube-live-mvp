// フレームの構造（ws-protocol.md の 2 章・4 章、requirements.md 11.9）。1 メッセージ = 1 フレーム = ヘッダ 17 バイト + 本文。
//   ヘッダ：識別子 2（0x42 0x4C）・版 1・種別 1・属性 1（bit0 = キーフレーム。bit1 から bit7 は予約）・時刻 8（メディアクロックのマイクロ秒。
//   符号なし 64 ビット）・本文長 4（符号なし 32 ビット）。数値は、ビッグエンディアン。
//   欄の位置・大きさ・上限・種別の符号は、契約（core/contract の LIMITS.ws_frame）から取る（直書きしない）。
//
// 判定の入力は、受け取ったバイト列そのもので、本文の中身は見ない（再エンコードしない。11.1）。
// 時刻は BigInt で扱い、Number へ変換しない（2^53 を超え得る）。BigInt のリテラル（1n）は使わない（tsconfig の target が ES2017 のため）。
// 切断するか・破棄するかは、呼び出し側が決める（4.1）。この層は、型付きのエラー（FrameError）を投げる。

import { LIMITS, WS_MESSAGE_TYPE_VALUES } from "../contract";
import type { WsMessageType } from "../contract";
import { isUint8Array } from "./bytes";
import { FrameError } from "./errors";

/** メッセージの方向。受信側が受理する方向でもある（中継は browser_to_relay、ブラウザは relay_to_browser）。 */
export type FrameDirection = (typeof LIMITS.ws_frame.directions)[number];

/** 時刻（マイクロ秒）。Number は、安全整数（0 以上）だけ。2^53 以上は BigInt で渡す。 */
export type TimestampUs = bigint | number;

/** 復号したフレーム。body は、受け取ったメッセージの一部のビュー（コピーしない）。 */
export interface RawFrame {
  readonly type: WsMessageType;
  readonly keyframe: boolean;
  readonly timestampUs: bigint;
  readonly body: Uint8Array;
}

/** 時刻（メディアクロック）を持つメッセージの種別。映像と音声だけ（ws-protocol.md の 2 章）。 */
export type MediaMessageType = "video" | "audio";

/** 制御メッセージの種別（映像・音声以外の 12 種）。ヘッダの時刻の欄は 0。 */
export type ControlMessageType = Exclude<WsMessageType, MediaMessageType>;

/** 制御メッセージの符号化の内容。keyframe と timestampUs を省くと、false と 0。 */
export interface ControlFrameInput {
  readonly type: ControlMessageType;
  readonly keyframe?: boolean;
  readonly timestampUs?: TimestampUs;
  readonly body: Uint8Array;
}

/**
 * 映像・音声の符号化の内容。timestampUs は必須（省くと、符号化は invalid_message）。keyframe を省くと false。
 * 時刻を 0 で補うと、中継の TimeGuard が「同じ種別で時刻が逆行するフレーム」として 2 枚目以降を破棄し、ブラウザには何も見えないまま配信が止まる。
 */
export interface MediaFrameInput {
  readonly type: MediaMessageType;
  readonly keyframe?: boolean;
  readonly timestampUs: TimestampUs;
  readonly body: Uint8Array;
}

/** 符号化するフレームの内容。種別で、時刻の扱いが分かれる（映像・音声は必須、制御メッセージは省略可）。 */
export type RawFrameInput = ControlFrameInput | MediaFrameInput;

const HEADER_BYTES = LIMITS.ws_frame.header_bytes;
const MAX_MESSAGE_BYTES = LIMITS.ws_frame.max_message_bytes;
const FIELDS = LIMITS.ws_frame.header_fields;
const MAGIC = LIMITS.ws_frame.magic;
const VERSION = LIMITS.ws_frame.version;
const KEYFRAME_MASK = 1 << LIMITS.ws_frame.keyframe_attribute_bit;
const DIRECTIONS: readonly FrameDirection[] = LIMITS.ws_frame.directions;

/** 時刻を持つ種別（映像・音声）。型の MediaMessageType と同じ 2 つ。 */
const MEDIA_MESSAGE_TYPES: readonly WsMessageType[] = ["video", "audio"];

const ZERO = BigInt(0);
const MAX_UINT64 = (BigInt(1) << BigInt(64)) - BigInt(1);

interface FrameTypeInfo {
  readonly name: WsMessageType;
  readonly code: number;
  readonly direction: FrameDirection;
}

interface TypeTables {
  readonly byName: ReadonlyMap<WsMessageType, FrameTypeInfo>;
  readonly byCode: ReadonlyMap<number, FrameTypeInfo>;
}

/** 契約の種別の表（名前 -> 符号・方向）から、名前と符号の両方向の引き表を作る。契約が食い違っていれば（符号の重複・欠け）、RangeError。 */
function buildTypeTables(): TypeTables {
  const byName = new Map<WsMessageType, FrameTypeInfo>();
  const byCode = new Map<number, FrameTypeInfo>();
  for (const name of WS_MESSAGE_TYPE_VALUES) {
    const entry = LIMITS.ws_frame.types[name];
    const info: FrameTypeInfo = Object.freeze({ name, code: entry.code, direction: entry.direction });
    if (byCode.has(info.code)) {
      throw new RangeError(`contract frame type code is duplicated: ${info.code}`);
    }
    byName.set(name, info);
    byCode.set(info.code, info);
  }
  return Object.freeze({ byName, byCode });
}

const TYPE_TABLES = buildTypeTables();

/** メッセージの種別の方向（ブラウザ → 中継か、中継 → ブラウザか）。未知の名前は undefined。 */
export function directionOfType(type: WsMessageType): FrameDirection | undefined {
  return TYPE_TABLES.byName.get(type)?.direction;
}

/** 時刻を、ヘッダの 8 バイトの値にする。required（映像・音声）で省いたときは、0 で補わず、invalid_message。 */
function toTimestamp(value: TimestampUs | undefined, required: boolean): bigint {
  if (value === undefined) {
    if (required) {
      throw new FrameError("invalid_message", "a video or audio frame needs a timestamp (it is never defaulted to 0)");
    }
    return ZERO;
  }
  if (typeof value === "bigint") {
    if (value < ZERO || value > MAX_UINT64) {
      throw new FrameError("invalid_message", "timestamp is out of the unsigned 64-bit range");
    }
    return value;
  }
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new FrameError("invalid_message", "a timestamp given as a number must be a non-negative safe integer (use a bigint above 2^53 - 1)");
    }
    return BigInt(value);
  }
  throw new FrameError("invalid_message", `timestamp must be a bigint or a number: ${typeof value}`);
}

/**
 * フレームを、1 メッセージのバイト列にする。種別は、契約の 14 種のどれか（でなければ unknown_type）。方向は検査しない（中継の Go の Encode と同じ。
 * ブラウザが送る 7 種に絞るのは FrameCodec）。全体（17 + 本文）が 2,097,152 バイト以下（超えれば too_large）。属性の予約ビットは 0。
 * 時刻：映像・音声は必須（省く、または bigint と数値以外は invalid_message。0 を黙って補わない）。制御メッセージは省略でき、省くと 0。
 * 本文は、新しい領域へコピーする（返したバイト列を書き換えても、本文は変わらない）。
 */
export function encodeRawFrame(input: RawFrameInput): Uint8Array {
  const info = TYPE_TABLES.byName.get(input.type);
  if (info === undefined) {
    throw new FrameError("unknown_type", `unknown message type name: ${String(input.type).slice(0, 32)}`);
  }
  if (!isUint8Array(input.body)) {
    throw new FrameError("invalid_message", `body must be a Uint8Array: ${Object.prototype.toString.call(input.body)}`);
  }
  if (input.keyframe !== undefined && typeof input.keyframe !== "boolean") {
    throw new FrameError("invalid_message", `keyframe must be a boolean: ${typeof input.keyframe}`);
  }
  const timestampUs = toTimestamp(input.timestampUs, MEDIA_MESSAGE_TYPES.includes(input.type));
  const total = HEADER_BYTES + input.body.length;
  if (total > MAX_MESSAGE_BYTES) {
    throw new FrameError("too_large", `message would be ${total} bytes, the limit is ${MAX_MESSAGE_BYTES}`);
  }

  const message = new Uint8Array(total);
  const view = new DataView(message.buffer, message.byteOffset, message.byteLength);
  message[FIELDS.magic.offset] = MAGIC[0];
  message[FIELDS.magic.offset + 1] = MAGIC[1];
  message[FIELDS.version.offset] = VERSION;
  message[FIELDS.type.offset] = info.code;
  message[FIELDS.attributes.offset] = input.keyframe === true ? KEYFRAME_MASK : 0;
  view.setBigUint64(FIELDS.timestamp_us.offset, timestampUs);
  view.setUint32(FIELDS.body_length.offset, input.body.length);
  message.set(input.body, HEADER_BYTES);
  return message;
}

/**
 * 受け取った 1 メッセージを、検証して復号する。accepts は、受信側が受理する種別の方向（ブラウザは relay_to_browser、中継は browser_to_relay）。
 * 検証は、ws-protocol.md の 4 章の順に行い、最初に該当した誤りを FrameError で返す：
 *   1. truncated_header     17 バイトに満たない
 *   2. invalid_magic        識別子が 0x42 0x4C でない
 *   3. unsupported_version  版が 1 でない
 *   4. unknown_type         種別符号が 14 種のどれでもない
 *   5. wrong_direction      受理しない方向の種別
 *   6. too_large            受け取ったバイト数、または宣言する大きさ（17 + 本文長）が、2,097,152 を超える
 *   7. length_mismatch      受け取った本文のバイト数が、本文長と一致しない（不足も超過も）
 * 本文長の宣言に比例した確保をしない（ヘッダだけで判定する）。message は書き換えない。
 * accepts が 2 つの方向のどちらでもない（呼び出しの誤り）、message が Uint8Array でない場合は、推測しない。
 */
export function decodeRawFrame(message: Uint8Array, accepts: FrameDirection): RawFrame {
  if (!DIRECTIONS.includes(accepts)) {
    throw new RangeError(`accepts must be one of ${DIRECTIONS.join(", ")}: ${String(accepts)}`);
  }
  if (!isUint8Array(message)) {
    throw new FrameError("invalid_message", `message must be a Uint8Array: ${Object.prototype.toString.call(message)}`);
  }
  const length = message.length;
  if (length < HEADER_BYTES) {
    throw new FrameError("truncated_header", `message is ${length} bytes, the header needs ${HEADER_BYTES}`);
  }
  const magic0 = message[FIELDS.magic.offset];
  const magic1 = message[FIELDS.magic.offset + 1];
  if (magic0 !== MAGIC[0] || magic1 !== MAGIC[1]) {
    throw new FrameError("invalid_magic", `got 0x${magic0.toString(16)} 0x${magic1.toString(16)}, want 0x${MAGIC[0].toString(16)} 0x${MAGIC[1].toString(16)}`);
  }
  const version = message[FIELDS.version.offset];
  if (version !== VERSION) {
    throw new FrameError("unsupported_version", `got ${version}, want ${VERSION}`);
  }
  const typeCode = message[FIELDS.type.offset];
  const info = TYPE_TABLES.byCode.get(typeCode);
  if (info === undefined) {
    throw new FrameError("unknown_type", `got 0x${typeCode.toString(16)}`);
  }
  if (info.direction !== accepts) {
    throw new FrameError("wrong_direction", `type ${info.name} goes ${info.direction}, this receiver accepts ${accepts}`);
  }

  const view = new DataView(message.buffer, message.byteOffset, message.byteLength);
  const bodyLength = view.getUint32(FIELDS.body_length.offset);
  const declaredBytes = HEADER_BYTES + bodyLength;
  if (length > MAX_MESSAGE_BYTES || declaredBytes > MAX_MESSAGE_BYTES) {
    throw new FrameError("too_large", `message is ${length} bytes, the header declares ${declaredBytes}, the limit is ${MAX_MESSAGE_BYTES}`);
  }
  if (length - HEADER_BYTES !== bodyLength) {
    throw new FrameError("length_mismatch", `body is ${length - HEADER_BYTES} bytes, the header declares ${bodyLength}`);
  }

  return Object.freeze({
    type: info.name,
    keyframe: (message[FIELDS.attributes.offset] & KEYFRAME_MASK) !== 0,
    timestampUs: view.getBigUint64(FIELDS.timestamp_us.offset),
    body: message.subarray(HEADER_BYTES),
  });
}
