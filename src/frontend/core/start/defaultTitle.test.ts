/**
 * @jest-environment node
 */
// 既定のタイトル（requirements.md 9.1：「ライブ配信」に日時を付した文字列）。
// ラベル（「ライブ配信」）は文言カタログ由来で、引数で受け取る（Domain Core は、利用者に表示する文字列を持たない）。
// 日時は JST の「YYYY-MM-DD HH:mm」。時刻は引数（エポックからのミリ秒）で、現在時刻を参照しない。
import { defaultTitle } from "./defaultTitle";
import { remainingChars, titleViolations } from "./title";

const EXAMPLE_NOW = 1_791_347_400_000; // 2026-10-07T04:30:00Z = JST 2026-10-07 13:30

describe("defaultTitle", () => {
  test("ラベルに、半角の空白と JST の日時を付す（http-api.md の例と同じ形）", () => {
    expect(defaultTitle(EXAMPLE_NOW, "ライブ配信")).toBe("ライブ配信 2026-10-07 13:30");
  });

  test.each<[string, number, string, string]>([
    ["日付をまたぐ直前", 1_791_298_799_999, "label", "label 2026-10-06 23:59"],
    ["日付をまたぐ瞬間", 1_791_298_800_000, "label", "label 2026-10-07 00:00"],
    ["うるう日", 1_835_362_800_000, "A", "A 2028-02-29 00:00"],
    ["ラベルに空白を含む", EXAMPLE_NOW, "Live stream", "Live stream 2026-10-07 13:30"],
  ])("%s", (_label, now, label, expected) => {
    expect(defaultTitle(now, label)).toBe(expected);
  });

  test("同じ入力に、いつも同じ出力（現在時刻を参照しない）", () => {
    expect(defaultTitle(EXAMPLE_NOW, "x")).toBe(defaultTitle(EXAMPLE_NOW, "x"));
    expect(defaultTitle(EXAMPLE_NOW + 60_000, "x")).toBe("x 2026-10-07 13:31");
  });

  test("できあがったタイトルは、9.1 の検証を満たす（1〜100 文字・山括弧なし）。文字数の残りは、日時（16 文字）と空白（1 文字）の分だけ減る", () => {
    const title = defaultTitle(EXAMPLE_NOW, "ライブ配信");
    expect(titleViolations(title)).toEqual([]);
    expect(remainingChars(title)).toBe(100 - 5 - 1 - 16);
  });

  test("ラベルが 83 文字なら、ちょうど 100 文字で有効。84 文字なら、100 文字を超えるため RangeError（カタログの誤りを、利用者の画面に出す前に見つける）", () => {
    const ok = defaultTitle(EXAMPLE_NOW, "あ".repeat(83));
    expect(titleViolations(ok)).toEqual([]);
    expect(remainingChars(ok)).toBe(0);
    expect(() => defaultTitle(EXAMPLE_NOW, "あ".repeat(84))).toThrow(RangeError);
  });

  test.each([
    ["空のラベル", ""],
    ["空白のみのラベル", "   "],
    ["山括弧を含むラベル", "<b>live</b>"],
  ])("%s は、無効なタイトルになるため RangeError", (_label, label) => {
    expect(() => defaultTitle(EXAMPLE_NOW, label)).toThrow(RangeError);
  });

  test("ラベルが文字列でなければ RangeError。時刻が不正（NaN・無限大・数値でない）でも RangeError", () => {
    expect(() => defaultTitle(EXAMPLE_NOW, undefined as never)).toThrow(RangeError);
    expect(() => defaultTitle(EXAMPLE_NOW, 5 as never)).toThrow(RangeError);
    expect(() => defaultTitle(Number.NaN, "x")).toThrow(RangeError);
    expect(() => defaultTitle(Number.POSITIVE_INFINITY, "x")).toThrow(RangeError);
    expect(() => defaultTitle("2026" as never, "x")).toThrow(RangeError);
  });
});
