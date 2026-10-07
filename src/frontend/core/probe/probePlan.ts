// 回線計測の送信ペース（requirements.md 11.8、ws-protocol.md の 5.2）：3 秒間、最大 6,000 kbps 相当で、32 KB 程度の計測データを送る。
// 純粋な関数（時計・タイマを持たない）。メッセージ i（0 始まり）を送る時刻（窓の開始からのミリ秒）は、
//   offset(i) = ceil((i + 1) x メッセージ全体のビット数 / 最大レート(kbps))        （1 kbps = 1,000 ビット / 秒 = 1 ビット / ms）
// つまり、メッセージを送る時刻までに送った量（自分を含む）が、最大レートで送れる量に、ちょうど（切り上げ）追いつく時刻。
// どの時刻までの累計も、最大レート x 時刻 を超えない（バーストしない）。メッセージ全体は、本文 + ヘッダ（中継は、ヘッダを含めて数える。契約の 5.2）。
// 送るのは、offset が窓（durationMs）より前のものだけ。

import { LIMITS } from "../contract";

export interface ProbePlanOptions {
  /** 計測の長さ（ミリ秒）。正の整数 */
  readonly durationMs: number;
  /** 最大の送信レート（kbps）。正の整数 */
  readonly maxRateKbps: number;
  /** 計測データ（フレームの本文）の大きさ（バイト）。正の整数 */
  readonly bodyBytes: number;
  /** フレームのヘッダの大きさ（バイト）。0 以上の整数 */
  readonly headerBytes: number;
}

export interface ProbeSend {
  /** 何番目か（0 始まり） */
  readonly index: number;
  /** 窓の開始からの時刻（ミリ秒） */
  readonly offsetMs: number;
  /** 本文の大きさ（バイト） */
  readonly bodyBytes: number;
}

const BITS_PER_BYTE = 8;
/** 計画の長さの上限（設定の誤りで、巨大な配列を作らない）。 */
const MAX_PLANNED_MESSAGES = 100_000;

function assertSafeInteger(value: number, name: string, minimum: number): void {
  if (!Number.isSafeInteger(value) || value < minimum) {
    throw new RangeError(`${name} must be a safe integer of at least ${minimum}: ${String(value)}`);
  }
}

/** 送信の計画（時刻の順）を作る。不正な入力は RangeError。呼ぶたびに、新しい配列を返す。 */
export function planProbeSends(options: ProbePlanOptions): ProbeSend[] {
  assertSafeInteger(options.durationMs, "durationMs", 1);
  assertSafeInteger(options.maxRateKbps, "maxRateKbps", 1);
  assertSafeInteger(options.bodyBytes, "bodyBytes", 1);
  assertSafeInteger(options.headerBytes, "headerBytes", 0);
  const wireBytes = options.bodyBytes + options.headerBytes;
  if (wireBytes > LIMITS.ws_frame.max_message_bytes) {
    throw new RangeError(`a probe message of ${wireBytes} bytes exceeds the limit of ${LIMITS.ws_frame.max_message_bytes} bytes`);
  }

  const wireBits = wireBytes * BITS_PER_BYTE;
  const plan: ProbeSend[] = [];
  for (let index = 0; ; index += 1) {
    const offsetMs = Math.ceil(((index + 1) * wireBits) / options.maxRateKbps);
    if (offsetMs >= options.durationMs) {
      return plan;
    }
    if (plan.length >= MAX_PLANNED_MESSAGES) {
      throw new RangeError(`the probe plan would have more than ${MAX_PLANNED_MESSAGES} messages`);
    }
    plan.push({ index, offsetMs, bodyBytes: options.bodyBytes });
  }
}
