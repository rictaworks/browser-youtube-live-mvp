/**
 * @jest-environment node
 */
// 回線計測の送信ペース（requirements.md 11.8、ws-protocol.md の 5.2）：3 秒間、最大 6,000 kbps 相当の計測データを、32 KB 程度のメッセージで送る。
// ペースの計算は、純粋な関数（時計・タイマを持たない）：メッセージ i（0 始まり）は、それまでの送信量（自分を含む）が、最大レートで送れる量に達する
// 時刻（切り上げ）に送る。つまり、どの時刻までの累計も、最大レート x 時刻 を超えない（バーストしない）。送信は、窓（3 秒）の中だけ。
import { LIMITS } from "../contract";
import { planProbeSends } from "./probePlan";
import type { ProbePlanOptions } from "./probePlan";

const HEADER_BYTES = LIMITS.ws_frame.header_bytes;

const DEFAULTS: ProbePlanOptions = {
  durationMs: LIMITS.line_probe.duration_seconds * 1000,
  maxRateKbps: LIMITS.line_probe.max_rate_kbps,
  bodyBytes: LIMITS.line_probe.message_bytes_hint,
  headerBytes: HEADER_BYTES,
};

describe("契約との対応", () => {
  test("計測は 3 秒間・最大 6,000 kbps・1 メッセージ 32 KB 程度（契約の line_probe）。ヘッダは 17 バイト", () => {
    expect(LIMITS.line_probe.duration_seconds).toBe(3);
    expect(LIMITS.line_probe.max_rate_kbps).toBe(6000);
    expect(LIMITS.line_probe.message_bytes_hint).toBe(32_768);
    expect(HEADER_BYTES).toBe(17);
  });
});

describe("planProbeSends: 既定の契約の値（3 秒・6,000 kbps・本文 32,768 バイト + ヘッダ 17 バイト）", () => {
  const plan = planProbeSends(DEFAULTS);

  test("メッセージ全体は 32,785 バイト。3 秒の窓に、68 メッセージ（69 つ目は、3 秒を過ぎる）", () => {
    expect(plan).toHaveLength(68);
    // 32,785 バイト = 262,280 ビット。6,000 kbps（= 6,000 ビット / ms）では、1 メッセージあたり 43.71 ms
    expect(plan[0]).toEqual({ index: 0, offsetMs: 44, bodyBytes: 32_768 });
    expect(plan[1].offsetMs).toBe(88);
    expect(plan[2].offsetMs).toBe(132);
    expect(plan[67].offsetMs).toBe(2973);
  });

  test("送信の時刻（窓の開始からのミリ秒）は、増え続け、すべて窓（0 以上 3,000 未満）の中", () => {
    for (let index = 1; index < plan.length; index += 1) {
      expect(plan[index].offsetMs).toBeGreaterThan(plan[index - 1].offsetMs);
    }
    expect(plan.every((send) => send.offsetMs >= 0 && send.offsetMs < 3000)).toBe(true);
    expect(plan.map((send) => send.index)).toEqual(Array.from({ length: 68 }, (_, index) => index));
  });

  test("どの時刻までの累計も、最大レート（6,000 kbps）を超えない（バーストしない。メッセージ全体のバイト数で数える）", () => {
    const wire = DEFAULTS.bodyBytes + HEADER_BYTES;
    for (const send of plan) {
      const sentBits = (send.index + 1) * wire * 8;
      // 1 kbps = 1,000 ビット / 秒 = 1 ビット / ms
      expect(sentBits / send.offsetMs).toBeLessThanOrEqual(DEFAULTS.maxRateKbps);
    }
  });

  test("3 秒間の平均は、5,900 kbps 以上 6,000 kbps 以下（最大レート相当で、ほぼ使い切る）。720p の閾値（4,100 kbps）より十分に大きい", () => {
    const totalBits = plan.length * (DEFAULTS.bodyBytes + HEADER_BYTES) * 8;
    const averageKbps = totalBits / 3000;
    expect(averageKbps).toBeGreaterThanOrEqual(5900);
    expect(averageKbps).toBeLessThanOrEqual(6000);
    expect(averageKbps).toBeGreaterThan(LIMITS.profiles["720p"].line_threshold_kbps);
  });

  test("決定的：同じ入力に、同じ計画（毎回、新しい配列）", () => {
    const again = planProbeSends(DEFAULTS);
    expect(again).toEqual(plan);
    expect(again).not.toBe(plan);
  });
});

describe("planProbeSends: 数の表（境界・端数）", () => {
  // [窓 ms, レート kbps, 本文バイト, ヘッダバイト, 期待する数, 最初の時刻, 最後の時刻]
  const table: ReadonlyArray<readonly [number, number, number, number, number, number, number]> = [
    // 1 メッセージ 1,000 ビット（本文 108 + ヘッダ 17 = 125 バイト）を、1,000 kbps で。ちょうど 1 ms ごと。窓 10 ms：offset 1 から 9 の 9 メッセージ（ちょうど窓の終わり 10 は、窓の外）
    [10, 1000, 108, 17, 9, 1, 9],
    // 端数は切り上げ：375 バイトのメッセージ（3,000 ビット）を、2,000 kbps で。1.5 ms ごと -> 2, 3, 5, 6, 8, 9（窓 10 ms の中）
    [10, 2000, 358, 17, 6, 2, 9],
    // レートが低い：窓の中に 1 つも送れない（最初の時刻が、窓を超える）
    [10, 1, 1000, 17, 0, 0, 0],
    // 窓が 1 ms：offset が 1 以上なので、窓の中（1 未満）に入らない
    [1, 1000, 108, 17, 0, 0, 0],
    // 窓が 2 ms：offset 1 だけ
    [2, 1000, 108, 17, 1, 1, 1],
  ];

  test.each(table)("窓 %i ms・%i kbps・本文 %i バイト + ヘッダ %i バイト -> %i メッセージ（最初 %i ms・最後 %i ms）", (durationMs, maxRateKbps, bodyBytes, headerBytes, count, first, last) => {
    const plan = planProbeSends({ durationMs, maxRateKbps, bodyBytes, headerBytes });
    expect(plan).toHaveLength(count);
    if (count > 0) {
      expect(plan[0].offsetMs).toBe(first);
      expect(plan[plan.length - 1].offsetMs).toBe(last);
    }
  });

  test("端数の切り上げ：375 バイトのメッセージ（3,000 ビット）を 2,000 kbps で送ると、1.5 ms 間隔を切り上げた時刻（2, 3, 5, 6, 8, 9）", () => {
    const plan = planProbeSends({ durationMs: 10, maxRateKbps: 2000, bodyBytes: 358, headerBytes: 17 });
    expect(plan.map((send) => send.offsetMs)).toEqual([2, 3, 5, 6, 8, 9]);
  });

  test("計画の長さは、レート・窓に比例し、1 メッセージが大きいほど少ない（性質）", () => {
    const small = planProbeSends({ ...DEFAULTS, bodyBytes: 1024 });
    const large = planProbeSends({ ...DEFAULTS, bodyBytes: 65_536 });
    expect(small.length).toBeGreaterThan(planProbeSends(DEFAULTS).length);
    expect(large.length).toBeLessThan(planProbeSends(DEFAULTS).length);
    const slow = planProbeSends({ ...DEFAULTS, maxRateKbps: 3000 });
    expect(slow.length).toBeLessThan(planProbeSends(DEFAULTS).length);
  });
});

describe("planProbeSends: 不正な入力は RangeError", () => {
  test.each([
    ["窓が 0", { durationMs: 0 }],
    ["窓が負", { durationMs: -1 }],
    ["窓が小数", { durationMs: 3000.5 }],
    ["窓が NaN", { durationMs: Number.NaN }],
    ["レートが 0", { maxRateKbps: 0 }],
    ["レートが小数", { maxRateKbps: 6000.5 }],
    ["レートが無限大", { maxRateKbps: Number.POSITIVE_INFINITY }],
    ["本文が 0 バイト", { bodyBytes: 0 }],
    ["本文が小数", { bodyBytes: 100.5 }],
    ["ヘッダが負", { headerBytes: -1 }],
    ["メッセージ全体が、上限（2,097,152 バイト）を超える", { bodyBytes: LIMITS.ws_frame.max_message_bytes - HEADER_BYTES + 1 }],
  ])("%s", (_label, override) => {
    expect(() => planProbeSends({ ...DEFAULTS, ...override })).toThrow(RangeError);
  });

  test("メッセージ全体がちょうど上限（2,097,152 バイト）は正しい", () => {
    expect(() => planProbeSends({ ...DEFAULTS, bodyBytes: LIMITS.ws_frame.max_message_bytes - HEADER_BYTES })).not.toThrow();
  });
});
