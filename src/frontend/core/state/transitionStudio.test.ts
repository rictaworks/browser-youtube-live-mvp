/**
 * @jest-environment node
 */
// スタジオの状態機械（requirements.md 25.3）。10 状態。遷移表を 1 行ずつ検査し、定義のない組は状態を変えないことも、全組で検査する。
// 期待する遷移表は、25.3 の図を、実装とは別に、ここへ書き写したもの（実装の表を読み込んで検査しない）。
import { STUDIO_STATE_VALUES } from "../contract";
import type { StudioState } from "../contract";
import { INITIAL_STUDIO_STATE, STUDIO_EVENT_VALUES, transitionStudio } from "./transitionStudio";
import type { StudioEvent } from "./transitionStudio";

interface Row {
  readonly from: StudioState;
  readonly event: StudioEvent;
  readonly to: StudioState;
  readonly label: string;
}

/** 25.3 の図の矢印。「致命通知・タイムアウト」と「期限の経過・配信レコードが終了済み」は、2 つの事象に分けて 1 行ずつ。 */
const ROWS: readonly Row[] = [
  { from: "idle", event: "start", to: "requesting", label: "待機 -> 受付中：配信を開始" },
  { from: "requesting", event: "rejected", to: "idle", label: "受付中 -> 待機：拒否（理由を表示）" },
  { from: "requesting", event: "accepted", to: "connecting", label: "受付中 -> 接続中：受理" },
  { from: "connecting", event: "connection_accepted", to: "probing", label: "接続中 -> 計測中：接続受理" },
  { from: "connecting", event: "connection_failed", to: "ended", label: "接続中 -> 終了：接続の不成立" },
  { from: "probing", event: "profile_selected", to: "starting", label: "計測中 -> 開始中：プロファイルを選定" },
  { from: "probing", event: "insufficient_bandwidth", to: "ended", label: "計測中 -> 終了：回線不足" },
  { from: "starting", event: "live_notified", to: "live", label: "開始中 -> 配信中：状態通知（ライブ）" },
  { from: "starting", event: "fatal_notice", to: "ended", label: "開始中 -> 終了：致命通知" },
  { from: "starting", event: "timeout", to: "ended", label: "開始中 -> 終了：タイムアウト" },
  { from: "live", event: "degraded_entered", to: "degraded", label: "配信中 -> 劣化：下限で逼迫が 20 秒継続" },
  { from: "degraded", event: "degraded_cleared", to: "live", label: "劣化 -> 配信中：滞留 1.5 秒以下が 10 秒継続" },
  { from: "live", event: "connection_lost", to: "reconnecting", label: "配信中 -> 再接続中：接続断・再接続条件" },
  { from: "degraded", event: "connection_lost", to: "reconnecting", label: "劣化 -> 再接続中：接続断・再接続条件" },
  { from: "reconnecting", event: "resumed", to: "live", label: "再接続中 -> 配信中：復帰" },
  { from: "reconnecting", event: "deadline_passed", to: "ended", label: "再接続中 -> 終了：期限の経過" },
  { from: "reconnecting", event: "broadcast_ended", to: "ended", label: "再接続中 -> 終了：配信レコードが終了済み" },
  { from: "requesting", event: "cancel", to: "stopping", label: "受付中 -> 停止中：取り消し" },
  { from: "connecting", event: "cancel", to: "stopping", label: "接続中 -> 停止中：取り消し" },
  { from: "probing", event: "cancel", to: "stopping", label: "計測中 -> 停止中：取り消し" },
  { from: "starting", event: "cancel", to: "stopping", label: "開始中 -> 停止中：取り消し" },
  { from: "live", event: "stop", to: "stopping", label: "配信中 -> 停止中：停止操作" },
  { from: "degraded", event: "stop", to: "stopping", label: "劣化 -> 停止中：停止操作" },
  { from: "reconnecting", event: "stop", to: "stopping", label: "再接続中 -> 停止中：停止操作" },
  { from: "live", event: "broadcast_ended", to: "ended", label: "配信中 -> 終了：状態通知（終了）" },
  { from: "degraded", event: "broadcast_ended", to: "ended", label: "劣化 -> 終了：状態通知（終了）" },
  { from: "stopping", event: "stop_confirmed", to: "ended", label: "停止中 -> 終了：終了の確定" },
  { from: "ended", event: "display_closed", to: "idle", label: "終了 -> 待機：終了時の表示を閉じる" },
];

function isDefined(from: StudioState, event: StudioEvent): boolean {
  return ROWS.some((row) => row.from === from && row.event === event);
}

describe("スタジオの状態機械：状態と事象", () => {
  test("10 状態（契約の列挙 studio_state）。初期状態は待機", () => {
    expect(STUDIO_STATE_VALUES).toHaveLength(10);
    expect([...STUDIO_STATE_VALUES]).toEqual(["idle", "requesting", "connecting", "probing", "starting", "live", "degraded", "reconnecting", "stopping", "ended"]);
    expect(INITIAL_STUDIO_STATE).toBe("idle");
  });

  test("事象は 20 種で、重複せず、英小文字の snake_case。凍結されている", () => {
    expect(STUDIO_EVENT_VALUES).toHaveLength(20);
    expect(new Set(STUDIO_EVENT_VALUES).size).toBe(20);
    for (const event of STUDIO_EVENT_VALUES) {
      expect(event).toMatch(/^[a-z]+(_[a-z]+)*$/);
    }
    expect(Object.isFrozen(STUDIO_EVENT_VALUES)).toBe(true);
  });

  test("書き写した遷移表は 28 行で、重複する（状態, 事象）の組が無い", () => {
    expect(ROWS).toHaveLength(28);
    const keys = new Set(ROWS.map((row) => `${row.from}/${row.event}`));
    expect(keys.size).toBe(28);
  });

  test("遷移表に現れる事象は、すべて事象の一覧にあり、一覧の事象は、遷移表のどれかに現れる", () => {
    const used = new Set(ROWS.map((row) => row.event));
    expect([...used].sort()).toEqual([...STUDIO_EVENT_VALUES].sort());
  });
});

describe("transitionStudio: 定義のある遷移（25.3 の表を 1 行ずつ）", () => {
  test.each(ROWS.map((row) => [row.label, row.from, row.event, row.to] as const))("%s", (_label, from, event, to) => {
    expect(transitionStudio(from, event)).toBe(to);
  });
});

describe("transitionStudio: 定義のない組は、状態を変えない（全組を検査）", () => {
  test("状態 10 × 事象 20 = 200 組のうち、表に無い 172 組は、すべて同じ状態を返す", () => {
    const changed: string[] = [];
    let undefinedPairs = 0;
    for (const from of STUDIO_STATE_VALUES) {
      for (const event of STUDIO_EVENT_VALUES) {
        if (isDefined(from, event)) {
          continue;
        }
        undefinedPairs += 1;
        if (transitionStudio(from, event) !== from) {
          changed.push(`${from}/${event}`);
        }
      }
    }
    expect(changed).toEqual([]);
    expect(undefinedPairs).toBe(200 - 28);
  });

  test.each<[string, StudioState, StudioEvent]>([
    ["待機で停止操作（配信が無い）", "idle", "stop"],
    ["待機で取り消し", "idle", "cancel"],
    ["配信中で取り消し（取り消しは、ライブ確定前のみ。ライブ後は停止操作）", "live", "cancel"],
    ["受付中で停止操作（ライブ前は取り消し）", "requesting", "stop"],
    ["配信中でプロファイルを選定（二重の通知）", "live", "profile_selected"],
    ["停止中に接続断（停止の途中で、再接続しない）", "stopping", "connection_lost"],
    ["停止中に状態通知（終了）（終了の確定を待つ。確定は stop_confirmed）", "stopping", "broadcast_ended"],
    ["終了したあとに接続断", "ended", "connection_lost"],
    ["終了したあとに停止操作", "ended", "stop"],
    ["再接続中に劣化の通知（再接続が先）", "reconnecting", "degraded_entered"],
    ["配信中に復帰の通知（二重の通知）", "live", "resumed"],
    ["開始中に期限の経過（開始中の期限は timeout）", "starting", "deadline_passed"],
    ["接続中に致命通知（接続の不成立として通知される）", "connecting", "fatal_notice"],
  ])("%s：状態は変わらない", (_label, from, event) => {
    expect(isDefined(from, event)).toBe(false);
    expect(transitionStudio(from, event)).toBe(from);
  });
});

describe("transitionStudio: 状態の流れ", () => {
  function run(events: readonly StudioEvent[], from: StudioState = INITIAL_STUDIO_STATE): StudioState {
    return events.reduce<StudioState>((state, event) => transitionStudio(state, event), from);
  }

  test("正常な開始から停止まで：待機 -> 受付中 -> 接続中 -> 計測中 -> 開始中 -> 配信中 -> 停止中 -> 終了 -> 待機", () => {
    const path: StudioState[] = [INITIAL_STUDIO_STATE];
    for (const event of ["start", "accepted", "connection_accepted", "profile_selected", "live_notified", "stop", "stop_confirmed", "display_closed"] as const) {
      path.push(transitionStudio(path[path.length - 1], event));
    }
    expect(path).toEqual(["idle", "requesting", "connecting", "probing", "starting", "live", "stopping", "ended", "idle"]);
  });

  test("劣化と再接続：配信中 <-> 劣化、配信中 -> 再接続中 -> 配信中、劣化 -> 再接続中 -> 配信中", () => {
    expect(run(["degraded_entered", "degraded_cleared"], "live")).toBe("live");
    expect(run(["connection_lost", "resumed"], "live")).toBe("live");
    expect(run(["degraded_entered", "connection_lost", "resumed"], "live")).toBe("live");
  });

  test("拒否・回線不足・接続の不成立・取り消し・タイムアウト・期限の経過は、最後に待機へ戻れる（終了 -> 待機）", () => {
    expect(run(["start", "rejected"])).toBe("idle");
    expect(run(["start", "accepted", "connection_accepted", "insufficient_bandwidth", "display_closed"])).toBe("idle");
    expect(run(["start", "accepted", "connection_failed", "display_closed"])).toBe("idle");
    expect(run(["start", "accepted", "cancel", "stop_confirmed", "display_closed"])).toBe("idle");
    expect(run(["start", "accepted", "connection_accepted", "profile_selected", "timeout", "display_closed"])).toBe("idle");
    expect(run(["connection_lost", "deadline_passed", "display_closed"], "live")).toBe("idle");
  });

  test("遷移表から、待機から全 10 状態へ到達でき、どの状態からも待機へ戻れる（行き止まりが無い）", () => {
    const next = (state: StudioState): StudioState[] => ROWS.filter((row) => row.from === state).map((row) => row.to);
    const reach = (start: StudioState): Set<StudioState> => {
      const seen = new Set<StudioState>([start]);
      const queue: StudioState[] = [start];
      while (queue.length > 0) {
        const state = queue.shift() as StudioState;
        for (const target of next(state)) {
          if (!seen.has(target)) {
            seen.add(target);
            queue.push(target);
          }
        }
      }
      return seen;
    };
    expect(reach("idle").size).toBe(10);
    for (const state of STUDIO_STATE_VALUES) {
      expect(reach(state).has("idle")).toBe(true);
    }
  });
});

describe("transitionStudio: 不正な入力（推測せず RangeError）", () => {
  test.each([
    ["未知の状態", "paused", "start"],
    ["状態が数値", 1, "start"],
    ["未知の事象", "idle", "launch"],
    ["事象が undefined", "idle", undefined],
    ["大文字の事象", "idle", "START"],
    ["Object のプロパティの名前", "idle", "constructor"],
  ])("%s", (_label, state, event) => {
    expect(() => transitionStudio(state as never, event as never)).toThrow(RangeError);
  });

  test("状態を保持しない（純粋）：同じ入力に、いつも同じ出力", () => {
    expect(transitionStudio("idle", "start")).toBe("requesting");
    expect(transitionStudio("idle", "start")).toBe("requesting");
    expect(transitionStudio("idle", "stop")).toBe("idle");
  });
});
