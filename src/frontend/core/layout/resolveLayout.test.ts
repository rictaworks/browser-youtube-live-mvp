/**
 * @jest-environment node
 */
// レイアウトの解決（requirements.md 11.3）。有効な映像ソース（取得済み = active）の組から、レイアウトが一意に決まる。
import { LAYOUT_VALUES, SOURCE_STATE_VALUES } from "../contract";
import type { Layout, SourceState } from "../contract";
import { resolveLayout } from "./resolveLayout";

describe("resolveLayout: 11.3 の表", () => {
  test.each<[string, SourceState, SourceState, Layout]>([
    ["画面共有あり・カメラあり", "active", "active", "screen_with_wipe"],
    ["画面共有あり・カメラなし", "active", "detached", "screen_only"],
    ["画面共有なし・カメラあり", "detached", "active", "camera_only"],
    ["画面共有なし・カメラなし", "detached", "detached", "slate"],
  ])("%s -> %s", (_label, screen, camera, expected) => {
    expect(resolveLayout({ screen, camera })).toBe(expected);
  });

  test.each<[string, SourceState, SourceState, Layout]>([
    ["画面共有を喪失（カメラは取得済み）：カメラのみ", "lost", "active", "camera_only"],
    ["カメラを喪失（画面共有は取得済み）：画面共有のみ", "active", "lost", "screen_only"],
    ["画面共有もカメラも喪失：代替スレート（全映像ソースの喪失）", "lost", "lost", "slate"],
    ["画面共有を拒否・カメラは取得済み：カメラのみ", "denied", "active", "camera_only"],
    ["画面共有は取得済み・カメラを拒否：画面共有のみ", "active", "denied", "screen_only"],
    ["両方とも拒否（権限がすべて拒否された状態）：代替スレート", "denied", "denied", "slate"],
    ["画面共有を要求中（まだ映像が無い）・カメラは取得済み：カメラのみ", "requesting", "active", "camera_only"],
    ["画面共有は取得済み・カメラを要求中：画面共有のみ", "active", "requesting", "screen_only"],
  ])("%s", (_label, screen, camera, expected) => {
    expect(resolveLayout({ screen, camera })).toBe(expected);
  });

  test("active のときだけ有効な映像ソースとして数える（5 × 5 の全組み合わせ。lost・denied・requesting・detached は数えない）", () => {
    const mismatches: string[] = [];
    for (const screen of SOURCE_STATE_VALUES) {
      for (const camera of SOURCE_STATE_VALUES) {
        const screenCounts = screen === "active";
        const cameraCounts = camera === "active";
        let expected: Layout = "slate";
        if (screenCounts && cameraCounts) {
          expected = "screen_with_wipe";
        } else if (screenCounts) {
          expected = "screen_only";
        } else if (cameraCounts) {
          expected = "camera_only";
        }
        if (resolveLayout({ screen, camera }) !== expected) {
          mismatches.push(`${screen} / ${camera}`);
        }
      }
    }
    expect(mismatches).toEqual([]);
    expect(SOURCE_STATE_VALUES).toHaveLength(5);
  });

  test("4 つのレイアウトが、すべて到達できる（契約の列挙 layout と一致）", () => {
    const reached = new Set<Layout>();
    for (const screen of SOURCE_STATE_VALUES) {
      for (const camera of SOURCE_STATE_VALUES) {
        reached.add(resolveLayout({ screen, camera }));
      }
    }
    expect([...reached].sort()).toEqual([...LAYOUT_VALUES].sort());
  });

  test("入力を変更しない（同じ入力に、いつも同じ出力）", () => {
    const sources = Object.freeze({ screen: "active", camera: "lost" } as const);
    expect(resolveLayout(sources)).toBe("screen_only");
    expect(resolveLayout(sources)).toBe("screen_only");
    expect(sources).toEqual({ screen: "active", camera: "lost" });
  });

  test.each([
    ["未知の状態（画面共有）", { screen: "unknown", camera: "active" }],
    ["未知の状態（カメラ）", { screen: "active", camera: "ACTIVE" }],
    ["状態が無い（カメラ）", { screen: "active" }],
    ["状態が数値", { screen: 1, camera: "active" }],
  ])("不正な入力（%s）は、状態を推測せず RangeError", (_label, sources) => {
    expect(() => resolveLayout(sources as never)).toThrow(RangeError);
  });
});
