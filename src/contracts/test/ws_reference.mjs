// WebSocket 転送フレームの参照実装（テスト用の、独立した小さなエンコーダとデコーダ）。
//
// ws-frame-vectors.json の自己整合を検査するためのもので、フロントエンド（#25）と中継（#18）の
// コーデックの実装ではない。ヘッダの配置は、ここへ直接書く（limits.json の ws_frame と同じであることは、
// limits.test.mjs が別に確かめる）。ビッグエンディアン。ヘッダ 17 バイト:
//   0〜1   識別子  0x42 0x4C
//   2      版      1
//   3      種別
//   4      属性    bit0 = キーフレーム
//   5〜12  時刻    メディアクロック（マイクロ秒）。符号なし 64 ビット
//   13〜16 本文長  符号なし 32 ビット
// ws-protocol.md の「検証の順」と同じ順で、最初に該当した誤りを返す。

export const HEADER_BYTES = 17;
export const MAGIC = Uint8Array.of(0x42, 0x4c);
export const VERSION = 1;
export const MAX_MESSAGE_BYTES = 2_097_152;
export const U64_MAX = 18_446_744_073_709_551_615n;
export const U32_MAX = 4_294_967_295;

/** 受信側と、その受信側が受理する方向。 */
export const INCOMING_DIRECTION = { relay: "browser_to_relay", browser: "relay_to_browser" };

/** 種別符号の表。limits.json を読まず、設計メモの表をそのまま書いた独立の写し（一致は limits.test.mjs が確かめる）。 */
export const REFERENCE_TYPES = {
  hello: { code: 0x01, direction: "browser_to_relay" },
  probe: { code: 0x02, direction: "browser_to_relay" },
  start: { code: 0x03, direction: "browser_to_relay" },
  video: { code: 0x04, direction: "browser_to_relay" },
  audio: { code: 0x05, direction: "browser_to_relay" },
  report: { code: 0x06, direction: "browser_to_relay" },
  end: { code: 0x07, direction: "browser_to_relay" },
  accepted: { code: 0x81, direction: "relay_to_browser" },
  probe_result: { code: 0x82, direction: "relay_to_browser" },
  ack: { code: 0x83, direction: "relay_to_browser" },
  keyframe_request: { code: 0x84, direction: "relay_to_browser" },
  throttle: { code: 0x85, direction: "relay_to_browser" },
  status: { code: 0x86, direction: "relay_to_browser" },
  fatal: { code: 0x87, direction: "relay_to_browser" },
};

const NAME_BY_CODE = new Map(Object.entries(REFERENCE_TYPES).map(([name, { code }]) => [code, name]));

/** 種別符号から、種別の名前を返す（未知なら undefined）。 */
export function typeNameOf(code) {
  return NAME_BY_CODE.get(code);
}

/**
 * フレームを作る。
 * @param {{typeCode: number, attributes?: number, timestampUs: bigint, body: Uint8Array, version?: number, magic?: Uint8Array, declaredLength?: number}} fields
 *   version・magic・declaredLength は、不正なフレームを作るときだけ指定する（既定は正しい値）。
 */
export function encodeFrame({ typeCode, attributes = 0, timestampUs, body, version = VERSION, magic = MAGIC, declaredLength = body.length }) {
  const frame = new Uint8Array(HEADER_BYTES + body.length);
  const view = new DataView(frame.buffer);
  frame.set(magic, 0);
  view.setUint8(2, version);
  view.setUint8(3, typeCode);
  view.setUint8(4, attributes);
  view.setBigUint64(5, timestampUs, false);
  view.setUint32(13, declaredLength, false);
  frame.set(body, HEADER_BYTES);
  return frame;
}

/**
 * フレームを復号する。受信側（relay または browser）が受理する方向だけを受理する。
 * @returns {{error: string} | {frame: {type: string, typeCode: number, attributes: number, keyframe: boolean, timestampUs: bigint, body: Uint8Array}}}
 */
export function decodeFrame(bytes, receiver) {
  if (!(receiver in INCOMING_DIRECTION)) {
    throw new Error(`受信側が不正です: ${receiver}`);
  }
  if (bytes.length < HEADER_BYTES) {
    return { error: "truncated_header" };
  }
  if (bytes[0] !== MAGIC[0] || bytes[1] !== MAGIC[1]) {
    return { error: "invalid_magic" };
  }
  if (bytes[2] !== VERSION) {
    return { error: "unsupported_version" };
  }
  const typeCode = bytes[3];
  const type = typeNameOf(typeCode);
  if (type === undefined) {
    return { error: "unknown_type" };
  }
  if (REFERENCE_TYPES[type].direction !== INCOMING_DIRECTION[receiver]) {
    return { error: "wrong_direction" };
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const declaredLength = view.getUint32(13, false);
  // 受け取ったバイト数と、ヘッダが宣言する大きさ（17 + 本文長）の、どちらが超えても too_large。
  // ヘッダだけの短いベクタで、2 MB 超を表せるようにするため。
  if (Math.max(bytes.length, HEADER_BYTES + declaredLength) > MAX_MESSAGE_BYTES) {
    return { error: "too_large" };
  }
  if (bytes.length - HEADER_BYTES !== declaredLength) {
    return { error: "length_mismatch" };
  }
  return {
    frame: {
      type,
      typeCode,
      attributes: bytes[4],
      keyframe: (bytes[4] & 0x01) === 0x01,
      timestampUs: view.getBigUint64(5, false),
      body: bytes.slice(HEADER_BYTES),
    },
  };
}
