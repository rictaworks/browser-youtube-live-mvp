import { parseDeclarations, splitValueTokens, tokensReferencedBy } from "./css-declarations";

describe("parseDeclarations", () => {
  it("宣言を、プロパティ・値・行番号として読む", () => {
    const css = ".button {\n  color: var(--silver);\n  padding: var(--sp-16) var(--sp-24);\n}\n";

    expect(parseDeclarations(css)).toEqual([
      { property: "color", value: "var(--silver)", line: 2 },
      { property: "padding", value: "var(--sp-16) var(--sp-24)", line: 3 },
    ]);
  });

  it("最後の宣言の「;」が無くても読む", () => {
    expect(parseDeclarations(".a{color:red}")).toEqual([{ property: "color", value: "red", line: 1 }]);
  });

  it("コメントを除く（行番号は保つ）", () => {
    const css = "/* color: red; */\n.a {\n  /* margin: 4px; */\n  gap: var(--sp-8); /* padding: 1px; */\n}\n";

    expect(parseDeclarations(css)).toEqual([{ property: "gap", value: "var(--sp-8)", line: 4 }]);
  });

  it("セレクターの疑似クラスを、宣言として読まない", () => {
    const css = "a:hover { color: var(--teal); }\n.button:not(:disabled):hover .icon { gap: var(--sp-8); }\n";

    expect(parseDeclarations(css).map((declaration) => declaration.property)).toEqual(["color", "gap"]);
  });

  it("@media の条件を、宣言として読まない。中の宣言は読む", () => {
    const css = "@media (min-width: 1024px) {\n  .layout { gap: var(--sp-24); }\n}\n";

    expect(parseDeclarations(css)).toEqual([{ property: "gap", value: "var(--sp-24)", line: 2 }]);
  });

  it("カスタムプロパティの宣言も、プロパティとして読む", () => {
    expect(parseDeclarations(":root { --live: oklch(0.72 0.2 22); }")).toEqual([
      { property: "--live", value: "oklch(0.72 0.2 22)", line: 1 },
    ]);
  });

  it("複数行の値を、1 つの宣言として読む", () => {
    const css = ".a {\n  transition:\n    color var(--dur-fast),\n    border-color var(--dur-fast);\n}\n";

    const [declaration] = parseDeclarations(css);

    expect(declaration.property).toBe("transition");
    expect(declaration.value.replace(/\s+/g, " ")).toBe("color var(--dur-fast), border-color var(--dur-fast)");
  });

  it("プロパティ名は小文字にそろえる", () => {
    expect(parseDeclarations(".a { Color: red; }")[0].property).toBe("color");
  });
});

describe("tokensReferencedBy", () => {
  it("値の中の var(--name) の名前を、出現順に返す", () => {
    expect(tokensReferencedBy("0 0 8px var(--teal), 0 0 4px var(--live)")).toEqual(["--teal", "--live"]);
  });

  it("フォールバック付きの var() も、名前を返す", () => {
    expect(tokensReferencedBy("var(--a, red)")).toEqual(["--a"]);
  });

  it("var() が無ければ、空", () => {
    expect(tokensReferencedBy("1px solid red")).toEqual([]);
  });
});

describe("splitValueTokens", () => {
  it.each([
    ["空白で区切る", "1px solid var(--silver-60)", ["1px", "solid", "var(--silver-60)"]],
    ["カンマでも区切る", "var(--font-sans), serif", ["var(--font-sans)", "serif"]],
    ["関数の括弧の中は、区切らない（フォールバック付きの var）", "0 0 24px var(--glow, 0 0 1px red)", ["0", "0", "24px", "var(--glow, 0 0 1px red)"]],
    ["入れ子の関数も、1 つの要素", "calc(var(--a) + var(--b))", ["calc(var(--a) + var(--b))"]],
    ["余分な空白・改行を無視する", "  a\n   b  ", ["a", "b"]],
    ["空の値は、要素なし", "", []],
  ])("%s", (_label, value, expected) => {
    expect(splitValueTokens(value)).toEqual(expected);
  });
});
