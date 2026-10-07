import {
  CircularCustomPropertyError,
  UnknownCustomPropertyError,
  parseCustomProperties,
  resolveCustomProperty,
} from "./css-custom-properties";

describe("parseCustomProperties", () => {
  it("カスタムプロパティの宣言を、名前と値の組として読む", () => {
    const properties = parseCustomProperties(":root { --bg: #080c18; --teal-dim: rgba(0,251,255,0.15); }");

    expect(properties.get("--bg")).toBe("#080c18");
    expect(properties.get("--teal-dim")).toBe("rgba(0,251,255,0.15)");
  });

  it("コメントを除く（値の後ろの注記も、宣言の間のコメントも）", () => {
    const css = `
      /* Base tokens */
      :root {
        --glow-dot: 0 0 8px var(--teal); /* @kind shadow */
        /* --commented: out; */
        --white: #f0f4ff;
      }
    `;

    const properties = parseCustomProperties(css);

    expect(properties.get("--glow-dot")).toBe("0 0 8px var(--teal)");
    expect(properties.has("--commented")).toBe(false);
    expect(properties.get("--white")).toBe("#f0f4ff");
  });

  it("値に含まれる関数・カンマ・空白を保つ", () => {
    const properties = parseCustomProperties(":root{--font-sans: 'Inter', 'Noto Sans JP', sans-serif; --live: oklch(0.72 0.2 22);}");

    expect(properties.get("--font-sans")).toBe("'Inter', 'Noto Sans JP', sans-serif");
    expect(properties.get("--live")).toBe("oklch(0.72 0.2 22)");
  });

  it("同じ名前が複数あれば、あとの宣言が勝つ", () => {
    expect(parseCustomProperties(":root{--a: 1px;} :root{--a: 2px;}").get("--a")).toBe("2px");
  });

  it("複数のセレクターにまたがっても、すべて読む", () => {
    const properties = parseCustomProperties(":root{--a: 1;} @media (min-width: 1px){:root{--b: 2;}}");

    expect(properties.get("--a")).toBe("1");
    expect(properties.get("--b")).toBe("2");
  });

  it("カスタムプロパティでない宣言は読まない", () => {
    const properties = parseCustomProperties("body{color: red; background: var(--bg);}");

    expect(properties.size).toBe(0);
  });
});

describe("resolveCustomProperty", () => {
  it("値をそのまま返す（var を含まない場合）", () => {
    const properties = new Map([["--bg", "#080c18"]]);

    expect(resolveCustomProperty("--bg", properties)).toBe("#080c18");
  });

  it("var() を、参照先の値へ置き換える（多段も）", () => {
    const properties = new Map([
      ["--bg", "#080c18"],
      ["--surface-page", "var(--bg)"],
      ["--alias", "var(--surface-page)"],
    ]);

    expect(resolveCustomProperty("--alias", properties)).toBe("#080c18");
  });

  it("値の途中の var() も置き換える", () => {
    const properties = new Map([
      ["--teal", "#00fbff"],
      ["--glow", "0 0 8px var(--teal)"],
    ]);

    expect(resolveCustomProperty("--glow", properties)).toBe("0 0 8px #00fbff");
  });

  it("未定義の名前は例外にする（既定値を補わない）", () => {
    expect(() => resolveCustomProperty("--missing", new Map())).toThrow(UnknownCustomPropertyError);
  });

  it("参照先が未定義でも例外にする", () => {
    const properties = new Map([["--a", "var(--missing)"]]);

    expect(() => resolveCustomProperty("--a", properties)).toThrow(UnknownCustomPropertyError);
  });

  it("循環する参照は例外にする", () => {
    const properties = new Map([
      ["--a", "var(--b)"],
      ["--b", "var(--a)"],
    ]);

    expect(() => resolveCustomProperty("--a", properties)).toThrow(CircularCustomPropertyError);
  });

  it("例外は、問題の名前を持つ", () => {
    try {
      resolveCustomProperty("--missing", new Map());
      throw new Error("例外が投げられませんでした");
    } catch (error) {
      expect(error).toBeInstanceOf(UnknownCustomPropertyError);
      expect((error as UnknownCustomPropertyError).propertyName).toBe("--missing");
    }
  });
});
