// base64（RFC 4648 の標準の文字集合・パディングあり）。ws-protocol.md の 5.3 の description_b64（復号器設定）の符号化・復号。
//   - 環境の関数（btoa・atob・Buffer）に頼らない（Domain Core は環境から独立。どの環境でも同じ結果）
//   - 復号は厳密：長さが 4 の倍数、標準の文字集合だけ、パディング（=）は末尾の組の最後に 0 から 2 個、末尾の余りのビットは 0（正規形）。
//     そのため、復号して再び符号化すると、元の文字列に戻る。不正な入力は、推測して復号せず RangeError

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const PADDING = "=";
const INVALID = -1;
const ASCII_LIMIT = 128;

/** 文字コード（0 から 127）から、6 ビットの値への表。文字集合に無い文字は INVALID。 */
function buildDecodeTable(): Int8Array {
  const table = new Int8Array(ASCII_LIMIT).fill(INVALID);
  for (let value = 0; value < ALPHABET.length; value += 1) {
    table[ALPHABET.charCodeAt(value)] = value;
  }
  return table;
}

const DECODE_TABLE = buildDecodeTable();

/** バイト列を、base64（標準の文字集合・パディングあり）の文字列にする。入力は変更しない。 */
export function encodeBase64(bytes: Uint8Array): string {
  const length = bytes.length;
  let output = "";
  let index = 0;
  for (; index + 3 <= length; index += 3) {
    const group = (bytes[index] << 16) | (bytes[index + 1] << 8) | bytes[index + 2];
    output += ALPHABET[(group >> 18) & 63] + ALPHABET[(group >> 12) & 63] + ALPHABET[(group >> 6) & 63] + ALPHABET[group & 63];
  }
  const remaining = length - index;
  if (remaining === 1) {
    const group = bytes[index] << 16;
    output += ALPHABET[(group >> 18) & 63] + ALPHABET[(group >> 12) & 63] + PADDING + PADDING;
  } else if (remaining === 2) {
    const group = (bytes[index] << 16) | (bytes[index + 1] << 8);
    output += ALPHABET[(group >> 18) & 63] + ALPHABET[(group >> 12) & 63] + ALPHABET[(group >> 6) & 63] + PADDING;
  }
  return output;
}

function sixBitValueAt(text: string, index: number): number {
  const code = text.charCodeAt(index);
  const value = code < ASCII_LIMIT ? DECODE_TABLE[code] : INVALID;
  if (value === INVALID) {
    throw new RangeError(`invalid base64 character (code ${code}) at index ${index}`);
  }
  return value;
}

/** 末尾の組のパディングの数（0 から 2）。 */
function countPadding(text: string): number {
  if (text.charAt(text.length - 1) !== PADDING) {
    return 0;
  }
  return text.charAt(text.length - 2) === PADDING ? 2 : 1;
}

/**
 * base64 の文字列を、バイト列にする（新しいバイト列を返す）。空の文字列は、空のバイト列。
 * 正規形だけを受理する（長さが 4 の倍数でない・文字集合の外・パディングの位置や数の誤り・末尾の余りのビットが 0 でない、は RangeError）。
 */
export function decodeBase64(text: string): Uint8Array {
  if (typeof text !== "string") {
    throw new RangeError(`base64 input must be a string: ${typeof text}`);
  }
  const length = text.length;
  if (length % 4 !== 0) {
    throw new RangeError(`base64 length must be a multiple of 4: ${length}`);
  }
  const padding = countPadding(text);
  const output = new Uint8Array((length / 4) * 3 - padding);
  let written = 0;
  for (let position = 0; position < length; position += 4) {
    const isLastGroup = position + 4 === length;
    const dataChars = isLastGroup ? 4 - padding : 4;
    let group = 0;
    for (let offset = 0; offset < 4; offset += 1) {
      const value = offset < dataChars ? sixBitValueAt(text, position + offset) : 0;
      group = (group << 6) | value;
    }
    // 末尾の余りのビット（バイトにならない下位のビット）は 0 でなければならない（正規形）
    const leftoverBitsMask = padding === 2 ? 0xffff : padding === 1 ? 0xff : 0;
    if (isLastGroup && (group & leftoverBitsMask) !== 0) {
      throw new RangeError("base64 trailing bits must be zero");
    }
    const bytesInGroup = isLastGroup ? 3 - padding : 3;
    for (let byteIndex = 0; byteIndex < bytesInGroup; byteIndex += 1) {
      output[written] = (group >> (16 - 8 * byteIndex)) & 255;
      written += 1;
    }
  }
  return output;
}
