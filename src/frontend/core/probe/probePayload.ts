// 計測データの中身（ws-protocol.md の 3 章：任意のバイト列）。
// 経路の途中で圧縮されることがある（WebSocket の permessage-deflate など）と、実際の回線より速く測れてしまう。そのため、0 の並びや、
// 同じ内容の繰り返しにせず、決定的な擬似乱数（xorshift32。種は、注入する）で、毎回、違う内容を作る。実時計・Math.random を使わない。

const MAX_SEED = 0xffffffff;
const BYTES_PER_WORD = 4;

/** xorshift32 の 1 歩。状態は、0 でない 32 ビットの符号なし整数。 */
function nextState(state: number): number {
  let value = state;
  value ^= value << 13;
  value ^= value >>> 17;
  value ^= value << 5;
  return value >>> 0;
}

/** 種の検査：1 以上 2^32 - 1 以下の整数（0 だと、擬似乱数が、0 のまま動かなくなる）。不正なら RangeError。 */
export function assertProbeSeed(seed: number): void {
  if (!Number.isInteger(seed) || seed < 1 || seed > MAX_SEED) {
    throw new RangeError(`seed must be an integer from 1 to ${MAX_SEED}: ${String(seed)}`);
  }
}

export class ProbePayloadGenerator {
  private state: number;

  /** seed は、1 以上 2^32 - 1 以下の整数。同じ種からは、同じ列。 */
  constructor(seed: number) {
    assertProbeSeed(seed);
    this.state = seed >>> 0;
  }

  /** length バイトの、擬似乱数のバイト列を、新しい配列で返す。続けて呼ぶと、続きの列になる（毎回、違う内容）。 */
  next(length: number): Uint8Array {
    if (!Number.isSafeInteger(length) || length < 0) {
      throw new RangeError(`length must be a non-negative safe integer: ${String(length)}`);
    }
    const bytes = new Uint8Array(length);
    let position = 0;
    while (position < length) {
      this.state = nextState(this.state);
      let word = this.state;
      for (let byteIndex = 0; byteIndex < BYTES_PER_WORD && position < length; byteIndex += 1) {
        bytes[position] = word & 0xff;
        word >>>= 8;
        position += 1;
      }
    }
    return bytes;
  }
}
