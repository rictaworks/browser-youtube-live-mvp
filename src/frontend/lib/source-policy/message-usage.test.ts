/**
 * @jest-environment node
 */
import { collectMessageKeyUsage } from "./message-usage";

describe("collectMessageKeyUsage: 文言のキーの参照を集める", () => {
  it("t('キー') の呼び出しの、キーを集める", () => {
    const usage = collectMessageKeyUsage("sample.ts", 'const a = t("terms.title"); const b = t("brand.name");');

    expect(usage.translated).toEqual(["terms.title", "brand.name"]);
  });

  it("params を伴う呼び出しも、キーを集める", () => {
    const usage = collectMessageKeyUsage("sample.ts", 't("count.remaining", { count: 3 });');

    expect(usage.translated).toEqual(["count.remaining"]);
  });

  it("JSX の中の呼び出しも、集める", () => {
    const usage = collectMessageKeyUsage("sample.tsx", 'export const A = () => <p title={t("a.b")}>{t("c.d")}</p>;');

    expect(usage.translated).toEqual(["a.b", "c.d"]);
  });

  it("置換の無いテンプレートのキーも、集める", () => {
    expect(collectMessageKeyUsage("sample.ts", "t(`a.b`);").translated).toEqual(["a.b"]);
  });

  it("t 以外の関数の呼び出し・メソッドの t は、集めない", () => {
    const usage = collectMessageKeyUsage("sample.ts", 'translate("a.b"); i18n.t("c.d"); test("e.f");');

    expect(usage.translated).toEqual([]);
  });

  it("動的なキー（t(`接頭辞${x}`)）は、静的な接頭辞を集める（その名前空間のキーは、すべて使われうる）", () => {
    const usage = collectMessageKeyUsage("sample.ts", "t(`ui.notice.severity.${tone}`);");

    expect(usage.translated).toEqual([]);
    expect(usage.dynamicPrefixes).toEqual(["ui.notice.severity."]);
  });

  it("接頭辞が空の動的なキーは、検査できないため、例外にする", () => {
    expect(() => collectMessageKeyUsage("sample.ts", "t(`${key}`);")).toThrow(RangeError);
  });

  it("変数のキー（t(key)）は、キーを集めない。表に書いた文字列のリテラルが、参照として残る", () => {
    const usage = collectMessageKeyUsage("sample.ts", 'const KEYS = ["a.b", "c.d"] as const; KEYS.map((key) => t(key));');

    expect(usage.translated).toEqual([]);
    expect(usage.literals).toEqual(expect.arrayContaining(["a.b", "c.d"]));
  });

  it("文字列のリテラルを、すべて集める（キーを表やオブジェクトに書く使い方のため）", () => {
    const usage = collectMessageKeyUsage("sample.ts", 'const table = { title: "a.b" }; const other = "plain";');

    expect(usage.literals).toEqual(expect.arrayContaining(["a.b", "plain"]));
  });

  it("コメントの中のキーは、参照として扱わない", () => {
    const usage = collectMessageKeyUsage("sample.ts", '// t("a.b")\n/* "c.d" */\nconst x = 1;');

    expect(usage.translated).toEqual([]);
    expect(usage.literals).toEqual([]);
  });
});
