// BitrateGovernor：適応制御（requirements.md 12 章）。滞留時間を毎秒評価し、目標ビットレートと破棄方針を決める。
//
// 12 章の 7 条件を、1 行ずつ、独立に評価する（数値は、契約の LIMITS.adaptive.conditions から取る）：
//   1. backlog_high_twice          滞留時間が 1.5 秒を超える評価が 2 回連続 -> 目標を 30% 引き下げる（下限まで）
//   2. backlog_low_no_drop         滞留時間が 0.3 秒未満、かつ直近 10 秒に破棄がない -> 10% 引き上げる（上限まで）
//   3. backlog_critical            滞留時間が 4 秒を超える -> 送信待ちの映像を全破棄し、直ちにキーフレームを発行する
//   4. video_ack_stalled           映像の受領済み時刻が 10 秒間進まない -> 再接続へ移る
//   5. backlog_severe_sustained    滞留時間が 8 秒を超える状態が 10 秒継続 -> 再接続へ移る
//   6. degraded_enter              下限に達したうえで、逼迫（滞留時間 1.5 秒超）が 20 秒継続 -> 劣化
//   7. degraded_exit               劣化の状態で、滞留時間 1.5 秒以下が 10 秒継続 -> 劣化を解除する
//
// 要件（12 章）：
//   - 目標ビットレートの変更は、1 秒あたり 1 回まで（契約の target_change_min_interval_ms）。評価ごとに、高々 1 回の変更
//   - 引き下げ幅（30%）より引き上げ幅（10%）が小さい（回復は、引き下げより緩やか）
//   - 中継の抑制指示は、ブラウザ側の判定より優先する：指示を受けた評価では、min(現在の目標, 指示) まで直ちに下げ（変更の間隔にかかわらず）、
//     その評価では、ブラウザ側の引き下げ・引き上げ（条件 1・2）を行わない。解除を伝えるメッセージは無い（契約）ので、指示の無い評価からは、通常の評価に従う
//
// 解釈（仕様に定めが無く、ここで置いた規則）：
//   - 丸め：引き下げは floor(目標 x 70 / 100)、引き上げは ceil(目標 x 110 / 100)。結果は、下限から上限に収める（整数の kbps）
//   - 「2 回連続」：引き下げを行った評価のあとは、数え直す（2 回ごとに引き下げる）。下限にいて変化が無かったときも、数え直す
//     変更の間隔で止められた（成立したのに、変更できなかった）ときは、数えを残し、変更できる評価で、直ちに引き下げる
//   - 「N 秒継続」：条件が最初に成り立った評価の時刻から、N 秒以上（>=）経った評価で成立する。途中で成り立たなくなれば、数え直す
//   - 「直近 10 秒の破棄」：(現在 - 10 秒, 現在] の破棄。ちょうど 10 秒前の破棄は含めない。現在より後の時刻（時計の逆行）の破棄は、直近として扱う
//   - 「下限に達した」：この評価の結果の目標が、下限以下（引き下げでちょうど下限になった評価から、数え始める）
//   - 条件は、独立に評価する：1 つの評価で、複数の条件が成立してよい（例：全破棄と、引き下げと、再接続）。再接続の指示でも、ほかの指示を抑えない
//   - 滞留時間を評価できない（undefined）評価は、滞留時間による条件の状態を変えない。条件 4 は、受領済みの映像の時刻だけで評価する
//     受領応答が、まだ 1 つも無い間（undefined）は、最初の評価の時刻から数える（応答が来ない接続を、放置しない）
//   - 時刻が進まない評価（直前と同じか、それより前）は、無視する（ignored）。状態を変えず、例外にもしない
//
// 状態（連続の数・継続の開始時刻・受領済み時刻・最後の変更の時刻）を持つ。時刻は、入力のメディアクロック由来の秒だけを使い（実時計・タイマを
// 参照しない）、内部は整数のマイクロ秒で比較する（浮動小数点の端数で、境界がずれない）。決定的：同じ入力の列に、同じ出力。

import { ADAPTIVE_CONDITION_VALUES, LIMITS } from "../contract";
import type { AdaptiveCondition } from "../contract";
import type { BrowserEvent } from "../report";
import type { DegradedChange, GovernorDecision, GovernorDiagnostics, GovernorInput, ReconnectCause } from "./types";

const CONDITIONS = LIMITS.adaptive.conditions;
const MICROSECONDS_PER_SECOND = 1_000_000;
const MICROSECONDS_PER_MILLISECOND = 1000;
const PERCENT = 100;

const MIN_CHANGE_INTERVAL_US = LIMITS.adaptive.target_change_min_interval_ms * MICROSECONDS_PER_MILLISECOND;
const NO_DROP_WINDOW_US = CONDITIONS.backlog_low_no_drop.no_drop_window_seconds * MICROSECONDS_PER_SECOND;
const VIDEO_ACK_STALLED_US = CONDITIONS.video_ack_stalled.stalled_seconds * MICROSECONDS_PER_SECOND;
const SEVERE_DURATION_US = CONDITIONS.backlog_severe_sustained.duration_seconds * MICROSECONDS_PER_SECOND;
const DEGRADED_ENTER_US = CONDITIONS.degraded_enter.duration_seconds * MICROSECONDS_PER_SECOND;
const DEGRADED_EXIT_US = CONDITIONS.degraded_exit.duration_seconds * MICROSECONDS_PER_SECOND;

/** 検査した入力のうち、内部で使う、マイクロ秒の値。 */
interface CheckedTimes {
  readonly nowUs: number;
  readonly dropTimesUs: readonly number[];
}

/** 目標の判断の結果。 */
interface TargetOutcome {
  readonly targetKbps: number;
  readonly event?: BrowserEvent;
  /** 条件 1 が成立した（変更の有無によらない） */
  readonly highTwice: boolean;
  /** 条件 2 が成立した（変更の有無によらない） */
  readonly lowNoDrop: boolean;
}

function fail(message: string): never {
  throw new RangeError(message);
}

function assertFiniteAtLeastZero(value: unknown, name: string): asserts value is number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    fail(`${name} must be a finite number of at least 0: ${String(value)}`);
  }
}

function assertSafeInteger(value: unknown, name: string, minimum: number): asserts value is number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum) {
    fail(`${name} must be a safe integer of at least ${minimum}: ${String(value)}`);
  }
}

/** 秒を、整数のマイクロ秒にする（0 以上の有限の数。結果が安全整数に収まらなければ RangeError）。 */
function toMicroseconds(seconds: number, name: string): number {
  assertFiniteAtLeastZero(seconds, name);
  const microseconds = Math.round(seconds * MICROSECONDS_PER_SECOND);
  if (!Number.isSafeInteger(microseconds)) {
    fail(`${name} is too large: ${seconds} seconds`);
  }
  return microseconds;
}

function toSeconds(microseconds: number | undefined): number | undefined {
  return microseconds === undefined ? undefined : microseconds / MICROSECONDS_PER_SECOND;
}

/** 入力を検査し、マイクロ秒の値を返す。不正な値は、推測せず RangeError（状態は変えない）。 */
function checkInput(input: GovernorInput): CheckedTimes {
  if (typeof input !== "object" || input === null) {
    return fail(`input must be an object: ${input === null ? "null" : typeof input}`);
  }
  const nowUs = toMicroseconds(input.nowSec, "nowSec");
  if (input.backlogMs !== undefined) {
    assertFiniteAtLeastZero(input.backlogMs, "backlogMs");
  }
  if (!Array.isArray(input.dropTimesSec)) {
    fail(`dropTimesSec must be an array: ${typeof input.dropTimesSec}`);
  }
  const dropTimesUs = input.dropTimesSec.map((seconds, index) => toMicroseconds(seconds, `dropTimesSec[${index}]`));
  assertSafeInteger(input.minKbps, "minKbps", 1);
  assertSafeInteger(input.maxKbps, "maxKbps", input.minKbps);
  assertSafeInteger(input.targetKbps, "targetKbps", input.minKbps);
  if (input.targetKbps > input.maxKbps) {
    fail(`targetKbps ${input.targetKbps} is above maxKbps ${input.maxKbps}`);
  }
  if (input.throttleKbps !== undefined) {
    assertSafeInteger(input.throttleKbps, "throttleKbps", 1);
  }
  if (input.ackedVideoUs !== undefined) {
    assertSafeInteger(input.ackedVideoUs, "ackedVideoUs", 0);
  }
  if (typeof input.degraded !== "boolean") {
    fail(`degraded must be a boolean: ${typeof input.degraded}`);
  }
  return { nowUs, dropTimesUs };
}

/** 引き下げ後の目標：floor(目標 x (100 - 30) / 100)。下限を下回らない。 */
function loweredTarget(targetKbps: number, minKbps: number): number {
  return Math.max(minKbps, Math.floor((targetKbps * (PERCENT - CONDITIONS.backlog_high_twice.decrease_percent)) / PERCENT));
}

/** 引き上げ後の目標：ceil(目標 x (100 + 10) / 100)。上限を超えない。 */
function raisedTarget(targetKbps: number, maxKbps: number): number {
  return Math.min(maxKbps, Math.ceil((targetKbps * (PERCENT + CONDITIONS.backlog_low_no_drop.increase_percent)) / PERCENT));
}

function frozenEvent(event: BrowserEvent): BrowserEvent {
  return Object.freeze(event);
}

export class BitrateGovernor {
  private lastEvaluatedUs: number | undefined;
  private highStreak = 0;
  private severeSinceUs: number | undefined;
  private squeezedSinceUs: number | undefined;
  private relaxedSinceUs: number | undefined;
  private lastAckedVideoUs: number | undefined;
  private ackAdvancedAtUs: number | undefined;
  private lastChangeUs: number | undefined;

  /**
   * 状態を初期化する。接続・再接続の直後（その接続の最初の受領応答の前）に呼ぶ。メディアクロックが 0 から数え直しになっても（ページの再読み込みなど）、
   * 新しい接続として、評価できる。
   */
  reset(): void {
    this.lastEvaluatedUs = undefined;
    this.highStreak = 0;
    this.severeSinceUs = undefined;
    this.squeezedSinceUs = undefined;
    this.relaxedSinceUs = undefined;
    this.lastAckedVideoUs = undefined;
    this.ackAdvancedAtUs = undefined;
    this.lastChangeUs = undefined;
  }

  /** 内部の状態の写し（診断用。時刻は秒）。 */
  diagnostics(): GovernorDiagnostics {
    return {
      lastEvaluatedSec: toSeconds(this.lastEvaluatedUs),
      highStreak: this.highStreak,
      severeSinceSec: toSeconds(this.severeSinceUs),
      squeezedSinceSec: toSeconds(this.squeezedSinceUs),
      relaxedSinceSec: toSeconds(this.relaxedSinceUs),
      ackAdvancedAtSec: toSeconds(this.ackAdvancedAtUs),
      lastChangeSec: toSeconds(this.lastChangeUs),
    };
  }

  /**
   * 1 回の評価（毎秒呼ぶ）。入力は変更しない。結果は、凍結している。
   * 不正な入力は RangeError（状態は変わらない）。時刻が進まない評価は、無視する（ignored）。
   */
  evaluate(input: GovernorInput): GovernorDecision {
    const { nowUs, dropTimesUs } = checkInput(input);
    if (this.lastEvaluatedUs !== undefined && nowUs <= this.lastEvaluatedUs) {
      return Object.freeze({
        ignored: true,
        targetKbps: input.targetKbps,
        discardAllVideo: false,
        requestKeyframe: false,
        reconnect: false,
        reconnectCause: undefined,
        degraded: input.degraded,
        degradedChange: "none",
        events: Object.freeze([]),
        triggered: Object.freeze([]),
      });
    }
    this.lastEvaluatedUs = nowUs;

    const backlogMs = input.backlogMs;
    const met = new Set<AdaptiveCondition>();
    const events: BrowserEvent[] = [];

    // 条件 4：映像の受領済み時刻が 10 秒間進まない（滞留時間を評価できなくても、評価する）
    const ackStalled = this.watchVideoAck(nowUs, input.ackedVideoUs);

    // 条件 1・2（と、中継の抑制指示）：目標ビットレート
    const outcome = this.decideTarget(input, nowUs, dropTimesUs);
    if (outcome.highTwice) {
      met.add("backlog_high_twice");
    }
    if (outcome.lowNoDrop) {
      met.add("backlog_low_no_drop");
    }
    if (outcome.event !== undefined) {
      events.push(frozenEvent(outcome.event));
    }

    let critical = false;
    let severeSustained = false;
    let degradedChange: DegradedChange = "none";
    if (backlogMs !== undefined) {
      // 条件 3：滞留時間が 4 秒を超える
      critical = backlogMs > CONDITIONS.backlog_critical.backlog_over_ms;
      if (critical) {
        met.add("backlog_critical");
        events.push(frozenEvent({ kind: "video_dropped" }));
      }
      // 条件 5：滞留時間が 8 秒を超える状態が 10 秒継続
      severeSustained = this.watchSevere(nowUs, backlogMs);
      // 条件 6・7：劣化
      degradedChange = this.watchDegraded(nowUs, backlogMs, input.degraded, outcome.targetKbps, input.minKbps);
    }
    if (ackStalled) {
      met.add("video_ack_stalled");
    }
    if (severeSustained) {
      met.add("backlog_severe_sustained");
    }
    let degraded = input.degraded;
    if (degradedChange === "started") {
      degraded = true;
      met.add("degraded_enter");
      events.push(frozenEvent({ kind: "degraded_started" }));
    } else if (degradedChange === "cleared") {
      degraded = false;
      met.add("degraded_exit");
      events.push(frozenEvent({ kind: "degraded_cleared" }));
    }

    const reconnectCause: ReconnectCause | undefined = ackStalled ? "video_ack_stalled" : severeSustained ? "backlog_severe_sustained" : undefined;
    return Object.freeze({
      ignored: false,
      targetKbps: outcome.targetKbps,
      discardAllVideo: critical,
      requestKeyframe: critical,
      reconnect: reconnectCause !== undefined,
      reconnectCause,
      degraded,
      degradedChange,
      events: Object.freeze(events),
      triggered: Object.freeze(ADAPTIVE_CONDITION_VALUES.filter((condition) => met.has(condition))),
    });
  }

  /**
   * 条件 4：受領済みの映像の時刻が、最後に進んだ時刻から 10 秒以上経ったか。進んだ（前回より大きい）とき、時刻を記録する。
   * まだ 1 つも受領応答が無い間は、最初の評価の時刻を、基準にする。減った値（中継の側が数え直した）は、進んだとは数えない。
   */
  private watchVideoAck(nowUs: number, ackedVideoUs: number | undefined): boolean {
    if (this.ackAdvancedAtUs === undefined) {
      this.ackAdvancedAtUs = nowUs;
    }
    if (ackedVideoUs !== undefined && (this.lastAckedVideoUs === undefined || ackedVideoUs > this.lastAckedVideoUs)) {
      this.lastAckedVideoUs = ackedVideoUs;
      this.ackAdvancedAtUs = nowUs;
    }
    return nowUs - this.ackAdvancedAtUs >= VIDEO_ACK_STALLED_US;
  }

  /**
   * 目標ビットレートの判断（条件 1・2 と、中継の抑制指示）。
   *   抑制指示：min(現在の目標, 指示)（下限から上限の範囲）まで、直ちに下げる。この評価では、ブラウザ側の判断（条件 1・2）をしない
   *   条件 1：滞留時間が 1.5 秒を超える評価が 2 回連続なら、30% 引き下げる
   *   条件 2：滞留時間が 0.3 秒未満、かつ直近 10 秒に破棄がなければ、10% 引き上げる
   * ブラウザ側の変更は、前回の変更から 1 秒以上あとの評価だけ。滞留時間を評価できない（undefined）ときは、ブラウザ側の判断をしない。
   */
  private decideTarget(input: GovernorInput, nowUs: number, dropTimesUs: readonly number[]): TargetOutcome {
    const { targetKbps, minKbps, maxKbps, throttleKbps, backlogMs } = input;

    if (throttleKbps !== undefined) {
      const capped = Math.min(maxKbps, Math.max(minKbps, Math.min(targetKbps, throttleKbps)));
      if (backlogMs !== undefined) {
        this.countHighStreak(backlogMs);
      }
      if (capped < targetKbps) {
        this.lastChangeUs = nowUs;
        return { targetKbps: capped, event: { kind: "bitrate_down", fromKbps: targetKbps, toKbps: capped }, highTwice: false, lowNoDrop: false };
      }
      return { targetKbps, highTwice: false, lowNoDrop: false };
    }

    if (backlogMs === undefined) {
      return { targetKbps, highTwice: false, lowNoDrop: false };
    }
    this.countHighStreak(backlogMs);
    const mayChange = this.lastChangeUs === undefined || nowUs - this.lastChangeUs >= MIN_CHANGE_INTERVAL_US;

    // 条件 1：滞留時間が 1.5 秒を超える評価が 2 回連続
    if (this.highStreak >= CONDITIONS.backlog_high_twice.consecutive_evaluations) {
      if (!mayChange) {
        return { targetKbps, highTwice: true, lowNoDrop: false };
      }
      this.highStreak = 0;
      const lowered = loweredTarget(targetKbps, minKbps);
      if (lowered < targetKbps) {
        this.lastChangeUs = nowUs;
        return { targetKbps: lowered, event: { kind: "bitrate_down", fromKbps: targetKbps, toKbps: lowered }, highTwice: true, lowNoDrop: false };
      }
      return { targetKbps, highTwice: true, lowNoDrop: false };
    }

    // 条件 2：滞留時間が 0.3 秒未満、かつ直近 10 秒に破棄がない
    const recentDrop = dropTimesUs.some((dropUs) => nowUs - dropUs < NO_DROP_WINDOW_US);
    if (backlogMs < CONDITIONS.backlog_low_no_drop.backlog_under_ms && !recentDrop) {
      if (mayChange && targetKbps < maxKbps) {
        const raised = raisedTarget(targetKbps, maxKbps);
        this.lastChangeUs = nowUs;
        return { targetKbps: raised, event: { kind: "bitrate_up", fromKbps: targetKbps, toKbps: raised }, highTwice: false, lowNoDrop: true };
      }
      return { targetKbps, highTwice: false, lowNoDrop: true };
    }
    return { targetKbps, highTwice: false, lowNoDrop: false };
  }

  /** 条件 1 の数え：滞留時間が 1.5 秒を超えた評価の、連続の数。超えなければ、0 に戻す。 */
  private countHighStreak(backlogMs: number): void {
    this.highStreak = backlogMs > CONDITIONS.backlog_high_twice.backlog_over_ms ? this.highStreak + 1 : 0;
  }

  /** 条件 5：滞留時間が 8 秒を超える状態が、最初に成り立った評価から 10 秒以上続いたか。8 秒以下に戻れば、数え直す。 */
  private watchSevere(nowUs: number, backlogMs: number): boolean {
    if (backlogMs <= CONDITIONS.backlog_severe_sustained.backlog_over_ms) {
      this.severeSinceUs = undefined;
      return false;
    }
    if (this.severeSinceUs === undefined) {
      this.severeSinceUs = nowUs;
    }
    return nowUs - this.severeSinceUs >= SEVERE_DURATION_US;
  }

  /**
   * 条件 6・7：劣化の出入り。
   *   劣化していない：この評価の結果の目標が下限以下で、滞留時間が 1.5 秒を超える状態が 20 秒続いたら、劣化に入る（"started"）
   *   劣化している：滞留時間が 1.5 秒以下の状態が 10 秒続いたら、解除する（"cleared"）
   * 状態が変わる評価では、反対側の数えも消す。条件が途切れたら、数え直す。
   */
  private watchDegraded(nowUs: number, backlogMs: number, degraded: boolean, targetKbps: number, minKbps: number): DegradedChange {
    if (!degraded) {
      this.relaxedSinceUs = undefined;
      const squeezed = targetKbps <= minKbps && backlogMs > CONDITIONS.degraded_enter.backlog_over_ms;
      if (!squeezed) {
        this.squeezedSinceUs = undefined;
        return "none";
      }
      if (this.squeezedSinceUs === undefined) {
        this.squeezedSinceUs = nowUs;
      }
      if (nowUs - this.squeezedSinceUs >= DEGRADED_ENTER_US) {
        this.squeezedSinceUs = undefined;
        return "started";
      }
      return "none";
    }

    this.squeezedSinceUs = undefined;
    if (backlogMs > CONDITIONS.degraded_exit.backlog_at_most_ms) {
      this.relaxedSinceUs = undefined;
      return "none";
    }
    if (this.relaxedSinceUs === undefined) {
      this.relaxedSinceUs = nowUs;
    }
    if (nowUs - this.relaxedSinceUs >= DEGRADED_EXIT_US) {
      this.relaxedSinceUs = undefined;
      return "cleared";
    }
    return "none";
  }
}
