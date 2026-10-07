/**
 * @jest-environment node
 */
// 再接続の方針（requirements.md 13.1・13.2）。
//   - 待機間隔は指数的に増やし、上限 5 秒（0.5 -> 1 -> 2 -> 4 -> 5 -> 5 ...）。ジッタは、注入した乱数でのみ。既定は決定的
//   - 配信が終了済み・期限（中断 30 秒）を過ぎた場合は、再接続しない（13.1「再接続の不成立」）。復帰は 1 配信あたり 10 回まで
import { BROADCAST_STATE_VALUES, LIMITS } from "../contract";
import type { BroadcastState } from "../contract";
import { Problems } from "../testing/helpers";
import { ReconnectPolicy } from "./ReconnectPolicy";
import type { ReconnectDecision } from "./ReconnectPolicy";

describe("契約との対応", () => {
  test("待機の上限は 5,000 ms、復帰の上限は 10 回（契約の deadlines）", () => {
    expect(LIMITS.deadlines.reconnect_backoff_cap_ms).toBe(5_000);
    expect(LIMITS.deadlines.max_resumes).toBe(10);
  });
});

describe("ReconnectPolicy.nextDelayMs: 指数的に増やし、上限 5 秒", () => {
  test.each([
    [0, 500],
    [1, 1_000],
    [2, 2_000],
    [3, 4_000],
    [4, 5_000],
    [5, 5_000],
    [6, 5_000],
    [10, 5_000],
    [30, 5_000],
    [31, 5_000],
    [1_023, 5_000],
    [1_024, 5_000],
    [1_000_000, 5_000],
    [Number.MAX_SAFE_INTEGER, 5_000],
  ])("%i 回目の再試行の前の待機は %i ms", (attempt, expected) => {
    expect(new ReconnectPolicy().nextDelayMs(attempt)).toBe(expected);
  });

  test("0.5 -> 1 -> 2 -> 4 -> 5 -> 5 ...（秒）。上限を超えず、減らない", () => {
    const policy = new ReconnectPolicy();
    const delays = Array.from({ length: 12 }, (_, attempt) => policy.nextDelayMs(attempt));
    expect(delays).toEqual([500, 1_000, 2_000, 4_000, 5_000, 5_000, 5_000, 5_000, 5_000, 5_000, 5_000, 5_000]);
  });

  test("既定は決定的（乱数を使わない）：同じ入力に、いつも同じ出力。インスタンスをまたいでも同じ", () => {
    const first = new ReconnectPolicy();
    const second = new ReconnectPolicy();
    for (let attempt = 0; attempt < 10; attempt += 1) {
      expect(first.nextDelayMs(attempt)).toBe(first.nextDelayMs(attempt));
      expect(first.nextDelayMs(attempt)).toBe(second.nextDelayMs(attempt));
    }
  });

  test.each([
    ["負の数", -1],
    ["小数", 1.5],
    ["NaN", Number.NaN],
    ["無限大", Number.POSITIVE_INFINITY],
    ["安全整数を超える値", Number.MAX_SAFE_INTEGER + 2],
  ])("不正な回数（%s）は RangeError", (_label, attempt) => {
    expect(() => new ReconnectPolicy().nextDelayMs(attempt)).toThrow(RangeError);
  });
});

describe("ReconnectPolicy.nextDelayMs: ジッタ（注入した乱数でのみ。待機を最大 20% 短くし、上限を超えない）", () => {
  test.each([
    [0, 0, 500],
    [0, 0.5, 450],
    [0, 0.999999, 400],
    [1, 0.5, 900],
    [3, 0.25, 3_800],
    [4, 0, 5_000],
    [4, 0.5, 4_500],
    [9, 0.999999, 4_000],
  ])("%i 回目・乱数 %f -> %i ms", (attempt, randomValue, expected) => {
    const policy = new ReconnectPolicy({ random: () => randomValue });
    expect(policy.nextDelayMs(attempt)).toBe(expected);
  });

  test("乱数が 0 のとき、ジッタ無しと同じ。ジッタを入れても、上限（5,000 ms）を超えず、基準の 80% を下回らない", () => {
    const plain = new ReconnectPolicy();
    const none = new ReconnectPolicy({ random: () => 0 });
    const problems = new Problems();
    let step = 0;
    const stepping = new ReconnectPolicy({
      random: () => {
        step += 1;
        return (step % 997) / 997;
      },
    });
    for (let attempt = 0; attempt < 200; attempt += 1) {
      const base = plain.nextDelayMs(attempt);
      if (none.nextDelayMs(attempt) !== base) {
        problems.report(`random 0 differs from no jitter at ${attempt}`);
      }
      const jittered = stepping.nextDelayMs(attempt);
      if (!Number.isInteger(jittered) || jittered > 5_000 || jittered > base || jittered < base * 0.8 - 0.5) {
        problems.report(`attempt ${attempt}: ${jittered} out of range for base ${base}`);
      }
    }
    expect(problems.list()).toEqual([]);
  });

  test("乱数は、呼び出しのたびに 1 回だけ引く（回数が決まっているので、注入した列を再現できる）", () => {
    const drawn: number[] = [];
    const policy = new ReconnectPolicy({
      random: () => {
        drawn.push(drawn.length / 10);
        return drawn[drawn.length - 1];
      },
    });
    policy.nextDelayMs(0);
    policy.nextDelayMs(1);
    expect(drawn).toEqual([0, 0.1]);
  });

  test.each([
    ["1", 1],
    ["負の数", -0.1],
    ["NaN", Number.NaN],
    ["2", 2],
    ["無限大", Number.POSITIVE_INFINITY],
  ])("注入した乱数が [0, 1) の外の値（%s）を返したら、握りつぶさず RangeError", (_label, value) => {
    const policy = new ReconnectPolicy({ random: () => value });
    expect(() => policy.nextDelayMs(2)).toThrow(RangeError);
  });
});

describe("ReconnectPolicy.shouldReconnect: 再接続の可否（配信が終了済み・期限を過ぎた・復帰の上限）", () => {
  const policy = new ReconnectPolicy();

  test.each<[BroadcastState, boolean, number, Partial<ReconnectDecision>]>([
    // 状態, resumable, 復帰済みの回数, 期待
    ["interrupted", true, 0, { reconnect: true, reason: "resumable", resumesRemaining: 10, maxResumes: 10 }],
    ["live", true, 0, { reconnect: true, reason: "resumable", resumesRemaining: 10 }],
    ["confirming", true, 0, { reconnect: true, reason: "resumable" }],
    ["awaiting_media", true, 0, { reconnect: true, reason: "resumable" }],
    ["interrupted", true, 3, { reconnect: true, reason: "resumable", resumesRemaining: 7 }],
    ["interrupted", true, 9, { reconnect: true, reason: "resumable", resumesRemaining: 1 }],
    // 期限（中断 30 秒）を過ぎた（サーバーが resumable でないと言う）
    ["interrupted", false, 0, { reconnect: false, reason: "not_resumable", resumesRemaining: 10 }],
    ["live", false, 0, { reconnect: false, reason: "not_resumable" }],
    ["confirming", false, 2, { reconnect: false, reason: "not_resumable", resumesRemaining: 8 }],
    ["awaiting_media", false, 0, { reconnect: false, reason: "not_resumable" }],
    // 受理済みは、まだ再接続の対象ではない（接続チケットは送出待ち・確定待ち・ライブ・中断のときだけ発行される）
    ["reserved", false, 0, { reconnect: false, reason: "not_resumable" }],
    ["reserved", true, 0, { reconnect: false, reason: "not_resumable" }],
    // 配信が終了済み（resumable がどうあれ、再接続しない）
    ["ended", false, 0, { reconnect: false, reason: "broadcast_ended", resumesRemaining: 10 }],
    ["ended", true, 0, { reconnect: false, reason: "broadcast_ended" }],
    ["ended", false, 4, { reconnect: false, reason: "broadcast_ended", resumesRemaining: 6 }],
    // 復帰の上限（10 回）：10 回復帰済みなら、次の中断では復帰しない
    ["interrupted", true, 10, { reconnect: false, reason: "resume_limit_reached", resumesRemaining: 0, maxResumes: 10 }],
    ["interrupted", true, 11, { reconnect: false, reason: "resume_limit_reached", resumesRemaining: 0 }],
    ["live", true, 1_000, { reconnect: false, reason: "resume_limit_reached", resumesRemaining: 0 }],
  ])("%s・resumable=%s・復帰済み %i 回 -> %j", (state, resumable, resumesCompleted, expected) => {
    expect(policy.shouldReconnect({ state, resumable }, resumesCompleted)).toMatchObject(expected);
  });

  test("判定の優先順位：終了済み > 復帰できない（期限切れ・受理済み） > 復帰の上限 > 再接続する", () => {
    expect(policy.shouldReconnect({ state: "ended", resumable: true }, 10).reason).toBe("broadcast_ended");
    expect(policy.shouldReconnect({ state: "interrupted", resumable: false }, 10).reason).toBe("not_resumable");
    expect(policy.shouldReconnect({ state: "interrupted", resumable: true }, 10).reason).toBe("resume_limit_reached");
    expect(policy.shouldReconnect({ state: "interrupted", resumable: true }, 9).reason).toBe("resumable");
  });

  test("復帰済みの回数を省くと 0（残り 10 回）", () => {
    expect(policy.shouldReconnect({ state: "interrupted", resumable: true })).toMatchObject({ reconnect: true, resumesRemaining: 10 });
  });

  test("全 6 状態 × resumable の 2 通りを、表と同じ規則で検査する（再接続するのは、復帰できる 4 状態で resumable のときだけ）", () => {
    const resumableStates = new Set<BroadcastState>(["awaiting_media", "confirming", "live", "interrupted"]);
    const mismatches: string[] = [];
    for (const state of BROADCAST_STATE_VALUES) {
      for (const resumable of [true, false]) {
        const expected = resumableStates.has(state) && resumable;
        if (policy.shouldReconnect({ state, resumable }, 0).reconnect !== expected) {
          mismatches.push(`${state} resumable=${String(resumable)}`);
        }
      }
    }
    expect(mismatches).toEqual([]);
    expect(BROADCAST_STATE_VALUES).toHaveLength(6);
  });

  test("判定は変更できない（凍結されている）。入力を変更しない", () => {
    const view = Object.freeze({ state: "live", resumable: true } as const);
    const decision = policy.shouldReconnect(view, 2);
    expect(Object.isFrozen(decision)).toBe(true);
    expect(view).toEqual({ state: "live", resumable: true });
  });

  test.each([
    ["未知の状態", { state: "paused", resumable: true }, 0],
    ["状態が無い", { resumable: true }, 0],
    ["resumable が真偽値でない", { state: "live", resumable: "true" }, 0],
    ["resumable が無い", { state: "live" }, 0],
    ["復帰済みの回数が負", { state: "live", resumable: true }, -1],
    ["復帰済みの回数が小数", { state: "live", resumable: true }, 1.5],
    ["復帰済みの回数が NaN", { state: "live", resumable: true }, Number.NaN],
  ])("不正な入力（%s）は、再接続するかどうかを推測せず RangeError", (_label, view, resumesCompleted) => {
    expect(() => policy.shouldReconnect(view as never, resumesCompleted)).toThrow(RangeError);
  });
});
