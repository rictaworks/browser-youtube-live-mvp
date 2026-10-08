/**
 * @jest-environment node
 */
// BitrateGovernor（requirements.md 12 章「適応制御要件」・15 章・23.3・24.1）：滞留時間を毎秒評価し、目標ビットレートと破棄方針を決める。
//
// 12 章の 7 条件を、1 行ずつ、境界（ちょうど・直前・直後）を表形式で検査する。
//   1. 滞留時間が 1.5 秒を超える評価が 2 回連続 -> 目標ビットレートを 30% 引き下げる（下限まで）
//   2. 滞留時間が 0.3 秒未満、かつ直近 10 秒に破棄がない -> 10% 引き上げる（上限まで）
//   3. 滞留時間が 4 秒を超える -> 送信待ちの映像をすべて破棄し、直ちにキーフレームを発行する
//   4. 映像の受領済み時刻が 10 秒間進まない -> 接続不良として再接続へ移る
//   5. 滞留時間が 8 秒を超える状態が 10 秒継続 -> 接続不良として再接続へ移る
//   6. 下限に達したうえで、逼迫（滞留時間 1.5 秒超）が 20 秒継続 -> 「劣化」
//   7. 劣化の状態で、滞留時間 1.5 秒以下が 10 秒継続 -> 劣化を解除する
// 要件：目標の変更は 1 秒あたり 1 回まで／引き下げ幅（30%）より引き上げ幅（10%）が小さい／中継の抑制指示は、ブラウザ側の判定より優先する
//
// 時刻は、メディアクロック由来の秒（実時計を使わない）。「N 秒継続」は、条件が最初に成り立った評価の時刻から、N 秒以上経った評価で成立する（>=）。
// 「直近 10 秒の破棄」は、(現在 - 10 秒, 現在] の破棄（ちょうど 10 秒前の破棄は、含まない）。
import { ADAPTIVE_CONDITION_VALUES, LIMITS } from "../contract";
import type { AdaptiveCondition } from "../contract";
import { Problems, seededRandom } from "../testing/helpers";
import { BitrateGovernor } from "./BitrateGovernor";
import type { GovernorDecision, GovernorInput } from "./types";

const MIN = 3000;
const MAX = 6000;
const US = 1_000_000;

interface RunOptions {
  readonly target?: number;
  readonly min?: number;
  readonly max?: number;
  readonly degraded?: boolean;
}

/** 閉じた輪：結果の目標・劣化の状態を、次の入力へ引き継ぐ。 */
class Run {
  readonly governor = new BitrateGovernor();
  readonly decisions: GovernorDecision[] = [];
  target: number;
  degraded: boolean;
  private clock = 0;
  readonly min: number;
  readonly max: number;

  constructor(options: RunOptions = {}) {
    this.target = options.target ?? 4500;
    this.min = options.min ?? MIN;
    this.max = options.max ?? MAX;
    this.degraded = options.degraded ?? false;
  }

  /** 時刻を指定して、1 回評価する。既定の滞留時間は 100 ms（健全）。 */
  at(nowSec: number, overrides: Partial<GovernorInput> = {}): GovernorDecision {
    const input: GovernorInput = {
      nowSec,
      backlogMs: 100,
      dropTimesSec: [],
      targetKbps: this.target,
      minKbps: this.min,
      maxKbps: this.max,
      // 既定の受領済みの映像の時刻は、メディア時刻（秒）に合わせて進む（条件 4 の検査は、overrides で止める）
      ackedVideoUs: Math.round((nowSec + 1) * US),
      degraded: this.degraded,
      ...overrides,
    };
    const decision = this.governor.evaluate(input);
    if (!decision.ignored) {
      this.target = decision.targetKbps;
      this.degraded = decision.degraded;
    }
    this.decisions.push(decision);
    this.clock = nowSec + 1;
    return decision;
  }

  /** 前回の 1 秒後に評価する。 */
  tick(overrides: Partial<GovernorInput> = {}): GovernorDecision {
    return this.at(this.clock, overrides);
  }

  /** 滞留時間の列を、1 秒ごとに評価し、結果を返す。 */
  ticks(backlogs: ReadonlyArray<number | undefined>, overrides: Partial<GovernorInput> = {}): GovernorDecision[] {
    return backlogs.map((backlogMs) => this.tick({ backlogMs, ...overrides }));
  }
}

const targetsOf = (decisions: readonly GovernorDecision[]): number[] => decisions.map((decision) => decision.targetKbps);
const down = (fromKbps: number, toKbps: number) => ({ kind: "bitrate_down", fromKbps, toKbps }) as const;
const up = (fromKbps: number, toKbps: number) => ({ kind: "bitrate_up", fromKbps, toKbps }) as const;

describe("契約との対応（12 章の表の数値が、契約の limits.json と一致する）", () => {
  test("7 条件の閾値・継続時間・変更の割合は、12 章の表のとおり", () => {
    const conditions = LIMITS.adaptive.conditions;
    expect(conditions.backlog_high_twice).toEqual({ backlog_over_ms: 1500, consecutive_evaluations: 2, decrease_percent: 30 });
    expect(conditions.backlog_low_no_drop).toEqual({ backlog_under_ms: 300, no_drop_window_seconds: 10, increase_percent: 10 });
    expect(conditions.backlog_critical).toEqual({ backlog_over_ms: 4000 });
    expect(conditions.video_ack_stalled).toEqual({ stalled_seconds: 10 });
    expect(conditions.backlog_severe_sustained).toEqual({ backlog_over_ms: 8000, duration_seconds: 10 });
    expect(conditions.degraded_enter).toEqual({ backlog_over_ms: 1500, duration_seconds: 20 });
    expect(conditions.degraded_exit).toEqual({ backlog_at_most_ms: 1500, duration_seconds: 10 });
    expect(LIMITS.adaptive.evaluation_interval_ms).toBe(1000);
    expect(LIMITS.adaptive.target_change_min_interval_ms).toBe(1000);
  });

  test("引き上げ幅（10%）は、引き下げ幅（30%）より小さい（回復は、引き下げより緩やか）", () => {
    expect(LIMITS.adaptive.conditions.backlog_low_no_drop.increase_percent).toBeLessThan(LIMITS.adaptive.conditions.backlog_high_twice.decrease_percent);
  });
});

describe("条件 1（backlog_high_twice）：滞留時間が 1.5 秒を超える評価が 2 回連続で、目標を 30% 引き下げる（下限まで）", () => {
  // [題, 滞留時間の列（1 秒ごと）, 各評価のあとの目標]
  const table: ReadonlyArray<readonly [string, ReadonlyArray<number | undefined>, readonly number[]]> = [
    ["ちょうど 1,500 ms は、超えない", [1500, 1500, 1500, 1500], [4500, 4500, 4500, 4500]],
    ["1 回だけ超える（連続していない）", [1501], [4500]],
    ["2 回連続で超える：2 回目に引き下げる（4,500 -> 3,150）", [1501, 1501], [4500, 3150]],
    ["1 つ目が超え、2 つ目がちょうど 1,500 ms：連続しない", [1501, 1500, 1501], [4500, 4500, 4500]],
    ["間に、超えない評価（1,000 ms）が入ると、数え直す", [1501, 1000, 1501, 1501], [4500, 4500, 4500, 3150]],
    ["1,500.001 ms（1 マイクロ秒だけ超える）が 2 回連続", [1500.001, 1500.001], [4500, 3150]],
    ["引き下げのあとは、数え直す。2 回ごとに引き下げる（3,150 -> 2,205 は下限 3,000 で止まる）", [1501, 1501, 1501, 1501], [4500, 3150, 3150, 3000]],
    ["下限に達したあとは、引き下げない（変化なし）", [1501, 1501, 1501, 1501, 1501, 1501], [4500, 3150, 3150, 3000, 3000, 3000]],
    ["滞留時間を評価できない（undefined）評価は、数えず、数え直しもしない（状態を保つ）", [1501, undefined, 1501], [4500, 4500, 3150]],
    ["とても大きい滞留時間でも、引き下げは 1 回あたり 30%", [100_000, 100_000], [4500, 3150]],
  ];

  test.each(table)("%s", (_label, backlogs, expectedTargets) => {
    const run = new Run();
    expect(targetsOf(run.ticks(backlogs))).toEqual([...expectedTargets]);
  });

  test("引き下げた評価だけに、bitrate_down の出来事（引き下げ前・後の目標）と、条件 1 が出る", () => {
    const run = new Run();
    const decisions = run.ticks([1501, 1501, 1501, 1501]);
    expect(decisions.map((decision) => decision.events.filter((event) => event.kind === "bitrate_down"))).toEqual([[], [down(4500, 3150)], [], [down(3150, 3000)]]);
    expect(decisions.map((decision) => decision.triggered.includes("backlog_high_twice"))).toEqual([false, true, false, true]);
  });

  test("引き下げの端数は、切り捨て（引き下げ幅を、広く取る）。結果は、下限を下回らない", () => {
    // 480p の範囲（800 から 2,500）で、引き下げ前の目標ごとの、引き下げ後の目標
    const rows: ReadonlyArray<readonly [number, number]> = [
      [2500, 1750],
      [2001, 1400],
      [1500, 1050],
      [1143, 800],
      [1142, 800],
      [801, 800],
      [800, 800],
    ];
    for (const [before, expected] of rows) {
      const run = new Run({ target: before, min: 800, max: 2500 });
      run.ticks([2000, 2000]);
      expect({ before, after: run.target }).toEqual({ before, after: expected });
    }
  });

  test("下限にいるとき、引き下げの出来事は出ない（変化がない）が、条件 1 には該当する", () => {
    const run = new Run({ target: MIN });
    const [first, second] = run.ticks([2000, 2000]);
    expect(first.triggered).not.toContain("backlog_high_twice");
    expect(second.targetKbps).toBe(MIN);
    expect(second.events).toEqual([]);
    expect(second.triggered).toContain("backlog_high_twice");
  });
});

describe("条件 2（backlog_low_no_drop）：滞留時間が 0.3 秒未満、かつ直近 10 秒に破棄がないとき、10% 引き上げる（上限まで）", () => {
  // 現在時刻 20 秒。破棄の時刻は、メディアクロック由来の秒
  // [題, 滞留時間, 破棄の時刻, 引き上げるか]
  const table: ReadonlyArray<readonly [string, number, readonly number[], boolean]> = [
    ["0 ms・破棄なし", 0, [], true],
    ["299.999 ms（0.3 秒未満）・破棄なし", 299.999, [], true],
    ["ちょうど 300 ms は、未満ではない", 300, [], false],
    ["300.001 ms", 300.001, [], false],
    ["直近 10 秒の破棄：9.999 秒前（直前）", 100, [10.001], false],
    ["直近 10 秒の破棄：ちょうど 10 秒前は、直近に含めない", 100, [10], true],
    ["直近 10 秒の破棄：10.001 秒前（直後）", 100, [9.999], true],
    ["破棄が、現在と同じ時刻", 100, [20], false],
    ["破棄の時刻が、現在より後（時計の逆行）：直近の破棄として扱う（引き上げない）", 100, [25], false],
    ["古い破棄と、直近の破棄が混在：直近があれば引き上げない", 100, [1, 15], false],
    ["古い破棄だけ（すべて 10 秒より前）：引き上げる", 100, [1, 5, 9], true],
    ["滞留時間が 1.5 秒を超えない中間（300 ms 以上 1,500 ms 以下）：引き上げない", 1000, [], false],
  ];

  test.each(table)("%s", (_label, backlogMs, dropTimesSec, expectIncrease) => {
    const run = new Run();
    const decision = run.at(20, { backlogMs, dropTimesSec });
    expect(decision.targetKbps).toBe(expectIncrease ? 4950 : 4500);
    expect(decision.events).toEqual(expectIncrease ? [up(4500, 4950)] : []);
  });

  test("引き上げは 10%（3,000 -> 3,300 -> 3,630 -> 3,993 -> 4,393 ...）。端数は切り上げ。上限（6,000）で止まる", () => {
    const run = new Run({ target: 3000 });
    const targets = targetsOf(run.ticks(Array.from({ length: 10 }, () => 100)));
    expect(targets).toEqual([3300, 3630, 3993, 4393, 4833, 5317, 5849, 6000, 6000, 6000]);
  });

  test("引き上げの端数は、切り上げ。結果は、上限を超えない（480p の範囲 800 から 2,500）", () => {
    const rows: ReadonlyArray<readonly [number, number]> = [
      [800, 880],
      [801, 882],
      [1500, 1650],
      [2272, 2500],
      [2273, 2500],
      [2499, 2500],
      [2500, 2500],
    ];
    for (const [before, expected] of rows) {
      const run = new Run({ target: before, min: 800, max: 2500 });
      run.tick({ backlogMs: 100 });
      expect({ before, after: run.target }).toEqual({ before, after: expected });
    }
  });

  test("上限にいるとき、引き上げの出来事は出ない（変化がない）が、条件 2 には該当する", () => {
    const run = new Run({ target: MAX });
    const decision = run.tick({ backlogMs: 100 });
    expect(decision.targetKbps).toBe(MAX);
    expect(decision.events).toEqual([]);
    expect(decision.triggered).toContain("backlog_low_no_drop");
  });

  test("引き下げ（30%）と引き上げ（10%）の差：1 回あたりの幅は、引き下げの方が大きい", () => {
    const lowering = new Run({ target: 4500 });
    lowering.ticks([2000, 2000]);
    const raising = new Run({ target: 4500 });
    raising.tick({ backlogMs: 100 });
    expect(4500 - lowering.target).toBeGreaterThan(raising.target - 4500);
  });
});

describe("条件 3（backlog_critical）：滞留時間が 4 秒を超えたら、送信待ちの映像を全破棄し、直ちにキーフレームを発行する", () => {
  test.each([
    ["ちょうど 4,000 ms は、超えない", 4000, false],
    ["4,000.001 ms", 4000.001, true],
    ["4,001 ms", 4001, true],
    ["10 秒", 10_000, true],
    ["3,999.999 ms", 3999.999, false],
  ])("%s", (_label, backlogMs, expected) => {
    const decision = new Run().at(5, { backlogMs });
    expect(decision.discardAllVideo).toBe(expected);
    expect(decision.requestKeyframe).toBe(expected);
    expect(decision.triggered.includes("backlog_critical")).toBe(expected);
    expect(decision.events.some((event) => event.kind === "video_dropped")).toBe(expected);
  });

  test("1 回目の評価から、指示する（2 回連続は要らない）。超えている間は、評価のたびに指示する", () => {
    const run = new Run();
    const decisions = run.ticks([5000, 5000, 5000]);
    expect(decisions.map((decision) => decision.discardAllVideo)).toEqual([true, true, true]);
  });

  test("目標の引き下げ（条件 1）とは独立：1 回目は全破棄だけ、2 回目は全破棄と引き下げの両方", () => {
    const run = new Run();
    const [first, second] = run.ticks([5000, 5000]);
    expect(first.targetKbps).toBe(4500);
    expect(first.discardAllVideo).toBe(true);
    expect(second.targetKbps).toBe(3150);
    expect(second.discardAllVideo).toBe(true);
    expect(second.events).toEqual([down(4500, 3150), { kind: "video_dropped" }]);
  });

  test("全破棄の出来事（video_dropped）は、破棄したフレーム数を持たない（数は、キューが知っている。呼び出し側が補う）", () => {
    const decision = new Run().tick({ backlogMs: 5000 });
    expect(decision.events).toEqual([{ kind: "video_dropped" }]);
  });
});

describe("条件 4（video_ack_stalled）：映像の受領済み時刻が 10 秒間進まなければ、接続不良として再接続へ移る", () => {
  test("受領済みの映像の時刻が、進み続けるあいだは、再接続しない", () => {
    const run = new Run();
    const decisions = Array.from({ length: 60 }, () => run.tick());
    expect(decisions.some((decision) => decision.reconnect)).toBe(false);
  });

  test("進まなくなった最後の評価から、ちょうど 10 秒で再接続（9 秒までは再接続しない）", () => {
    const run = new Run();
    const results = Array.from({ length: 12 }, (_, second) => run.at(second, { ackedVideoUs: 5 * US }));
    // 評価の 0 秒の値が、最後に進んだ時刻の基準。10 秒目（第 11 の評価）で成立する
    expect(results.map((decision) => decision.reconnect)).toEqual([false, false, false, false, false, false, false, false, false, false, true, true]);
    expect(results[10].reconnectCause).toBe("video_ack_stalled");
    expect(results[10].triggered).toContain("video_ack_stalled");
    expect(results[9].reconnectCause).toBeUndefined();
  });

  test("境界：9.999 秒は成立しない／10 秒ちょうどで成立する", () => {
    const run = new Run();
    run.at(0, { ackedVideoUs: US });
    expect(run.at(9.999, { ackedVideoUs: US }).reconnect).toBe(false);
    expect(run.at(10, { ackedVideoUs: US }).reconnect).toBe(true);
  });

  test("受領済みの時刻が、1 マイクロ秒でも進めば、数え直す", () => {
    const run = new Run();
    run.at(0, { ackedVideoUs: US });
    expect(run.at(9, { ackedVideoUs: US + 1 }).reconnect).toBe(false);
    expect(run.at(18.999, { ackedVideoUs: US + 1 }).reconnect).toBe(false);
    expect(run.at(19, { ackedVideoUs: US + 1 }).reconnect).toBe(true);
  });

  test("受領応答を、まだ 1 つも受けていない（undefined）ときも、最初の評価から数える（応答が来ない接続を、放置しない）", () => {
    const run = new Run();
    run.at(0, { ackedVideoUs: undefined });
    expect(run.at(9.999, { ackedVideoUs: undefined }).reconnect).toBe(false);
    expect(run.at(10, { ackedVideoUs: undefined }).reconnect).toBe(true);
  });

  test("最初の受領応答が、遅れて届けば、そこから数え直す", () => {
    const run = new Run();
    run.at(0, { ackedVideoUs: undefined });
    run.at(5, { ackedVideoUs: 4 * US });
    expect(run.at(14.999, { ackedVideoUs: 4 * US }).reconnect).toBe(false);
    expect(run.at(15, { ackedVideoUs: 4 * US }).reconnect).toBe(true);
  });

  test("受領済みの時刻が減っても（中継の側が数え直した）、進んだとは数えない", () => {
    const run = new Run();
    run.at(0, { ackedVideoUs: 8 * US });
    run.at(5, { ackedVideoUs: 2 * US });
    expect(run.at(10, { ackedVideoUs: 2 * US }).reconnect).toBe(true);
  });

  test("滞留時間を評価できなくても（undefined）、条件 4 は評価する", () => {
    const run = new Run();
    run.at(0, { backlogMs: undefined, ackedVideoUs: US });
    expect(run.at(10, { backlogMs: undefined, ackedVideoUs: US }).reconnect).toBe(true);
  });
});

describe("条件 5（backlog_severe_sustained）：滞留時間が 8 秒を超える状態が 10 秒継続したら、接続不良として再接続へ移る", () => {
  test("8,000.001 ms 以上の状態が、最初に成り立った評価から 10 秒続いたとき、再接続（9.999 秒までは再接続しない）", () => {
    const run = new Run();
    const results = [0, 3, 9.999, 10].map((second) => run.at(second, { backlogMs: 8000.001 }));
    expect(results.map((decision) => decision.reconnect)).toEqual([false, false, false, true]);
    expect(results[3].reconnectCause).toBe("backlog_severe_sustained");
    expect(results[3].triggered).toContain("backlog_severe_sustained");
  });

  test("ちょうど 8,000 ms は、超えない（何秒続いても、再接続しない）", () => {
    const run = new Run();
    const results = Array.from({ length: 30 }, () => run.tick({ backlogMs: 8000 }));
    expect(results.some((decision) => decision.reconnect)).toBe(false);
  });

  test("途中で 8 秒以下に戻ると、数え直す", () => {
    const run = new Run();
    run.at(0, { backlogMs: 9000 });
    run.at(5, { backlogMs: 9000 });
    run.at(6, { backlogMs: 8000 });
    expect(run.at(15.999, { backlogMs: 9000 }).reconnect).toBe(false);
    expect(run.at(16, { backlogMs: 9000 }).reconnect).toBe(false);
    expect(run.at(26, { backlogMs: 9000 }).reconnect).toBe(true);
  });

  test("滞留時間を評価できない（undefined）評価は、数えず、数え直しもしない", () => {
    const run = new Run();
    run.at(0, { backlogMs: 9000 });
    run.at(5, { backlogMs: undefined });
    expect(run.at(10, { backlogMs: 9000 }).reconnect).toBe(true);
  });

  test("再接続の指示と同じ評価で、全破棄（条件 3）も指示される（条件は、1 行ずつ独立に評価する）", () => {
    const run = new Run();
    const decision = run.at(0, { backlogMs: 9000 });
    run.at(10, { backlogMs: 9000 });
    expect(decision.discardAllVideo).toBe(true);
    expect(run.decisions[1].reconnect).toBe(true);
    expect(run.decisions[1].discardAllVideo).toBe(true);
  });
});

describe("条件 6（degraded_enter）：下限に達したうえで、逼迫（滞留時間 1.5 秒超）が 20 秒継続したら「劣化」", () => {
  test("下限で、滞留時間 1,500.001 ms 以上が、最初に成り立った評価から 20 秒続いたとき、劣化（19.999 秒までは劣化しない）", () => {
    const run = new Run({ target: MIN });
    // 滞留時間 2,000 ms は、条件 1 を引き起こすが、すでに下限なので、目標は変わらない
    const results = [0, 10, 19.999, 20].map((second) => run.at(second, { backlogMs: 2000 }));
    expect(results.map((decision) => decision.degraded)).toEqual([false, false, false, true]);
    expect(results.map((decision) => decision.degradedChange)).toEqual(["none", "none", "none", "started"]);
    expect(results[3].events).toContainEqual({ kind: "degraded_started" });
    expect(results[3].triggered).toContain("degraded_enter");
    expect(run.degraded).toBe(true);
  });

  test("ちょうど 1,500 ms は、逼迫ではない（何秒続いても、劣化しない）", () => {
    const run = new Run({ target: MIN });
    const results = Array.from({ length: 40 }, () => run.tick({ backlogMs: 1500 }));
    expect(results.some((decision) => decision.degraded)).toBe(false);
  });

  test("下限に達していない間は、数えない。引き下げの結果、下限に達した評価から数える", () => {
    const run = new Run({ target: 3100 });
    // 1 回目：超える（1 回目）。2 回目：超える（2 回連続）-> 3,100 を 30% 下げ、下限 3,000 に達する。この評価から数える（時刻 1 秒）
    const first = run.at(0, { backlogMs: 2000 });
    const second = run.at(1, { backlogMs: 2000 });
    expect(first.targetKbps).toBe(3100);
    expect(second.targetKbps).toBe(3000);
    expect(run.at(20.999, { backlogMs: 2000 }).degraded).toBe(false);
    expect(run.at(21, { backlogMs: 2000 }).degraded).toBe(true);
  });

  test("途中で、逼迫でない（1,500 ms 以下）評価があると、数え直す", () => {
    const run = new Run({ target: MIN });
    run.at(0, { backlogMs: 2000 });
    run.at(10, { backlogMs: 1500 });
    expect(run.at(29.999, { backlogMs: 2000 }).degraded).toBe(false);
    expect(run.at(30, { backlogMs: 2000 }).degraded).toBe(false);
    expect(run.at(50, { backlogMs: 2000 }).degraded).toBe(true);
  });

  test("途中で、下限から外れると（目標が、下限を超える）、数え直す", () => {
    const run = new Run({ target: MIN });
    run.at(0, { backlogMs: 2000 });
    // 滞留時間が健全になり、条件 2 で引き上げる（下限から外れる）
    run.at(12, { backlogMs: 100 });
    expect(run.target).toBeGreaterThan(MIN);
    // 再び逼迫：目標が下限でない間は数えない
    expect(run.at(13, { backlogMs: 2000 }).degraded).toBe(false);
    expect(run.at(40, { backlogMs: 2000 }).degraded).toBe(false);
  });

  test("滞留時間を評価できない（undefined）評価は、数えず、数え直しもしない", () => {
    const run = new Run({ target: MIN });
    run.at(0, { backlogMs: 2000 });
    run.at(10, { backlogMs: undefined });
    expect(run.at(20, { backlogMs: 2000 }).degraded).toBe(true);
  });

  test("すでに劣化している間は、条件 6 を評価しない（出来事 degraded_started を、重ねて出さない）", () => {
    const run = new Run({ target: MIN, degraded: true });
    const results = Array.from({ length: 30 }, () => run.tick({ backlogMs: 2000 }));
    expect(results.some((decision) => decision.events.some((event) => event.kind === "degraded_started"))).toBe(false);
    expect(results.every((decision) => decision.degraded)).toBe(true);
  });
});

describe("条件 7（degraded_exit）：劣化の状態で、滞留時間 1.5 秒以下が 10 秒継続したら、劣化を解除する", () => {
  test("滞留時間 1,500 ms 以下が、最初に成り立った評価から 10 秒続いたとき、解除（9.999 秒までは解除しない）", () => {
    const run = new Run({ target: MIN, degraded: true });
    const results = [0, 5, 9.999, 10].map((second) => run.at(second, { backlogMs: 1500 }));
    expect(results.map((decision) => decision.degraded)).toEqual([true, true, true, false]);
    expect(results.map((decision) => decision.degradedChange)).toEqual(["none", "none", "none", "cleared"]);
    expect(results[3].events).toContainEqual({ kind: "degraded_cleared" });
    expect(results[3].triggered).toContain("degraded_exit");
  });

  test("1,500.001 ms は、1.5 秒以下ではない（何秒続いても、解除しない）", () => {
    const run = new Run({ target: MIN, degraded: true });
    const results = Array.from({ length: 30 }, () => run.tick({ backlogMs: 1500.001 }));
    expect(results.every((decision) => decision.degraded)).toBe(true);
  });

  test("途中で 1.5 秒を超えると、数え直す", () => {
    const run = new Run({ target: MIN, degraded: true });
    run.at(0, { backlogMs: 100 });
    run.at(6, { backlogMs: 1501 });
    expect(run.at(15.999, { backlogMs: 100 }).degraded).toBe(true);
    expect(run.at(16, { backlogMs: 100 }).degraded).toBe(true);
    expect(run.at(26, { backlogMs: 100 }).degraded).toBe(false);
  });

  test("劣化していなければ、条件 7 は評価しない（出来事 degraded_cleared を出さない）", () => {
    const run = new Run();
    const results = Array.from({ length: 30 }, () => run.tick({ backlogMs: 100 }));
    expect(results.some((decision) => decision.events.some((event) => event.kind === "degraded_cleared"))).toBe(false);
  });

  test("劣化していても、滞留時間が健全（0.3 秒未満・破棄なし）なら、目標は、条件 2 で引き上がる（劣化の解除は、10 秒の継続を待つ）", () => {
    const run = new Run({ target: MIN, degraded: true });
    const first = run.tick({ backlogMs: 100 });
    expect(first.targetKbps).toBe(3300);
    expect(first.degraded).toBe(true);
  });

  test("劣化から解除したあと、再び下限で逼迫が 20 秒続けば、再び劣化する", () => {
    const run = new Run({ target: MIN, degraded: true });
    for (let second = 0; second <= 10; second += 1) {
      run.at(second, { backlogMs: 1500 });
    }
    expect(run.degraded).toBe(false);
    run.target = MIN;
    run.at(11, { backlogMs: 2000 });
    expect(run.at(31, { backlogMs: 2000 }).degraded).toBe(true);
  });
});

describe("7 条件が、契約の列挙 adaptive_condition の 7 つと、1 対 1 に対応する", () => {
  // 各条件を、最小の入力で成立させ、triggered に、その条件だけが（ほかの条件を引き起こさずに）出ることを確かめる
  const rows: ReadonlyArray<readonly [AdaptiveCondition, () => GovernorDecision]> = [
    ["backlog_high_twice", () => new Run().ticks([1600, 1600])[1]],
    ["backlog_low_no_drop", () => new Run().tick({ backlogMs: 100 })],
    ["backlog_critical", () => new Run().tick({ backlogMs: 4500 })],
    [
      "video_ack_stalled",
      () => {
        const run = new Run();
        run.at(0, { ackedVideoUs: US });
        return run.at(10, { ackedVideoUs: US });
      },
    ],
    [
      "backlog_severe_sustained",
      () => {
        const run = new Run();
        run.at(0, { backlogMs: 8500 });
        return run.at(10, { backlogMs: 8500 });
      },
    ],
    [
      "degraded_enter",
      () => {
        const run = new Run({ target: MIN });
        run.at(0, { backlogMs: 1600 });
        return run.at(20, { backlogMs: 1600 });
      },
    ],
    [
      "degraded_exit",
      () => {
        const run = new Run({ target: MIN, degraded: true });
        run.at(0, { backlogMs: 1000 });
        return run.at(10, { backlogMs: 1000 });
      },
    ],
  ];

  test("契約の列挙の 7 つの順に、すべて検査している", () => {
    expect(rows.map(([condition]) => condition)).toEqual([...ADAPTIVE_CONDITION_VALUES]);
  });

  test.each(rows)("%s は、この条件が triggered に出る", (condition, produce) => {
    const decision = produce();
    expect(decision.triggered).toContain(condition);
  });

  test("triggered は、契約の列挙の順（12 章の表の順）に並ぶ", () => {
    const run = new Run({ target: MIN });
    // 同じ評価で、条件 1・3・5・6 が成立する
    run.at(0, { backlogMs: 9000, ackedVideoUs: US });
    const decision = run.at(1, { backlogMs: 9000, ackedVideoUs: 2 * US });
    const order = decision.triggered.map((condition) => ADAPTIVE_CONDITION_VALUES.indexOf(condition));
    expect(order).toEqual([...order].sort((a, b) => a - b));
    expect(decision.triggered).toEqual(expect.arrayContaining(["backlog_high_twice", "backlog_critical"]));
  });
});

describe("中継の抑制指示は、ブラウザ側の判定より優先する（min(現在の目標, 指示)。プロファイルの下限から上限の範囲）", () => {
  test("指示が現在の目標より小さければ、その評価で、直ちに指示の値まで下げる（出来事 bitrate_down）", () => {
    const decision = new Run().tick({ backlogMs: 100, throttleKbps: 3150 });
    expect(decision.targetKbps).toBe(3150);
    expect(decision.events).toEqual([down(4500, 3150)]);
  });

  test("ブラウザ側が引き上げたい（健全・破棄なし）評価でも、指示を優先する（引き上げない）", () => {
    const decision = new Run().tick({ backlogMs: 0, throttleKbps: 4000 });
    expect(decision.targetKbps).toBe(4000);
  });

  test.each([
    ["指示が目標より大きい", 5000, 4500],
    ["指示が目標と等しい", 4500, 4500],
  ])("%s：目標は変わらない。その評価での、ブラウザ側の引き上げも行わない（指示の評価のあいだ、上げない）", (_label, throttleKbps, expected) => {
    const decision = new Run().tick({ backlogMs: 0, throttleKbps });
    expect(decision.targetKbps).toBe(expected);
    expect(decision.events).toEqual([]);
    expect(decision.triggered).not.toContain("backlog_low_no_drop");
  });

  test("指示が、プロファイルの下限より小さければ、下限で止める（下限を下回らない）", () => {
    const decision = new Run().tick({ throttleKbps: 1000 });
    expect(decision.targetKbps).toBe(MIN);
    expect(decision.events).toEqual([down(4500, MIN)]);
  });

  test("指示は、条件 1（引き下げ）の判定を置き換える：連続の数が揃っていても、指示の値になる（さらに 30% は下げない）", () => {
    const run = new Run();
    run.tick({ backlogMs: 2000 });
    const decision = run.tick({ backlogMs: 2000, throttleKbps: 4200 });
    expect(decision.targetKbps).toBe(4200);
    expect(decision.triggered).not.toContain("backlog_high_twice");
  });

  test("解除を伝えるメッセージは無い：指示のない評価からは、通常の評価（引き上げ・引き下げ）に従う", () => {
    const run = new Run();
    run.tick({ throttleKbps: 3150 });
    expect(run.target).toBe(3150);
    // 次の評価（指示なし）。健全・破棄なしなので、10% 引き上げる
    const next = run.tick({ backlogMs: 100 });
    expect(next.targetKbps).toBe(3465);
    expect(next.events).toEqual([up(3150, 3465)]);
  });

  test("指示のあとも、中継の送出待ちがなお高ければ、中継が再び指示する：指示のたびに、指示の値まで下げる", () => {
    const run = new Run();
    const first = run.tick({ throttleKbps: 4000 });
    const second = run.tick({ throttleKbps: 3500 });
    expect([first.targetKbps, second.targetKbps]).toEqual([4000, 3500]);
  });

  test.each([
    ["0", 0],
    ["負", -1],
    ["小数", 3150.5],
    ["NaN", Number.NaN],
    ["null", null],
    ["文字列", "3150"],
  ])("不正な指示（%s）は RangeError", (_label, throttleKbps) => {
    expect(() => new Run().tick({ throttleKbps: throttleKbps as unknown as number })).toThrow(RangeError);
  });
});

describe("目標の変更は、1 秒あたり 1 回まで", () => {
  test("評価が 1 秒より短い間隔（0.9 秒）で来ても、目標を変えない（1 秒あとの評価で変える）", () => {
    const run = new Run();
    run.at(0, { backlogMs: 2000 });
    const changed = run.at(1, { backlogMs: 2000 });
    expect(changed.targetKbps).toBe(3150);
    run.at(1.5, { backlogMs: 2000 });
    const blocked = run.at(1.9, { backlogMs: 2000 });
    expect(blocked.targetKbps).toBe(3150);
    expect(blocked.events).toEqual([]);
    // 連続の数は、消費されていない（成立していたのに、変更の間隔で止められた）ので、変更が許される評価で、すぐ引き下げる
    const allowed = run.at(2, { backlogMs: 2000 });
    expect(allowed.targetKbps).toBe(3000);
  });

  test("引き上げも同じ：1 秒以内に 2 回は、上げない。ちょうど 1 秒なら上げる", () => {
    const run = new Run();
    run.at(20, { backlogMs: 100 });
    expect(run.at(20.5, { backlogMs: 100 }).targetKbps).toBe(4950);
    expect(run.at(20.999, { backlogMs: 100 }).targetKbps).toBe(4950);
    expect(run.at(21, { backlogMs: 100 }).targetKbps).toBe(5445);
  });

  test("指示（抑制）を適用したあと、1 秒以内は、ブラウザ側の判定で目標を変えない。指示は、変更の間隔にかかわらず、直ちに適用する", () => {
    const run = new Run();
    run.at(30, { backlogMs: 100 });
    const throttled = run.at(30.4, { throttleKbps: 4000 });
    expect(throttled.targetKbps).toBe(4000);
    expect(run.at(30.8, { backlogMs: 100 }).targetKbps).toBe(4000);
    expect(run.at(31.4, { backlogMs: 100 }).targetKbps).toBe(4400);
  });

  test("1 秒ごとの評価では、変更は評価ごとに高々 1 回（出来事は、目標の変更 1 つまで）", () => {
    const run = new Run();
    const results = run.ticks([2000, 2000, 2000, 2000, 100, 100, 100, 100]);
    for (const decision of results) {
      expect(decision.events.filter((event) => event.kind === "bitrate_down" || event.kind === "bitrate_up").length).toBeLessThanOrEqual(1);
    }
  });
});

describe("入力の時刻が、同じ・逆行しても壊れない", () => {
  test("同じ時刻の評価は無視する（ignored）。状態を変えず、目標・劣化は、入力のまま", () => {
    const run = new Run();
    run.at(1, { backlogMs: 2000 });
    const duplicate = run.at(1, { backlogMs: 2000 });
    expect(duplicate).toMatchObject({ ignored: true, targetKbps: 4500, discardAllVideo: false, reconnect: false, degraded: false, degradedChange: "none" });
    expect(duplicate.events).toEqual([]);
    expect(duplicate.triggered).toEqual([]);
    // 重複を数えていなければ、次の評価が 2 回目の連続
    expect(run.at(2, { backlogMs: 2000 }).targetKbps).toBe(3150);
  });

  test("時刻が逆行した評価は無視する。例外にならず、以後の評価は、逆行がなかった場合と同じ結果", () => {
    const withRegression = new Run();
    const without = new Run();
    const script: ReadonlyArray<readonly [number, Partial<GovernorInput>]> = [
      [0, { backlogMs: 2000 }],
      [1, { backlogMs: 2000 }],
      [2, { backlogMs: 100 }],
    ];
    for (const [second, overrides] of script) {
      without.at(second, overrides);
      withRegression.at(second, overrides);
    }
    const regressed = withRegression.at(0.5, { backlogMs: 9000 });
    expect(regressed.ignored).toBe(true);
    expect(() => withRegression.at(1.5, { backlogMs: 9000 })).not.toThrow();
    const after = withRegression.at(3, { backlogMs: 100 });
    const reference = without.at(3, { backlogMs: 100 });
    expect(after).toEqual(reference);
  });

  test("逆行した評価が、継続時間を負にしたり、再接続・劣化を引き起こしたりしない", () => {
    const run = new Run({ target: MIN });
    run.at(100, { backlogMs: 9000, ackedVideoUs: US });
    const earlier = run.at(5, { backlogMs: 9000, ackedVideoUs: US });
    expect(earlier).toMatchObject({ ignored: true, reconnect: false, degraded: false, discardAllVideo: false });
  });

  test("最初の評価は、どの時刻でも受理する（0 でなくてよい）", () => {
    expect(new Run().at(123.456, { backlogMs: 100 }).ignored).toBe(false);
  });
});

describe("滞留時間を評価できないとき（undefined。その接続の最初の ack の前）", () => {
  test("滞留時間による条件（1・2・3・5・6・7）は評価しない：引き上げも引き下げも、全破棄も、劣化の変化もない", () => {
    const run = new Run({ target: MIN });
    const results = Array.from({ length: 8 }, () => run.tick({ backlogMs: undefined }));
    for (const decision of results) {
      expect(decision).toMatchObject({ targetKbps: MIN, discardAllVideo: false, degraded: false });
      expect(decision.events).toEqual([]);
    }
  });
});

describe("状態の初期化（reset）：接続・再接続の直後に呼ぶ", () => {
  test("reset のあとの評価は、新しい governor と同じ（連続の数・継続時間・受領済み時刻・最後の変更の時刻を、忘れる）。時刻が 0 に戻ってもよい", () => {
    const used = new Run();
    used.ticks([2000, 2000, 2000, 9000, 9000]);
    used.governor.reset();
    const fresh = new Run();
    // 時刻を 0 から数え直す（再読み込みなど）
    const script: ReadonlyArray<Partial<GovernorInput>> = [{ backlogMs: 2000 }, { backlogMs: 2000 }, { backlogMs: 100 }, { backlogMs: 100 }];
    const usedResults = script.map((overrides, index) => used.governor.evaluate({ nowSec: index, backlogMs: 100, dropTimesSec: [], targetKbps: 4500, minKbps: MIN, maxKbps: MAX, ackedVideoUs: (index + 1) * US, degraded: false, ...overrides }));
    const freshResults = script.map((overrides, index) => fresh.governor.evaluate({ nowSec: index, backlogMs: 100, dropTimesSec: [], targetKbps: 4500, minKbps: MIN, maxKbps: MAX, ackedVideoUs: (index + 1) * US, degraded: false, ...overrides }));
    expect(usedResults).toEqual(freshResults);
  });

  test("diagnostics は、内部の数・時刻（秒）を返す。reset で空になる", () => {
    const run = new Run({ target: MIN });
    run.at(0, { backlogMs: 2000, ackedVideoUs: US });
    run.at(1, { backlogMs: 9000, ackedVideoUs: 2 * US });
    expect(run.governor.diagnostics()).toMatchObject({ highStreak: 0, severeSinceSec: 1, squeezedSinceSec: 0, relaxedSinceSec: undefined, ackAdvancedAtSec: 1 });
    run.governor.reset();
    expect(run.governor.diagnostics()).toEqual({ lastEvaluatedSec: undefined, highStreak: 0, severeSinceSec: undefined, squeezedSinceSec: undefined, relaxedSinceSec: undefined, ackAdvancedAtSec: undefined, lastChangeSec: undefined });
  });
});

describe("入力の検査：不正な値は、推測せず RangeError", () => {
  const valid: GovernorInput = { nowSec: 1, backlogMs: 100, dropTimesSec: [], targetKbps: 4500, minKbps: MIN, maxKbps: MAX, ackedVideoUs: US, degraded: false };

  test.each([
    ["nowSec が負", { nowSec: -1 }],
    ["nowSec が NaN", { nowSec: Number.NaN }],
    ["nowSec が無限大", { nowSec: Number.POSITIVE_INFINITY }],
    ["nowSec が文字列", { nowSec: "1" }],
    ["nowSec が大きすぎる（マイクロ秒が安全整数を超える）", { nowSec: 1e12 }],
    ["backlogMs が負", { backlogMs: -1 }],
    ["backlogMs が NaN", { backlogMs: Number.NaN }],
    ["backlogMs が無限大", { backlogMs: Number.POSITIVE_INFINITY }],
    ["backlogMs が null（評価できないときは undefined）", { backlogMs: null }],
    ["backlogMs が文字列", { backlogMs: "100" }],
    ["dropTimesSec が配列でない", { dropTimesSec: 1 }],
    ["dropTimesSec に負の値", { dropTimesSec: [-1] }],
    ["dropTimesSec に NaN", { dropTimesSec: [Number.NaN] }],
    ["dropTimesSec に文字列", { dropTimesSec: ["1"] }],
    ["targetKbps が下限未満", { targetKbps: 2999 }],
    ["targetKbps が上限超過", { targetKbps: 6001 }],
    ["targetKbps が小数", { targetKbps: 4500.5 }],
    ["targetKbps が NaN", { targetKbps: Number.NaN }],
    ["minKbps が 0", { minKbps: 0 }],
    ["minKbps が小数", { minKbps: 3000.5 }],
    ["minKbps が maxKbps より大きい", { minKbps: 7000 }],
    ["maxKbps が小数", { maxKbps: 6000.5 }],
    ["ackedVideoUs が負", { ackedVideoUs: -1 }],
    ["ackedVideoUs が小数", { ackedVideoUs: 1.5 }],
    ["ackedVideoUs が NaN", { ackedVideoUs: Number.NaN }],
    ["ackedVideoUs が null", { ackedVideoUs: null }],
    ["degraded が真偽値でない", { degraded: 0 }],
  ])("%s", (_label, override) => {
    expect(() => new BitrateGovernor().evaluate({ ...valid, ...override } as unknown as GovernorInput)).toThrow(RangeError);
  });

  test("入力がオブジェクトでなければ RangeError", () => {
    expect(() => new BitrateGovernor().evaluate(null as unknown as GovernorInput)).toThrow(RangeError);
    expect(() => new BitrateGovernor().evaluate(undefined as unknown as GovernorInput)).toThrow(RangeError);
  });

  test("不正な入力のとき、状態は変わらない（次の正しい入力が、新しい governor と同じ結果になる）", () => {
    const governor = new BitrateGovernor();
    expect(() => governor.evaluate({ ...valid, nowSec: 5, backlogMs: -1 })).toThrow(RangeError);
    expect(governor.evaluate({ ...valid, nowSec: 0 })).toEqual(new BitrateGovernor().evaluate({ ...valid, nowSec: 0 }));
  });

  test("入力を変更しない（dropTimesSec の配列も）", () => {
    const dropTimesSec = [1, 2, 3];
    const input: GovernorInput = { ...valid, dropTimesSec };
    new BitrateGovernor().evaluate(input);
    expect(dropTimesSec).toEqual([1, 2, 3]);
    expect(input).toEqual({ ...valid, dropTimesSec: [1, 2, 3] });
  });
});

describe("結果は変更できない（凍結されている）。決定的（同じ入力の列に、同じ出力）", () => {
  test("結果・出来事の配列・triggered の配列が凍結されている", () => {
    const decision = new Run().tick({ backlogMs: 5000 });
    expect(Object.isFrozen(decision)).toBe(true);
    expect(Object.isFrozen(decision.events)).toBe(true);
    expect(Object.isFrozen(decision.triggered)).toBe(true);
  });

  test("同じ入力の列を、別々の instance に与えると、同じ出力の列になる（乱数・実時計を使わない）", () => {
    const random = seededRandom(25);
    const inputs: GovernorInput[] = [];
    let target = 4500;
    for (let second = 0; second < 300; second += 1) {
      const roll = random();
      inputs.push({
        nowSec: second,
        backlogMs: roll < 0.05 ? undefined : Math.floor(random() * random() * 12_000),
        dropTimesSec: random() < 0.1 ? [Math.max(0, second - 2)] : [],
        targetKbps: target,
        minKbps: MIN,
        maxKbps: MAX,
        throttleKbps: random() < 0.05 ? 3000 + Math.floor(random() * 3000) : undefined,
        ackedVideoUs: random() < 0.9 ? (second + 1) * US : US,
        degraded: false,
      });
      target = 4500;
    }
    const outputs = (): string => {
      const governor = new BitrateGovernor();
      return JSON.stringify(inputs.map((input) => governor.evaluate(input)));
    };
    expect(outputs()).toBe(outputs());
  });
});

describe("性質の検査（決定的な乱数。閉じた輪で、結果を次の入力へ引き継ぐ）", () => {
  test("どんな入力の列でも：目標は、いつも、下限から上限の範囲。1 秒あたり 1 回まで。出来事は、変化と一致する。例外にならない", () => {
    const problems = new Problems();
    for (let seed = 1; seed <= 60; seed += 1) {
      const random = seededRandom(seed);
      const min = 800 + Math.floor(random() * 2000);
      const max = min + Math.floor(random() * 4000);
      const governor = new BitrateGovernor();
      let target = min + Math.floor(random() * (max - min + 1));
      let degraded = random() < 0.2;
      let previousChangeSec = -10;
      let nowSec = 0;
      let ackUs = US;
      const drops: number[] = [];
      for (let step = 0; step < 400; step += 1) {
        nowSec += random() < 0.9 ? 1 : 0.25 + random() * 0.5;
        if (random() < 0.85) {
          ackUs += US;
        }
        if (random() < 0.1) {
          drops.push(nowSec);
        }
        const backlog = random() < 0.05 ? undefined : random() < 0.5 ? random() * 1_500 : random() * 12_000;
        const throttle = random() < 0.06 ? 1 + Math.floor(random() * (max + 1000)) : undefined;
        const decision = governor.evaluate({ nowSec, backlogMs: backlog, dropTimesSec: drops.slice(-20), targetKbps: target, minKbps: min, maxKbps: max, throttleKbps: throttle, ackedVideoUs: ackUs, degraded });
        const label = `seed ${seed} step ${step}`;
        if (decision.targetKbps < min || decision.targetKbps > max || !Number.isInteger(decision.targetKbps)) {
          problems.report(`${label}: target ${decision.targetKbps} is out of [${min}, ${max}] or not an integer`);
        }
        const changed = decision.targetKbps !== target;
        const bitrateEvents = decision.events.filter((event) => event.kind === "bitrate_down" || event.kind === "bitrate_up");
        if (changed !== (bitrateEvents.length === 1) || bitrateEvents.length > 1) {
          problems.report(`${label}: ${bitrateEvents.length} bitrate events for a change of ${target} -> ${decision.targetKbps}`);
        }
        const event = bitrateEvents[0];
        if (event !== undefined && (event.kind === "bitrate_down" || event.kind === "bitrate_up")) {
          if (event.fromKbps !== target || event.toKbps !== decision.targetKbps || (event.kind === "bitrate_down") !== (decision.targetKbps < target)) {
            problems.report(`${label}: the bitrate event ${JSON.stringify(event)} does not match ${target} -> ${decision.targetKbps}`);
          }
        }
        if (!decision.ignored && changed && throttle === undefined) {
          if (nowSec - previousChangeSec < 1 - 1e-9) {
            problems.report(`${label}: the target changed twice within ${nowSec - previousChangeSec} seconds`);
          }
        }
        if (!decision.ignored && changed) {
          previousChangeSec = nowSec;
        }
        if (decision.discardAllVideo !== decision.requestKeyframe) {
          problems.report(`${label}: discardAllVideo and requestKeyframe differ`);
        }
        if (decision.discardAllVideo !== decision.events.some((item) => item.kind === "video_dropped")) {
          problems.report(`${label}: the video_dropped event does not match discardAllVideo`);
        }
        if (decision.reconnect !== (decision.reconnectCause !== undefined)) {
          problems.report(`${label}: reconnect and reconnectCause differ`);
        }
        const expectedChange = decision.degraded === degraded ? "none" : decision.degraded ? "started" : "cleared";
        if (decision.degradedChange !== expectedChange) {
          problems.report(`${label}: degradedChange is ${decision.degradedChange}, expected ${expectedChange}`);
        }
        if (decision.degraded !== degraded) {
          const expectedEvent = decision.degraded ? "degraded_started" : "degraded_cleared";
          if (!decision.events.some((item) => item.kind === expectedEvent)) {
            problems.report(`${label}: degraded changed without ${expectedEvent}`);
          }
        } else if (decision.events.some((item) => item.kind === "degraded_started" || item.kind === "degraded_cleared")) {
          problems.report(`${label}: a degraded event without a change`);
        }
        if (!decision.ignored) {
          target = decision.targetKbps;
          degraded = decision.degraded;
        }
      }
    }
    expect(problems.list()).toEqual([]);
  });
});
