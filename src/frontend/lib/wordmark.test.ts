import { splitWordmark } from "./wordmark";

describe("splitWordmark: 製品名を、ワードマークの「前の語」と「強調する最後の語」に分ける", () => {
  it.each([
    ["2 語", "Browser Live", { lead: "Browser", accent: "Live" }],
    ["1 語（強調する語は無し）", "Browser", { lead: "Browser", accent: "" }],
    ["3 語（最後の語だけを強調する）", "Browser Live Studio", { lead: "Browser Live", accent: "Studio" }],
    ["前後と語の間の余分な空白は 1 つにそろえる", "  Browser   Live  ", { lead: "Browser", accent: "Live" }],
    ["日本語の製品名", "ブラウザ ライブ", { lead: "ブラウザ", accent: "ライブ" }],
    ["空白を含まない日本語の製品名", "ブラウザライブ", { lead: "ブラウザライブ", accent: "" }],
  ])("%s", (_label, name, expected) => {
    expect(splitWordmark(name)).toEqual(expected);
  });

  it.each([
    ["空文字", ""],
    ["空白のみ", "   "],
  ])("%s は、例外にする（空の製品名を表示しない）", (_label, name) => {
    expect(() => splitWordmark(name)).toThrow(RangeError);
  });
});
