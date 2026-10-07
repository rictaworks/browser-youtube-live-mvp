/**
 * @jest-environment node
 */
import { findEmoji, findJapaneseInCode, findNativeDialogCalls, findTextInCode } from "./detectors";

// 検知の部品の単体テスト（リポジトリ全体への適用は repository.test.ts）。
// 絵文字・記号は、ソースへ直接書かず、コードポイントから組み立てる（本ファイル自身が、絵文字の検知に掛からないようにするため）。
const fromCodePoints = (...codePoints: number[]) => String.fromCodePoint(...codePoints);
const ROCKET = fromCodePoints(0x1f680);
const CHECK_MARK_BUTTON = fromCodePoints(0x2705);
const HEAVY_CHECK_MARK = fromCodePoints(0x2714);
const RED_HEART_EMOJI_PRESENTATION = fromCodePoints(0x2764, 0xfe0f);
const FLAG_JP = fromCodePoints(0x1f1ef, 0x1f1f5);
const KEYCAP_ONE = fromCodePoints(0x31, 0xfe0f, 0x20e3);
const COPYRIGHT_SIGN = fromCodePoints(0xa9);
const REGISTERED_SIGN = fromCodePoints(0xae);
const TRADE_MARK_SIGN = fromCodePoints(0x2122);
// 矢印・省略記号・参照記号・星・四角・音符（絵文字ではない記号）
const PLAIN_SYMBOLS = [0x2192, 0x2026, 0x203b, 0x2605, 0x25a0, 0x266a].map((codePoint) => fromCodePoints(codePoint)).join(" ");

describe("findJapaneseInCode: 日本語のリテラルを見つける", () => {
  it.each([
    ["ひらがな", 'const a = "あいう";'],
    ["カタカナ", 'const a = "アイウ";'],
    ["半角カタカナ", 'const a = "ｱｲ";'],
    ["漢字", 'const a = "日本語";'],
    ["ASCII に混ざった日本語", 'const a = "Studio の状態";'],
    ["単一引用符", "const a = '日本語';"],
    ["置換の無いテンプレート", "const a = `日本語`;"],
    ["置換のあるテンプレートの先頭", "const a = `日本語 ${b}`;"],
    ["置換のあるテンプレートの中間", "const a = `${b} 日本語 ${c}`;"],
    ["置換のあるテンプレートの末尾", "const a = `${b} 日本語`;"],
    ["オブジェクトのキー（文字列）", 'const a = { "日本語": 1 };'],
    ["型のリテラル", 'type A = "日本語";'],
    ["正規表現", "const a = /[ぁ-ん]/;"],
    ["識別子", "const 名前 = 1;"],
  ])("%s", (_label, source) => {
    expect(findJapaneseInCode("sample.ts", source).length).toBeGreaterThan(0);
  });

  it.each([
    ["JSX の文字", "export const A = () => <p>日本語</p>;"],
    ["JSX の文字（式と混在）", "export const A = () => <p>{x} 日本語</p>;"],
    ["JSX の属性の文字列", 'export const A = () => <a title="日本語">x</a>;'],
  ])("%s（.tsx）", (_label, source) => {
    expect(findJapaneseInCode("sample.tsx", source).length).toBeGreaterThan(0);
  });

  it.each([
    ["行コメント", "const a = 1; // 日本語のコメント"],
    ["ブロックコメント", "/* 日本語のコメント */ const a = 1;"],
    ["JSDoc", "/**\n * 日本語の説明\n * @param x 日本語\n */\nexport function f(x: number) { return x; }"],
    ["複数行のコメントの中の文字列風の記述", '/*\n const a = "日本語";\n*/\nconst b = 1;'],
  ])("%s は対象にしない", (_label, source) => {
    expect(findJapaneseInCode("sample.ts", source)).toEqual([]);
  });

  it.each([
    ["ASCII のみ", 'const a = "Hello";'],
    ["全角の約物だけ（かなも漢字も無い）", 'const a = "、。（）：";'],
    ["長音記号だけ", 'const a = "ー";'],
    ["空の文字列", 'const a = "";'],
  ])("%s は対象にしない", (_label, source) => {
    expect(findJapaneseInCode("sample.ts", source)).toEqual([]);
  });

  it("JSX の JSX コメント内の日本語は対象にしない", () => {
    const source = "export const A = () => <p>{/* 日本語のコメント */}x</p>;";

    expect(findJapaneseInCode("sample.tsx", source)).toEqual([]);
  });

  it("JSX の空白だけの文字は対象にしない", () => {
    const source = "export const A = () => (\n  <div>\n    <p>x</p>\n  </div>\n);";

    expect(findJapaneseInCode("sample.tsx", source)).toEqual([]);
  });

  it("位置（行・桁）と、見つけた文字列を返す", () => {
    const source = 'const a = 1;\nconst b = "x日本語";\n';

    const findings = findJapaneseInCode("sample.ts", source);

    expect(findings).toHaveLength(1);
    expect(findings[0].line).toBe(2);
    expect(findings[0].column).toBe(11);
    expect(findings[0].text).toContain("日本語");
  });

  it("複数の箇所を、すべて返す", () => {
    const source = 'const a = "あ";\nconst b = "い";\n';

    expect(findJapaneseInCode("sample.ts", source).map((finding) => finding.line)).toEqual([1, 2]);
  });

  it("拡張子が .ts なら、JSX として解釈しない（型アサーションの <T> を壊さない）", () => {
    const source = "const a = <number>b;";

    expect(findJapaneseInCode("sample.ts", source)).toEqual([]);
  });
});

describe("findEmoji: 絵文字を見つける", () => {
  it.each([
    ["絵文字（ロケット）", ROCKET],
    ["絵文字表示が既定の記号（チェックマークのボタン）", CHECK_MARK_BUTTON],
    ["テキスト表示が既定の記号（太いチェックマーク）", HEAVY_CHECK_MARK],
    ["絵文字表示の指定（VS16）付きの記号", RED_HEART_EMOJI_PRESENTATION],
    ["国旗（地域指示記号）", FLAG_JP],
    ["キーキャップ", KEYCAP_ONE],
  ])("%s", (_label, emoji) => {
    expect(findEmoji(`before ${emoji} after`).length).toBeGreaterThan(0);
  });

  it.each([
    ["著作権記号", COPYRIGHT_SIGN],
    ["登録商標記号", REGISTERED_SIGN],
    ["商標記号", TRADE_MARK_SIGN],
    ["日本語", "日本語のテキスト"],
    ["矢印・約物・記号", PLAIN_SYMBOLS],
    ["数字・記号（キーキャップの素）", "1 # * 0"],
    ["ASCII", "const a = 'plain';"],
  ])("%s は絵文字として扱わない", (_label, text) => {
    expect(findEmoji(text)).toEqual([]);
  });

  it("位置（行・桁）を返す", () => {
    const findings = findEmoji(`line1\nab${ROCKET}cd\n`);

    expect(findings).toHaveLength(1);
    expect(findings[0].line).toBe(2);
    expect(findings[0].column).toBe(3);
  });

  it("コメントの中も対象にする（コード・テスト・コメント・ドキュメントのすべてで使わない）", () => {
    expect(findEmoji(`// ${ROCKET}\nconst a = 1;`).length).toBeGreaterThan(0);
  });
});

describe("findNativeDialogCalls: alert・confirm・prompt の呼び出しを見つける", () => {
  it.each([
    ["alert", 'alert("x");'],
    ["confirm", 'confirm("x");'],
    ["prompt", 'prompt("x");'],
    ["window.alert", 'window.alert("x");'],
    ["window.confirm", 'window.confirm("x");'],
    ["window.prompt", 'window.prompt("x");'],
    ["globalThis.alert", 'globalThis.alert("x");'],
    ["self.confirm", 'self.confirm("x");'],
    ["添字での呼び出し", 'window["alert"]("x");'],
    ["式の中", 'if (confirm("x")) { run(); }'],
    ["コンポーネントの中", 'export function A() { return <button onClick={() => alert("x")}>y</button>; }'],
  ])("%s", (_label, source) => {
    expect(findNativeDialogCalls("sample.tsx", source).length).toBeGreaterThan(0);
  });

  it.each([
    ["beforeunload の登録（離脱確認は許可する）", 'window.addEventListener("beforeunload", handler);'],
    ["他のオブジェクトの同名のメソッド", 'dialog.confirm("x"); modal.alert("x"); form.prompt("x");'],
    ["文字列の中", 'const a = "alert(1)";'],
    ["コメントの中", '// alert("x")\n/* confirm("x") */'],
    ["似た名前の関数", 'confirmButton("x"); alertMessage("x"); promptUser("x");'],
    ["呼び出さない参照", "const f = alert;"],
    ["文字列としての指定（spyOn など）", 'jest.spyOn(window, "alert");'],
    ["同名のプロパティの宣言", "const o = { alert: 1, confirm: 2, prompt: 3 };"],
  ])("%s は対象にしない", (_label, source) => {
    expect(findNativeDialogCalls("sample.tsx", source)).toEqual([]);
  });

  it("位置（行・桁）を返す", () => {
    const findings = findNativeDialogCalls("sample.ts", 'const a = 1;\n  alert("x");\n');

    expect(findings).toHaveLength(1);
    expect(findings[0].line).toBe(2);
    expect(findings[0].column).toBe(3);
    expect(findings[0].text).toBe('alert("x")');
  });
});

describe("findTextInCode: コードの中の文字（文字列・テンプレート・JSX の文字）に、指定の文字列が含まれるか", () => {
  it.each([
    ["文字列", 'const a = "Alpha Beta";'],
    ["置換の無いテンプレート", "const a = `Alpha Beta`;"],
    ["置換のあるテンプレート", "const a = `x ${y} Alpha Beta`;"],
    ["文字列の一部", 'const a = "the Alpha Beta site";'],
  ])("%s の中を見つける", (_label, source) => {
    expect(findTextInCode("sample.ts", source, "Alpha Beta").length).toBeGreaterThan(0);
  });

  it("JSX の文字の中を見つける（.tsx）", () => {
    expect(findTextInCode("sample.tsx", "export const A = () => <p>Alpha Beta</p>;", "Alpha Beta").length).toBeGreaterThan(0);
  });

  it.each([
    ["行コメント", "// Alpha Beta\nconst a = 1;"],
    ["ブロックコメント", "/* Alpha Beta */ const a = 1;"],
    ["JSDoc", "/** Alpha Beta */\nexport const a = 1;"],
    ["含まない文字列", 'const a = "Alpha";'],
  ])("%s は、見つけない", (_label, source) => {
    expect(findTextInCode("sample.ts", source, "Alpha Beta")).toEqual([]);
  });

  it("位置（行・桁）を返す", () => {
    const findings = findTextInCode("sample.ts", 'const a = 1;\nconst b = "Alpha Beta";\n', "Alpha Beta");

    expect(findings).toEqual([expect.objectContaining({ line: 2, column: 11 })]);
  });
});
