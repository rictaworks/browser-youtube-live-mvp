'use strict';
// WebSocket 転送フレームの参照実装（ws-protocol.md の 2 章・4 章から書き下したもの）。Node の Buffer で書いた、TypeScript の実装（src/frontend/core/transport）とは
// 別の実装。差分テスト（check_vectors.cjs）と、実ブラウザの検査（probe_codec_in_browser.cjs。中継の代役が、これでフレームを読み書きする）が使う。
// 読み取りのみ。環境・時刻・乱数に依存しない。

const MAX_MESSAGE = 2097152;
const HEADER_BYTES = 17;

/** 種別の符号 -> [名前, 方向] */
const REFERENCE_TYPES = {
  0x01: ['hello', 'browser_to_relay'],
  0x02: ['probe', 'browser_to_relay'],
  0x03: ['start', 'browser_to_relay'],
  0x04: ['video', 'browser_to_relay'],
  0x05: ['audio', 'browser_to_relay'],
  0x06: ['report', 'browser_to_relay'],
  0x07: ['end', 'browser_to_relay'],
  0x81: ['accepted', 'relay_to_browser'],
  0x82: ['probe_result', 'relay_to_browser'],
  0x83: ['ack', 'relay_to_browser'],
  0x84: ['keyframe_request', 'relay_to_browser'],
  0x85: ['throttle', 'relay_to_browser'],
  0x86: ['status', 'relay_to_browser'],
  0x87: ['fatal', 'relay_to_browser'],
};
const CODE_OF = Object.fromEntries(Object.entries(REFERENCE_TYPES).map(([code, [name]]) => [name, Number(code)]));

/**
 * 検証の順（4 章）：切り詰め・識別子・版・種別・方向・大きさ・長さ。accepts は、受信側が受理する方向。
 * 結果は、{ error } または { type, keyframe, timestamp（10 進数の文字列）, body（16 進数の文字列）, bodyBytes（Buffer）}。
 */
function referenceDecode(bytes, accepts) {
  if (bytes.length < HEADER_BYTES) return { error: 'truncated_header' };
  if (bytes[0] !== 0x42 || bytes[1] !== 0x4c) return { error: 'invalid_magic' };
  if (bytes[2] !== 1) return { error: 'unsupported_version' };
  const entry = REFERENCE_TYPES[bytes[3]];
  if (entry === undefined) return { error: 'unknown_type' };
  if (entry[1] !== accepts) return { error: 'wrong_direction' };
  const declared = bytes.readUInt32BE(13);
  if (bytes.length > MAX_MESSAGE || HEADER_BYTES + declared > MAX_MESSAGE) return { error: 'too_large' };
  if (bytes.length - HEADER_BYTES !== declared) return { error: 'length_mismatch' };
  const bodyBytes = bytes.subarray(HEADER_BYTES);
  return { type: entry[0], keyframe: (bytes[4] & 1) === 1, timestamp: bytes.readBigUInt64BE(5).toString(), body: bodyBytes.toString('hex'), bodyBytes };
}

/** frame = { type, keyframe, timestamp（10 進数の文字列または BigInt）, body（Buffer） } */
function referenceEncode(frame) {
  const header = Buffer.alloc(HEADER_BYTES);
  header[0] = 0x42;
  header[1] = 0x4c;
  header[2] = 1;
  header[3] = CODE_OF[frame.type];
  header[4] = frame.keyframe ? 1 : 0;
  header.writeBigUInt64BE(BigInt(frame.timestamp === undefined ? 0 : frame.timestamp), 5);
  header.writeUInt32BE(frame.body.length, 13);
  return Buffer.concat([header, frame.body]);
}

/** 中継 → ブラウザの制御メッセージ（時刻 0・属性 0）。body は、JSON のオブジェクト（キーの順は、渡した順）、または空（keyframe_request）。 */
function referenceControl(type, body) {
  return referenceEncode({ type, keyframe: false, timestamp: 0, body: body === undefined ? Buffer.alloc(0) : Buffer.from(JSON.stringify(body), 'utf8') });
}

module.exports = { MAX_MESSAGE, HEADER_BYTES, REFERENCE_TYPES, CODE_OF, referenceDecode, referenceEncode, referenceControl };
