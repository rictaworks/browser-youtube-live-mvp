import { parseDeclarations } from "../css-declarations";
import { findRawColorValues, findRawSizeValues, findRemovedOutlines } from "./css-rules";

const check = (rule: typeof findRawColorValues, css: string) => rule(parseDeclarations(css));

describe("findRawColorValues: 色の値の直書き（色は、トークンの変数だけを使う）", () => {
  it.each([
    ["16 進", ".a { color: #fff; }"],
    ["16 進（6 桁）", ".a { background: #080c18; }"],
    ["rgb()", ".a { color: rgb(1, 2, 3); }"],
    ["rgba()", ".a { border-color: rgba(0, 251, 255, 0.2); }"],
    ["hsl()", ".a { color: hsl(10 20% 30%); }"],
    ["oklch()", ".a { color: oklch(0.72 0.2 22); }"],
    ["color-mix()", ".a { color: color-mix(in srgb, red, blue); }"],
    ["フォールバックの中の色", ".a { color: var(--x, #fff); }"],
    ["影の中の色", ".a { box-shadow: 0 0 8px rgba(0, 0, 0, 0.5); }"],
    ["色名（color）", ".a { color: white; }"],
    ["色名（border の省略形）", ".a { border: 1px solid red; }"],
    ["色名（background）", ".a { background: silver; }"],
    ["色名（outline）", ".a { outline: 2px solid teal; }"],
  ])("%s を見つける", (_label, css) => {
    expect(check(findRawColorValues, css).length).toBeGreaterThan(0);
  });

  it.each([
    ["トークンの変数", ".a { color: var(--silver); background: var(--card-bg); }"],
    ["枠（太さ・種類・トークンの色）", ".a { border: 1px solid var(--silver-60); }"],
    ["透明・継承", ".a { background: transparent; color: inherit; border-color: currentColor; }"],
    ["影（長さとトークンの色）", ".a { box-shadow: 0 0 24px var(--glow-color); }"],
    ["枠なし", ".a { border: 0; outline: none; }"],
    ["色に関係の無いプロパティの語", ".a { display: flex; cursor: pointer; text-transform: uppercase; }"],
    ["下線（text-decoration）", ".a { text-decoration: underline; }"],
    ["カスタムプロパティの宣言そのもの（トークンの定義）は、別のファイルの責務", ".a { --x: 1px; }"],
  ])("%s は、見つけない", (_label, css) => {
    expect(check(findRawColorValues, css)).toEqual([]);
  });

  it("行番号とプロパティを返す", () => {
    const violations = check(findRawColorValues, ".a {\n  display: flex;\n  color: #fff;\n}\n");

    expect(violations).toEqual([expect.objectContaining({ line: 3, property: "color", value: "#fff" })]);
  });
});

describe("findRawSizeValues: 余白・文字の値の直書き（余白・書体・文字の大きさは、トークンの変数だけを使う）", () => {
  it.each([
    ["padding", ".a { padding: 16px; }"],
    ["padding（複数の値）", ".a { padding: var(--sp-16) 24px; }"],
    ["margin", ".a { margin-top: 8px; }"],
    ["gap", ".a { gap: 12px 24px; }"],
    ["row-gap", ".a { row-gap: 1rem; }"],
    ["font-size", ".a { font-size: 14px; }"],
    ["letter-spacing", ".a { letter-spacing: 0.2em; }"],
    ["line-height（単位なしの数）", ".a { line-height: 1.5; }"],
    ["font-family", ".a { font-family: Arial, sans-serif; }"],
    ["font-weight（数）", ".a { font-weight: 600; }"],
    ["font（省略形は、トークンを使えない）", ".a { font: 600 12px/1 var(--font-sans); }"],
  ])("%s を見つける", (_label, css) => {
    expect(check(findRawSizeValues, css).length).toBeGreaterThan(0);
  });

  it.each([
    ["トークン", ".a { padding: var(--sp-16) var(--sp-24); gap: var(--sp-12) var(--sp-28); }"],
    ["0 と auto", ".a { margin: 0 auto; padding: var(--sp-8) 0; }"],
    ["フォントのトークン", ".a { font-family: var(--font-sans); font-size: var(--fs-14); font-weight: var(--fw-medium); }"],
    ["行間・字間のトークン", ".a { line-height: var(--lh-ui); letter-spacing: var(--ls-02); }"],
    ["キーワード", ".a { line-height: normal; font-weight: inherit; margin: initial; }"],
    ["余白に関係の無いプロパティの長さ（幅・高さ・枠線の太さ）", ".a { width: 1px; height: 100%; max-width: 860px; border: 1px solid var(--x); }"],
  ])("%s は、見つけない", (_label, css) => {
    expect(check(findRawSizeValues, css)).toEqual([]);
  });

  it("行番号とプロパティを返す", () => {
    const violations = check(findRawSizeValues, ".a {\n  display: flex;\n  padding: 16px;\n}\n");

    expect(violations).toEqual([expect.objectContaining({ line: 3, property: "padding", value: "16px" })]);
  });
});

describe("findRemovedOutlines: フォーカスの輪郭を消さない（要件 17.6）", () => {
  it.each([
    ["outline: none", ".a:focus { outline: none; }"],
    ["outline: 0", ".a:focus { outline: 0; }"],
    ["outline: 0px", ".a:focus { outline: 0px; }"],
    ["outline-style: none", ".a:focus { outline-style: none; }"],
    ["outline-width: 0", ".a:focus { outline-width: 0; }"],
  ])("%s を見つける", (_label, css) => {
    expect(check(findRemovedOutlines, css).length).toBeGreaterThan(0);
  });

  it.each([
    ["輪郭を指定する", ".a:focus-visible { outline: var(--focus-ring-width) solid var(--white); }"],
    ["輪郭のオフセット", ".a:focus-visible { outline-offset: var(--focus-ring-offset); }"],
    ["枠なし（border）は、輪郭ではない", ".a { border: 0; }"],
  ])("%s は、見つけない", (_label, css) => {
    expect(check(findRemovedOutlines, css)).toEqual([]);
  });
});
