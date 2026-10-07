// nameOf（エラーの名前の読み取り）。型付きのエラー・診断に、元のエラーの名前だけを残すための部品。名前を読めない値は、推測せず null。
import { nameOf } from "./error-name";

describe("nameOf", () => {
  it.each([
    ["DOMException", new DOMException("message", "NotAllowedError"), "NotAllowedError"],
    ["Error の派生", new TypeError("message"), "TypeError"],
    ["名前を持つ普通のオブジェクト", { name: "CustomError" }, "CustomError"],
  ])("%s は、その名前", (_label, value, expected) => {
    expect(nameOf(value)).toBe(expected);
  });

  it.each([
    ["空の名前", { name: "" }],
    ["文字列でない名前", { name: 5 }],
    ["名前が無いオブジェクト", {}],
    ["null", null],
    ["undefined", undefined],
    ["文字列", "NotAllowedError"],
    ["数値", 42],
  ])("%s は、null（名前を推測しない）", (_label, value) => {
    expect(nameOf(value)).toBeNull();
  });
});
