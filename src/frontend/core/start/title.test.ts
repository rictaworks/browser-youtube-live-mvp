/**
 * @jest-environment node
 */
// タイトルの規則（requirements.md 9.1・16.3・http-api.md の POST /api/broadcasts）。
//   1〜100 文字（Unicode のコードポイントの数）・山括弧（< と >）を含まない・空白のみは不可。文字数の残りを表示する。
import { TITLE_MAX_CODE_POINTS, countCodePoints, remainingChars, titleViolations } from "./title";

/** BMP の外の文字（CJK 統合漢字拡張 B。UTF-16 では 2 単位、コードポイントでは 1 つ）。絵文字ではない。 */
const ASTRAL = String.fromCodePoint(0x20bb7);
/** 結合文字（結合アクセント。基底の文字と合わせて 1 つの見た目だが、コードポイントは 2 つ）。 */
const COMBINING_ACUTE = String.fromCodePoint(0x301);
/** 全角の空白（U+3000）。 */
const IDEOGRAPHIC_SPACE = String.fromCodePoint(0x3000);
/** 孤立した上位サロゲート（対になる下位サロゲートが無い。UTF-8 のファイルには、文字として書けない）。 */
const LONE_SURROGATE = String.fromCharCode(0xd800);

describe("countCodePoints: Unicode のコードポイントの数（UTF-16 の長さではない）", () => {
  test.each<[string, string, number]>([
    ["空", "", 0],
    ["ASCII", "abc", 3],
    ["日本語（BMP）", "ライブ配信", 5],
    ["BMP の外の文字は 1 つ（UTF-16 では 2 単位）", ASTRAL, 1],
    ["BMP の外の文字 3 つ", ASTRAL.repeat(3), 3],
    ["結合文字は別のコードポイント（e と結合アクセントで 2）", `e${COMBINING_ACUTE}`, 2],
    ["孤立したサロゲートは 1 つ", `a${LONE_SURROGATE}b`, 3],
    ["空白も数える", "  a  ", 5],
    ["改行も数える", "a\nb", 3],
  ])("%s", (_label, text, expected) => {
    expect(countCodePoints(text)).toBe(expected);
  });

  test("UTF-16 の長さと異なる（BMP の外の文字を含む）", () => {
    expect(ASTRAL.length).toBe(2);
    expect(countCodePoints(ASTRAL)).toBe(1);
  });
});

describe("titleViolations: 9.1 の検証", () => {
  test.each<[string, string, readonly string[]]>([
    ["1 文字", "a", []],
    ["通常のタイトル", "ライブ配信 2026-10-07 13:30", []],
    ["100 文字（ASCII）", "a".repeat(100), []],
    ["100 文字（日本語）", "あ".repeat(100), []],
    ["100 コードポイント（UTF-16 では 200 単位）", ASTRAL.repeat(100), []],
    ["100 コードポイント（結合文字を含む）", `e${COMBINING_ACUTE}`.repeat(50), []],
    ["前後の空白も文字数に数える（3 文字）", " a ", []],
    ["全角の山括弧（U+FF1C・U+FF1E）は山括弧ではない", "＜全角＞", []],
    ["引用符・アンパサンドは許される", "A & B \"quote\" 'single'", []],
    ["空", "", ["blank"]],
    ["半角の空白のみ", "   ", ["blank"]],
    ["全角の空白のみ（U+3000）", IDEOGRAPHIC_SPACE.repeat(2), ["blank"]],
    ["タブと改行のみ", "\t\n\r", ["blank"]],
    ["101 文字（ASCII）", "a".repeat(101), ["too_long"]],
    ["101 文字（日本語）", "あ".repeat(101), ["too_long"]],
    ["101 コードポイント（BMP の外の文字）", ASTRAL.repeat(101), ["too_long"]],
    ["102 コードポイント（結合文字）", `e${COMBINING_ACUTE}`.repeat(51), ["too_long"]],
    ["< を含む", "a<b", ["angle_bracket"]],
    ["> を含む", "a>b", ["angle_bracket"]],
    ["<> だけ", "<>", ["angle_bracket"]],
    ["タグの形", "<script>alert(1)</script>", ["angle_bracket"]],
    ["先頭が <", "<a", ["angle_bracket"]],
    ["101 文字で < を含む：両方", `<${"a".repeat(100)}`, ["too_long", "angle_bracket"]],
  ])("%s", (_label, title, expected) => {
    expect(titleViolations(title)).toEqual(expected);
  });

  test("100 と 101 の境界（コードポイントで数える）", () => {
    expect(titleViolations("a".repeat(TITLE_MAX_CODE_POINTS))).toEqual([]);
    expect(titleViolations("a".repeat(TITLE_MAX_CODE_POINTS + 1))).toEqual(["too_long"]);
    expect(TITLE_MAX_CODE_POINTS).toBe(100);
  });

  test("文字列でない入力は、空と同じ（有効なタイトルになり得ない）", () => {
    expect(titleViolations(undefined as never)).toEqual(["blank"]);
    expect(titleViolations(null as never)).toEqual(["blank"]);
    expect(titleViolations(123 as never)).toEqual(["blank"]);
  });
});

describe("remainingChars: 文字数の残り（16.3）", () => {
  test.each<[string, string, number]>([
    ["空は 100", "", 100],
    ["3 文字は 97", "abc", 97],
    ["日本語 5 文字は 95", "ライブ配信", 95],
    ["100 文字は 0", "a".repeat(100), 0],
    ["101 文字は -1（超過した文字数を、負の数で返す）", "a".repeat(101), -1],
    ["150 文字は -50", "a".repeat(150), -50],
    ["BMP の外の文字は 1 文字として数える", ASTRAL.repeat(10), 90],
    ["空白も数える", "     ", 95],
  ])("%s", (_label, title, expected) => {
    expect(remainingChars(title)).toBe(expected);
  });

  test("文字列でない入力は、数を答えられないため RangeError", () => {
    expect(() => remainingChars(undefined as never)).toThrow(RangeError);
    expect(() => remainingChars(1 as never)).toThrow(RangeError);
  });
});
