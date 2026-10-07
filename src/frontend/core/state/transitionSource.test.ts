/**
 * @jest-environment node
 */
// ソースの状態機械（requirements.md 25.5）。5 状態（未取得・要求中・取得済み・拒否・喪失）。
// 期待する遷移表は、25.5 の図を、実装とは別に、ここへ書き写したもの。定義のない組は状態を変えない（全組を検査する）。
import { SOURCE_STATE_VALUES } from "../contract";
import type { SourceState } from "../contract";
import { INITIAL_SOURCE_STATE, SOURCE_EVENT_VALUES, transitionSource } from "./transitionSource";
import type { SourceEvent } from "./transitionSource";

interface Row {
  readonly from: SourceState;
  readonly event: SourceEvent;
  readonly to: SourceState;
  readonly label: string;
}

/** 25.5 の図の矢印（10 本）。「再要求」「再取得を要求」は、取得を要求と同じ事象 request。 */
const ROWS: readonly Row[] = [
  { from: "detached", event: "request", to: "requesting", label: "未取得 -> 要求中：取得を要求" },
  { from: "requesting", event: "granted", to: "active", label: "要求中 -> 取得済み：許可" },
  { from: "requesting", event: "denied", to: "denied", label: "要求中 -> 拒否：拒否" },
  { from: "requesting", event: "selection_cancelled", to: "detached", label: "要求中 -> 未取得：選択の取り消し" },
  { from: "denied", event: "request", to: "requesting", label: "拒否 -> 要求中：再要求" },
  { from: "active", event: "track_ended", to: "lost", label: "取得済み -> 喪失：トラックの終了" },
  { from: "active", event: "release", to: "detached", label: "取得済み -> 未取得：解除" },
  { from: "lost", event: "request", to: "requesting", label: "喪失 -> 要求中：再取得を要求" },
  { from: "lost", event: "release", to: "detached", label: "喪失 -> 未取得：解除" },
  { from: "denied", event: "release", to: "detached", label: "拒否 -> 未取得：解除" },
];

function isDefined(from: SourceState, event: SourceEvent): boolean {
  return ROWS.some((row) => row.from === from && row.event === event);
}

describe("ソースの状態機械：状態と事象", () => {
  test("5 状態（契約の列挙 source_state）。初期状態は未取得", () => {
    expect(SOURCE_STATE_VALUES).toHaveLength(5);
    expect([...SOURCE_STATE_VALUES]).toEqual(["detached", "requesting", "active", "denied", "lost"]);
    expect(INITIAL_SOURCE_STATE).toBe("detached");
  });

  test("事象は 6 種で、重複せず、英小文字の snake_case。凍結されている", () => {
    expect([...SOURCE_EVENT_VALUES]).toEqual(["request", "granted", "denied", "selection_cancelled", "track_ended", "release"]);
    expect(new Set(SOURCE_EVENT_VALUES).size).toBe(6);
    expect(Object.isFrozen(SOURCE_EVENT_VALUES)).toBe(true);
  });

  test("書き写した遷移表は 10 行で、重複する組が無い", () => {
    expect(ROWS).toHaveLength(10);
    expect(new Set(ROWS.map((row) => `${row.from}/${row.event}`)).size).toBe(10);
  });
});

describe("transitionSource: 定義のある遷移（25.5 の表を 1 行ずつ）", () => {
  test.each(ROWS.map((row) => [row.label, row.from, row.event, row.to] as const))("%s", (_label, from, event, to) => {
    expect(transitionSource(from, event)).toBe(to);
  });
});

describe("transitionSource: 定義のない組は、状態を変えない（全組を検査）", () => {
  test("状態 5 × 事象 6 = 30 組のうち、表に無い 20 組は、すべて同じ状態を返す", () => {
    const changed: string[] = [];
    let undefinedPairs = 0;
    for (const from of SOURCE_STATE_VALUES) {
      for (const event of SOURCE_EVENT_VALUES) {
        if (isDefined(from, event)) {
          continue;
        }
        undefinedPairs += 1;
        if (transitionSource(from, event) !== from) {
          changed.push(`${from}/${event}`);
        }
      }
    }
    expect(changed).toEqual([]);
    expect(undefinedPairs).toBe(30 - 10);
  });

  test.each<[string, SourceState, SourceEvent]>([
    ["取得済みで再要求（要求は、未取得・拒否・喪失からだけ）", "active", "request"],
    ["要求中に再要求（二重の要求）", "requesting", "request"],
    ["未取得で許可の通知（要求していない）", "detached", "granted"],
    ["取得済みでトラックの終了の二重の通知（喪失のまま）", "lost", "track_ended"],
    ["喪失で許可の通知（要求し直してから）", "lost", "granted"],
    ["未取得で解除（何もしない）", "detached", "release"],
    ["要求中に解除（選択の取り消しで未取得へ戻る。解除は取得済み・喪失・拒否から）", "requesting", "release"],
    ["拒否のまま許可の通知（再要求してから）", "denied", "granted"],
    ["取得済みで拒否の通知（取得済みを奪わない）", "active", "denied"],
  ])("%s：状態は変わらない", (_label, from, event) => {
    expect(isDefined(from, event)).toBe(false);
    expect(transitionSource(from, event)).toBe(from);
  });
});

describe("transitionSource: 状態の流れ", () => {
  function run(events: readonly SourceEvent[], from: SourceState = INITIAL_SOURCE_STATE): SourceState {
    return events.reduce<SourceState>((state, event) => transitionSource(state, event), from);
  }

  test("取得 -> 許可 -> トラックの終了 -> 再取得 -> 許可 -> 解除", () => {
    const path: SourceState[] = [INITIAL_SOURCE_STATE];
    for (const event of ["request", "granted", "track_ended", "request", "granted", "release"] as const) {
      path.push(transitionSource(path[path.length - 1], event));
    }
    expect(path).toEqual(["detached", "requesting", "active", "lost", "requesting", "active", "detached"]);
  });

  test("拒否 -> 再要求 -> 選択の取り消し -> 未取得、拒否 -> 解除 -> 未取得", () => {
    expect(run(["request", "denied", "request", "selection_cancelled"])).toBe("detached");
    expect(run(["request", "denied", "release"])).toBe("detached");
  });

  test("遷移表から、未取得から全 5 状態へ到達でき、どの状態からも未取得へ戻れる", () => {
    const reach = (start: SourceState): Set<SourceState> => {
      const seen = new Set<SourceState>([start]);
      const queue: SourceState[] = [start];
      while (queue.length > 0) {
        const state = queue.shift() as SourceState;
        for (const row of ROWS.filter((candidate) => candidate.from === state)) {
          if (!seen.has(row.to)) {
            seen.add(row.to);
            queue.push(row.to);
          }
        }
      }
      return seen;
    };
    expect(reach("detached").size).toBe(5);
    for (const state of SOURCE_STATE_VALUES) {
      expect(reach(state).has("detached")).toBe(true);
    }
  });
});

describe("transitionSource: 不正な入力（推測せず RangeError）", () => {
  test.each([
    ["未知の状態", "idle", "request"],
    ["状態が undefined", undefined, "request"],
    ["未知の事象", "detached", "attach"],
    ["事象が数値", "detached", 1],
    ["Object のプロパティの名前", "detached", "toString"],
  ])("%s", (_label, state, event) => {
    expect(() => transitionSource(state as never, event as never)).toThrow(RangeError);
  });
});
