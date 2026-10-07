/**
 * @jest-environment node
 */
// 開始入力の検証（requirements.md 9.1・16.3）。
//   タイトル：1〜100 文字（コードポイント）・山括弧を含まない・空白のみは不可
//   公開範囲：公開（public）・限定公開（unlisted）・非公開（private）の 3 値。既定は限定公開
//   子ども向けの申告：はい・いいえ。未選択は不可（利用者の明示的な選択を必須とする）
// 不備のある項目の名前は、サーバーの拒否（invalid_input の fields）と同じ（title・privacy_status・made_for_kids）。
import { DEFAULT_PRIVACY_STATUS, PRIVACY_STATUS_VALUES, validateStartInput } from "./validateStartInput";
import type { StartInputError, StartInputValidation } from "./validateStartInput";

/** BMP の外の文字（CJK 統合漢字拡張 B）。絵文字ではない。 */
const ASTRAL = String.fromCodePoint(0x20bb7);
/** 全角の空白（U+3000）。 */
const IDEOGRAPHIC_SPACE = String.fromCodePoint(0x3000);

function errorsOf(result: StartInputValidation): readonly StartInputError[] {
  return result.valid ? [] : result.errors;
}

describe("validateStartInput: 有効な入力", () => {
  test.each<[string, string, string, boolean]>([
    ["通常（限定公開・子ども向けでない）", "ライブ配信 2026-10-07 13:30", "unlisted", false],
    ["公開・子ども向け", "Live", "public", true],
    ["非公開", "x", "private", false],
    ["100 文字ちょうど", "a".repeat(100), "unlisted", false],
    ["100 コードポイント（BMP の外の文字）", ASTRAL.repeat(100), "unlisted", true],
    ["全角の山括弧は許される", "＜全角＞", "unlisted", false],
    ["前後に空白があっても、空白だけでなければ有効（値は変更しない）", "  title  ", "unlisted", false],
  ])("%s", (_label, title, privacyStatus, madeForKids) => {
    const result = validateStartInput({ title, privacyStatus, madeForKids });
    expect(result).toEqual({ valid: true, value: { title, privacyStatus, madeForKids } });
  });

  test("子ども向けの申告は、いいえ（false）も、有効な選択（未選択ではない）", () => {
    expect(validateStartInput({ title: "t", privacyStatus: "unlisted", madeForKids: false }).valid).toBe(true);
    expect(validateStartInput({ title: "t", privacyStatus: "unlisted", madeForKids: true }).valid).toBe(true);
  });
});

describe("validateStartInput: タイトルの不備", () => {
  test.each<[string, string, readonly string[]]>([
    ["空", "", ["title_blank"]],
    ["空白のみ", "   ", ["title_blank"]],
    ["全角の空白のみ", IDEOGRAPHIC_SPACE, ["title_blank"]],
    ["101 文字", "a".repeat(101), ["title_too_long"]],
    ["101 コードポイント（BMP の外の文字）", ASTRAL.repeat(101), ["title_too_long"]],
    ["山括弧 <", "a<b", ["title_has_angle_bracket"]],
    ["山括弧 >", "a>b", ["title_has_angle_bracket"]],
    ["長すぎて、山括弧も含む", `>${"a".repeat(100)}`, ["title_too_long", "title_has_angle_bracket"]],
  ])("%s -> %j", (_label, title, expectedCodes) => {
    const result = validateStartInput({ title, privacyStatus: "unlisted", madeForKids: false });
    expect(result.valid).toBe(false);
    expect(errorsOf(result)).toEqual(expectedCodes.map((code) => ({ field: "title", code })));
  });

  test("文字列でないタイトルは、空と同じ（有効になり得ない）", () => {
    for (const title of [undefined, null, 42, {}]) {
      const result = validateStartInput({ title: title as never, privacyStatus: "unlisted", madeForKids: false });
      expect(errorsOf(result)).toEqual([{ field: "title", code: "title_blank" }]);
    }
  });
});

describe("validateStartInput: 公開範囲の不備", () => {
  test.each([
    ["空", ""],
    ["大文字", "PUBLIC"],
    ["前後に空白", " public"],
    ["未知の値", "friends"],
    ["日本語の表示名（符号ではない）", "限定公開"],
    ["undefined", undefined],
    ["null", null],
    ["数値", 1],
  ])("%s は privacy_status の不備", (_label, privacyStatus) => {
    const result = validateStartInput({ title: "t", privacyStatus: privacyStatus as never, madeForKids: false });
    expect(errorsOf(result)).toEqual([{ field: "privacy_status", code: "privacy_status_invalid" }]);
  });

  test("3 値と既定値", () => {
    expect([...PRIVACY_STATUS_VALUES]).toEqual(["public", "unlisted", "private"]);
    expect(DEFAULT_PRIVACY_STATUS).toBe("unlisted"); // 既定は限定公開（9.1・16.3）
    for (const privacyStatus of PRIVACY_STATUS_VALUES) {
      expect(validateStartInput({ title: "t", privacyStatus, madeForKids: false }).valid).toBe(true);
    }
  });
});

describe("validateStartInput: 子ども向けの申告（未選択は不可）", () => {
  test.each([
    ["null（未選択）", null],
    ["undefined（未選択）", undefined],
    ["文字列 \"true\"（真偽値ではない）", "true"],
    ["文字列 \"false\"", "false"],
    ["数値 1", 1],
    ["数値 0", 0],
    ["空文字", ""],
  ])("%s は made_for_kids の不備", (_label, madeForKids) => {
    const result = validateStartInput({ title: "t", privacyStatus: "unlisted", madeForKids: madeForKids as never });
    expect(errorsOf(result)).toEqual([{ field: "made_for_kids", code: "made_for_kids_unselected" }]);
  });
});

describe("validateStartInput: 複数の不備", () => {
  test("すべて不備なら、項目の順（title・privacy_status・made_for_kids）に、すべて返す。最初の 1 件だけで止めない", () => {
    const result = validateStartInput({ title: "", privacyStatus: "friends", madeForKids: null });
    expect(errorsOf(result)).toEqual([
      { field: "title", code: "title_blank" },
      { field: "privacy_status", code: "privacy_status_invalid" },
      { field: "made_for_kids", code: "made_for_kids_unselected" },
    ]);
  });

  test("タイトルと申告が不備（公開範囲は有効）", () => {
    const result = validateStartInput({ title: "<", privacyStatus: "private", madeForKids: null });
    expect(errorsOf(result).map((error) => error.field)).toEqual(["title", "made_for_kids"]);
  });

  test("不備の項目の名前は、サーバーの拒否（invalid_input の fields）と同じ 3 つだけ", () => {
    const fields = new Set(errorsOf(validateStartInput({ title: "", privacyStatus: "x", madeForKids: null })).map((error) => error.field));
    expect([...fields].sort()).toEqual(["made_for_kids", "privacy_status", "title"]);
  });
});

describe("validateStartInput: 純粋さ", () => {
  test("入力を変更しない。結果は変更できない（凍結）。同じ入力に、いつも同じ出力", () => {
    const input = Object.freeze({ title: "t", privacyStatus: "unlisted", madeForKids: false });
    const valid = validateStartInput(input);
    expect(Object.isFrozen(valid)).toBe(true);
    if (valid.valid) {
      expect(Object.isFrozen(valid.value)).toBe(true);
    }
    expect(validateStartInput(input)).toEqual(valid);

    const invalid = validateStartInput({ title: "", privacyStatus: "unlisted", madeForKids: null });
    expect(Object.isFrozen(invalid)).toBe(true);
    if (!invalid.valid) {
      expect(Object.isFrozen(invalid.errors)).toBe(true);
    }
  });

  test("検証した値は、入力と別のオブジェクト（呼び出し側の後の変更の影響を受けない）", () => {
    const input = { title: "t", privacyStatus: "unlisted", madeForKids: false };
    const result = validateStartInput(input);
    input.title = "changed";
    expect(result.valid && result.value.title).toBe("t");
  });
});
