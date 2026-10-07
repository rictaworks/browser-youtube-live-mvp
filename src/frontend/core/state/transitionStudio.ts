// スタジオの状態機械（requirements.md 25.3・15 章「配信の状態遷移」の、ブラウザ側）。10 状態：
//   待機・受付中・接続中・計測中・開始中・配信中・劣化・再接続中・停止中・終了
// 遷移は、25.3 の図の矢印を 1 行ずつ、下の表に書いたもの。表に無い（状態, 事象）の組は、状態を変えない。
// 副作用を持たない（状態を保持しない。呼び出し側が、現在の状態と事象を渡し、次の状態を受け取る）。

import { STUDIO_STATE_VALUES, isStudioState } from "../contract";
import type { StudioState } from "../contract";
import { defineTransitions, lookupNextState } from "./transitionTable";

/**
 * スタジオの状態を動かす事象（25.3 の矢印の見出し）。
 *   start                  配信を開始（待機 -> 受付中）
 *   rejected               拒否（受付中 -> 待機。理由を表示）
 *   accepted               受理（受付中 -> 接続中）
 *   connection_accepted    接続受理（接続中 -> 計測中）
 *   connection_failed      接続の不成立（接続中 -> 終了）
 *   profile_selected       プロファイルを選定（計測中 -> 開始中）
 *   insufficient_bandwidth 回線不足（計測中 -> 終了）
 *   live_notified          状態通知（ライブ）（開始中 -> 配信中）
 *   fatal_notice           致命通知（開始中 -> 終了）
 *   timeout                タイムアウト（開始中 -> 終了）
 *   degraded_entered       下限で逼迫が 20 秒継続（配信中 -> 劣化）
 *   degraded_cleared       滞留 1.5 秒以下が 10 秒継続（劣化 -> 配信中）
 *   connection_lost        接続断・再接続条件（配信中・劣化 -> 再接続中）
 *   resumed                復帰（再接続中 -> 配信中）
 *   deadline_passed        期限の経過（再接続中 -> 終了）
 *   broadcast_ended        状態通知（終了）・配信レコードが終了済み（配信中・劣化・再接続中 -> 終了）
 *   cancel                 取り消し（受付中・接続中・計測中・開始中 -> 停止中。ライブ確定前）
 *   stop                   停止操作（配信中・劣化・再接続中 -> 停止中）
 *   stop_confirmed         終了の確定（停止中 -> 終了）
 *   display_closed         終了時の表示を閉じる（終了 -> 待機）
 */
export const STUDIO_EVENT_VALUES = Object.freeze([
  "start",
  "rejected",
  "accepted",
  "connection_accepted",
  "connection_failed",
  "profile_selected",
  "insufficient_bandwidth",
  "live_notified",
  "fatal_notice",
  "timeout",
  "degraded_entered",
  "degraded_cleared",
  "connection_lost",
  "resumed",
  "deadline_passed",
  "broadcast_ended",
  "cancel",
  "stop",
  "stop_confirmed",
  "display_closed",
] as const);
export type StudioEvent = (typeof STUDIO_EVENT_VALUES)[number];

export function isStudioEvent(value: unknown): value is StudioEvent {
  return typeof value === "string" && (STUDIO_EVENT_VALUES as readonly string[]).includes(value);
}

/** スタジオの初期状態（25.3 の [*] -> 待機）。 */
export const INITIAL_STUDIO_STATE: StudioState = "idle";

const STUDIO_TRANSITIONS = defineTransitions<StudioState, StudioEvent>({
  idle: { start: "requesting" },
  requesting: { rejected: "idle", accepted: "connecting", cancel: "stopping" },
  connecting: { connection_accepted: "probing", connection_failed: "ended", cancel: "stopping" },
  probing: { profile_selected: "starting", insufficient_bandwidth: "ended", cancel: "stopping" },
  starting: { live_notified: "live", fatal_notice: "ended", timeout: "ended", cancel: "stopping" },
  live: { degraded_entered: "degraded", connection_lost: "reconnecting", stop: "stopping", broadcast_ended: "ended" },
  degraded: { degraded_cleared: "live", connection_lost: "reconnecting", stop: "stopping", broadcast_ended: "ended" },
  reconnecting: { resumed: "live", deadline_passed: "ended", broadcast_ended: "ended", stop: "stopping" },
  stopping: { stop_confirmed: "ended" },
  ended: { display_closed: "idle" },
});

/**
 * 現在の状態に事象が起きたときの、次の状態を返す。定義のない組は、状態を変えない（同じ状態を返す）。
 * 未知の状態・未知の事象は、定義のない組ではなく、呼び出しの誤りなので、推測せず RangeError。
 */
export function transitionStudio(state: StudioState, event: StudioEvent): StudioState {
  if (!isStudioState(state)) {
    throw new RangeError(`unknown studio state (expected one of ${STUDIO_STATE_VALUES.join(", ")}): ${String(state)}`);
  }
  if (!isStudioEvent(event)) {
    throw new RangeError(`unknown studio event (expected one of ${STUDIO_EVENT_VALUES.join(", ")}): ${String(event)}`);
  }
  return lookupNextState(STUDIO_TRANSITIONS, state, event);
}
