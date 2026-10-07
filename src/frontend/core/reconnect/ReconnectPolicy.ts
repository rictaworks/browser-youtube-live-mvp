// 再接続の方針（requirements.md 13.1・13.2・23.4）。ブラウザが中継との接続を失ったとき、どれだけ待って再接続を試みるか、再接続してよいか。
//
//   - 待機間隔は指数的に増やし、上限 5 秒（0.5 -> 1 -> 2 -> 4 -> 5 -> 5 ...）。初期値（0.5 秒）と倍率（2 倍）は契約に含まれず、ここで定める
//   - ジッタ（待機のばらつき）は、注入した乱数でのみ入れる。既定は決定的（乱数を使わない）。ジッタは待機を短くする向きだけで、上限を超えない
//   - 配信が終了済み・期限（中断 30 秒）を過ぎた場合は、再接続しない（13.1「再接続の不成立」）。復帰は 1 配信あたり 10 回まで
//   - 時刻・乱数・タイマを自分では持たない（Domain Core）

import { BROADCAST_STATE_VALUES, LIMITS, isBroadcastState } from "../contract";
import type { BroadcastState } from "../contract";

/** 最初の再試行の前の待機（ミリ秒）。 */
const INITIAL_DELAY_MS = 500;
/** 再試行のたびに待機を増やす倍率。 */
const DELAY_MULTIPLIER = 2;
/** ジッタの幅：待機を、最大でこの割合だけ短くする（乱数が 0 のとき短くしない）。 */
const JITTER_RATIO = 0.2;
/** 倍率を掛ける回数の上限。これ以上は、上限（契約の reconnect_backoff_cap_ms）に達していて、2 のべき乗の桁あふれを避ける。 */
const MAX_DOUBLINGS = 30;

/** サーバーが返す配信の見え方のうち、再接続の判断に使う項目（BroadcastView の state・resumable）。 */
export interface ReconnectServerView {
  readonly state: BroadcastState;
  /** 復帰できるか。状態が送出待ち・確定待ち・ライブ・中断のいずれかで、期限内なら true（http-api.md 2.1） */
  readonly resumable: boolean;
}

export type ReconnectReason =
  /** 再接続してよい */
  | "resumable"
  /** 配信が終了済み（終了を表示し、理由を示す） */
  | "broadcast_ended"
  /** 復帰できない（期限（中断 30 秒）を過ぎた・まだ接続の対象でない） */
  | "not_resumable"
  /** 復帰が上限（10 回）に達している（次の中断は、復帰を待たずに終了する） */
  | "resume_limit_reached";

/** 再接続の判断。resumesRemaining・maxResumes は、復帰の回数（10 回まで）の判断材料。 */
export interface ReconnectDecision {
  readonly reconnect: boolean;
  readonly reason: ReconnectReason;
  /** 復帰の残り回数（0 以上 maxResumes 以下） */
  readonly resumesRemaining: number;
  /** 1 配信あたりの復帰の上限（契約の deadlines.max_resumes） */
  readonly maxResumes: number;
}

export interface ReconnectPolicyOptions {
  /** 0 以上 1 未満の乱数。渡したときだけ、待機にジッタを入れる。省くと決定的。 */
  readonly random?: () => number;
}

/** 復帰できる配信の状態（http-api.md の POST /api/broadcasts/:id/ticket の発行条件）。 */
const RESUMABLE_STATES: ReadonlySet<BroadcastState> = new Set<BroadcastState>(["awaiting_media", "confirming", "live", "interrupted"]);

function assertNonNegativeSafeInteger(value: number, name: string): void {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new RangeError(`${name} must be a non-negative safe integer: ${String(value)}`);
  }
}

function assertServerView(view: ReconnectServerView): void {
  if (!isBroadcastState(view.state)) {
    throw new RangeError(`state is not a broadcast state (expected one of ${BROADCAST_STATE_VALUES.join(", ")}): ${String(view.state)}`);
  }
  if (typeof view.resumable !== "boolean") {
    throw new RangeError(`resumable must be a boolean: ${String(view.resumable)}`);
  }
}

export class ReconnectPolicy {
  private readonly random: (() => number) | undefined;

  constructor(options: ReconnectPolicyOptions = {}) {
    this.random = options.random;
  }

  /**
   * attempt 回目（0 始まり）の再試行の前に待つ時間（ミリ秒。整数）。
   * min(上限, 500 × 2^attempt)。注入した乱数があれば、最大 20% 短くする（乱数を、呼び出しごとに 1 回だけ引く）。
   */
  nextDelayMs(attempt: number): number {
    assertNonNegativeSafeInteger(attempt, "attempt");
    const exponential = INITIAL_DELAY_MS * DELAY_MULTIPLIER ** Math.min(attempt, MAX_DOUBLINGS);
    const delay = Math.min(LIMITS.deadlines.reconnect_backoff_cap_ms, exponential);
    if (this.random === undefined) {
      return delay;
    }
    const draw = this.random();
    if (!Number.isFinite(draw) || draw < 0 || draw >= 1) {
      throw new RangeError(`the injected random must return a number in [0, 1): ${String(draw)}`);
    }
    return Math.round(delay * (1 - JITTER_RATIO * draw));
  }

  /**
   * サーバーの見え方（配信の状態と、復帰できるか）と、これまでに復帰した回数から、再接続してよいかを判断する。
   * 優先順位：終了済み > 復帰できない（期限を過ぎた・受理済み） > 復帰の上限（10 回） > 再接続する。
   * 不正な入力（未知の状態・真偽値でない resumable・不正な回数）は、推測せず RangeError。
   */
  shouldReconnect(serverView: ReconnectServerView, resumesCompleted = 0): ReconnectDecision {
    assertServerView(serverView);
    assertNonNegativeSafeInteger(resumesCompleted, "resumesCompleted");

    const maxResumes = LIMITS.deadlines.max_resumes;
    const resumesRemaining = Math.max(0, maxResumes - resumesCompleted);
    const decide = (reconnect: boolean, reason: ReconnectReason): ReconnectDecision =>
      Object.freeze({ reconnect, reason, resumesRemaining, maxResumes });

    if (serverView.state === "ended") {
      return decide(false, "broadcast_ended");
    }
    if (!RESUMABLE_STATES.has(serverView.state) || !serverView.resumable) {
      return decide(false, "not_resumable");
    }
    if (resumesRemaining === 0) {
      return decide(false, "resume_limit_reached");
    }
    return decide(true, "resumable");
  }
}
