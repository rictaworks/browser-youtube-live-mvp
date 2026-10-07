// ソースの状態機械（requirements.md 25.5）。5 状態：未取得・要求中・取得済み・拒否・喪失
// 遷移は、25.5 の図の矢印を 1 行ずつ、下の表に書いたもの。表に無い（状態, 事象）の組は、状態を変えない。
// 副作用を持たない（状態を保持しない）。ソースの取得の実装（SourceManager。#26）は、この規則を使い、規則を重複して持たない。

import { SOURCE_STATE_VALUES, isSourceState } from "../contract";
import type { SourceState } from "../contract";
import { defineTransitions, lookupNextState } from "./transitionTable";

/**
 * ソースの状態を動かす事象（25.5 の矢印の見出し）。
 *   request              取得を要求・再要求・再取得を要求（未取得・拒否・喪失 -> 要求中）
 *   granted              許可（要求中 -> 取得済み）
 *   denied               拒否（要求中 -> 拒否）
 *   selection_cancelled  選択の取り消し（要求中 -> 未取得）
 *   track_ended          トラックの終了（取得済み -> 喪失）
 *   release              解除（取得済み・喪失・拒否 -> 未取得）
 */
export const SOURCE_EVENT_VALUES = Object.freeze(["request", "granted", "denied", "selection_cancelled", "track_ended", "release"] as const);
export type SourceEvent = (typeof SOURCE_EVENT_VALUES)[number];

export function isSourceEvent(value: unknown): value is SourceEvent {
  return typeof value === "string" && (SOURCE_EVENT_VALUES as readonly string[]).includes(value);
}

/** ソースの初期状態（25.5 の [*] -> 未取得）。 */
export const INITIAL_SOURCE_STATE: SourceState = "detached";

const SOURCE_TRANSITIONS = defineTransitions<SourceState, SourceEvent>({
  detached: { request: "requesting" },
  requesting: { granted: "active", denied: "denied", selection_cancelled: "detached" },
  active: { track_ended: "lost", release: "detached" },
  denied: { request: "requesting", release: "detached" },
  lost: { request: "requesting", release: "detached" },
});

/**
 * 現在の状態に事象が起きたときの、次の状態を返す。定義のない組は、状態を変えない（同じ状態を返す）。
 * 未知の状態・未知の事象は、定義のない組ではなく、呼び出しの誤りなので、推測せず RangeError。
 */
export function transitionSource(state: SourceState, event: SourceEvent): SourceState {
  if (!isSourceState(state)) {
    throw new RangeError(`unknown source state (expected one of ${SOURCE_STATE_VALUES.join(", ")}): ${String(state)}`);
  }
  if (!isSourceEvent(event)) {
    throw new RangeError(`unknown source event (expected one of ${SOURCE_EVENT_VALUES.join(", ")}): ${String(event)}`);
  }
  return lookupNextState(SOURCE_TRANSITIONS, state, event);
}
