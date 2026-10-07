/**
 * @jest-environment node
 */
import fs from "node:fs";
import path from "node:path";
import { parseDeclarations, tokensReferencedBy } from "@/lib/css-declarations";
import { parseCustomProperties } from "@/lib/css-custom-properties";
import { findRawColorValues, findRawSizeValues, findRemovedOutlines } from "@/lib/source-policy/css-rules";
import { listFiles } from "@/lib/source-policy/files";

// CSS の方針の検査:
//   - 色・余白・書体・文字の大きさは、トークンの変数だけを使う（値を直書きしない）
//   - フォーカスの輪郭を消さない・動きの低減に従う・外部の CDN へ接続しない
//   - 部品の状態（通常・ホバー・押下・フォーカス・無効・処理中）の規則がある
//   - 表示幅 1,024 px 以上は 2 カラム、未満は 1 カラム

const PROJECT_ROOT = path.resolve(__dirname, "..");
const allFiles = listFiles(PROJECT_ROOT);
const cssFiles = allFiles.filter((file) => file.endsWith(".css"));

// トークンを定義するファイル（値を書く場所）。それ以外の CSS は、値を書かず、トークンを参照する
const TOKEN_DEFINITION_FILES = cssFiles.filter((file) => file.startsWith("styles/"));
const STYLE_FILES = cssFiles.filter((file) => file.startsWith("components/") || file.startsWith("app/"));

function read(relativePath: string): string {
  return fs.readFileSync(path.join(PROJECT_ROOT, relativePath), "utf8");
}

describe("CSS の走査の対象", () => {
  it("コンポーネントの CSS Modules と、全体の CSS（app/globals.css）が含まれる（走査が空振りしていない）", () => {
    expect(STYLE_FILES).toEqual(
      expect.arrayContaining([
        "app/globals.css",
        "components/ui/Button.module.css",
        "components/ui/Notice.module.css",
        "components/layout/SiteHeader.module.css",
      ]),
    );
  });

  it("トークンの定義は、styles/ にある（デザインシステムのコピー 5 件と、アプリ固有 2 件）", () => {
    expect(TOKEN_DEFINITION_FILES).toEqual(
      expect.arrayContaining([
        "styles/app-colors.css",
        "styles/app-tokens.css",
        "styles/tokens/base.css",
        "styles/tokens/colors.css",
        "styles/tokens/effects.css",
        "styles/tokens/spacing.css",
        "styles/tokens/typography.css",
      ]),
    );
  });
});

describe("値の直書きをしない（色・余白・書体・文字の大きさは、トークンの変数）", () => {
  it.each(STYLE_FILES.map((file) => [file] as const))("%s に、色の直書きが無い", (file) => {
    expect(findRawColorValues(parseDeclarations(read(file)))).toEqual([]);
  });

  it.each(STYLE_FILES.map((file) => [file] as const))("%s に、余白・書体・文字の大きさの直書きが無い", (file) => {
    expect(findRawSizeValues(parseDeclarations(read(file)))).toEqual([]);
  });
});

describe("var(--トークン) は、すべて定義されている（綴りの誤りで、スタイルが黙って落ちない）", () => {
  // next/font（app/layout.tsx）が、実行時に定義する変数
  const DEFINED_AT_RUNTIME = ["--font-inter", "--font-noto-sans-jp", "--font-playfair-display"];
  const defined = new Set<string>(DEFINED_AT_RUNTIME);
  for (const file of TOKEN_DEFINITION_FILES) {
    for (const name of parseCustomProperties(read(file)).keys()) {
      defined.add(name);
    }
  }

  it.each([...STYLE_FILES, "styles/app-tokens.css", "styles/app-colors.css"].map((file) => [file] as const))("%s", (file) => {
    const undefinedNames = parseDeclarations(read(file)).flatMap((declaration) =>
      tokensReferencedBy(declaration.value)
        .filter((name) => !defined.has(name))
        .map((name) => `${file}:${declaration.line} ${name}`),
    );

    expect(undefinedNames).toEqual([]);
  });
});

describe("フォーカスの輪郭を消さない（要件 17.6）", () => {
  it.each(cssFiles.map((file) => [file] as const))("%s に、outline を消す宣言が無い", (file) => {
    expect(findRemovedOutlines(parseDeclarations(read(file)))).toEqual([]);
  });

  it("全体の CSS が、フォーカスした部品すべてへ、輪郭の規則（:focus-visible）を与える", () => {
    const globals = read("app/globals.css");

    expect(globals).toMatch(/:focus-visible\s*\{[^}]*outline:\s*var\(--focus-ring-width\)\s+solid\s+var\(--white\)/);
    expect(globals).toMatch(/:focus-visible\s*\{[^}]*outline-offset:\s*var\(--focus-ring-offset\)/);
  });
});

describe("フォーカスの輪郭は、すぐに表示する（遷移の対象にしない）", () => {
  it.each(STYLE_FILES.map((file) => [file] as const))("%s は、transition に all を使わない（outline が、遅れて現れるため）", (file) => {
    const usesAll = parseDeclarations(read(file))
      .filter((declaration) => /^transition(?:-property)?$/.test(declaration.property))
      .filter((declaration) => /(?:^|[\s,])all(?:[\s,]|$)/.test(declaration.value));

    expect(usesAll).toEqual([]);
  });
});

describe("動きの低減（要件 17.6）", () => {
  const globals = read("app/globals.css");
  const reduced = /@media \(prefers-reduced-motion: reduce\)\s*\{([\s\S]*?)\n\}/.exec(globals)?.[1] ?? "";

  it("全体の CSS が、動きの低減の設定で、遷移とアニメーションを止める", () => {
    expect(reduced).toMatch(/transition:\s*none\s*!important/);
    expect(reduced).toMatch(/animation:\s*none\s*!important/);
  });

  it("滑らかなスクロール（tokens/base.css の html）も、動きの低減の設定で止める", () => {
    expect(read("styles/tokens/base.css")).toMatch(/scroll-behavior:\s*smooth/);
    expect(reduced).toMatch(/html\s*\{[^}]*scroll-behavior:\s*auto/);
  });
});

describe("外部の CDN へ接続しない", () => {
  it.each(cssFiles.map((file) => [file] as const))("%s は、外部の URL・@import url() を持たない", (file) => {
    const css = read(file);

    expect(css).not.toMatch(/https?:\/\//);
    expect(css).not.toMatch(/@import\s+url\(/);
  });

  it("全体の CSS は、トークン（デザインシステムのコピー）→ アプリ固有のトークンの順に、ローカルのファイルを読み込む", () => {
    const imports = Array.from(read("app/globals.css").matchAll(/@import\s+"([^"]+)";/g), (match) => match[1]);

    expect(imports).toEqual([
      "../styles/tokens/colors.css",
      "../styles/tokens/typography.css",
      "../styles/tokens/spacing.css",
      "../styles/tokens/effects.css",
      "../styles/tokens/base.css",
      "../styles/app-colors.css",
      "../styles/app-tokens.css",
    ]);
  });
});

describe("ボタンの状態（要件 17.5: 通常・ホバー・押下・フォーカス・無効・処理中）", () => {
  const button = read("components/ui/Button.module.css");

  it("ホバー・押下・無効・処理中（aria-disabled）の規則を持つ", () => {
    expect(button).toMatch(/\.button:hover\s*\{/);
    expect(button).toMatch(/\.button:active\s*\{/);
    expect(button).toMatch(/\.button:disabled/);
    expect(button).toMatch(/\.button\[aria-disabled="true"\]/);
  });

  it("主要・停止の、ホバー・押下の規則を持つ", () => {
    for (const variant of ["primary", "stop"]) {
      expect(button).toMatch(new RegExp(`\\.${variant}:hover\\s*\\{`));
      expect(button).toMatch(new RegExp(`\\.${variant}:active\\s*\\{`));
    }
  });

  it("無効・処理中の規則は、ホバー・押下の規則より後ろにある（見た目を打ち消すため）", () => {
    expect(button.indexOf(".button:disabled")).toBeGreaterThan(button.lastIndexOf(".stop:active"));
  });
});

describe("レイアウト（要件 17.4）", () => {
  const twoColumn = read("components/layout/TwoColumnLayout.module.css");
  const tokens = parseCustomProperties(read("styles/app-tokens.css"));

  it("既定は 1 カラム。1,024 px 以上で 2 カラム（右のパネルの幅は、トークン --layout-aside-width）", () => {
    const base = /\.layout\s*\{([^}]*)\}/.exec(twoColumn)?.[1] ?? "";
    const wide = /@media \(min-width: 1024px\)\s*\{([\s\S]*?)\n\}/.exec(twoColumn)?.[1] ?? "";

    expect(base).toMatch(/grid-template-columns:\s*minmax\(0,\s*1fr\);/);
    expect(wide).toMatch(/grid-template-columns:\s*minmax\(0,\s*1fr\)\s+var\(--layout-aside-width\);/);
  });

  it("右のパネルの幅は 320 px", () => {
    expect(tokens.get("--layout-aside-width")).toBe("320px");
  });

  it("余白は 4 px を単位とする（トークンの余白は、6・50 を除き 4 の倍数）", () => {
    const spacing = parseCustomProperties(read("styles/tokens/spacing.css"));
    const notMultiplesOfFour = Array.from(spacing.entries())
      .filter(([name]) => name.startsWith("--sp-"))
      .filter(([, value]) => Number.parseInt(value, 10) % 4 !== 0)
      .map(([name]) => name);

    expect(notMultiplesOfFour).toEqual(["--sp-6", "--sp-50"]);
  });

  it("コンポーネントの CSS が使う余白のトークンは、4 の倍数だけ（6・50 を使わない）。モックの 4 の倍数でない余白は、近い値へ丸めている", () => {
    const used = STYLE_FILES.flatMap((file) =>
      parseDeclarations(read(file)).flatMap((declaration) => tokensReferencedBy(declaration.value)),
    ).filter((name) => /^--sp-\d+$/.test(name));

    const nonMultiples = Array.from(new Set(used)).filter((name) => Number.parseInt(name.slice("--sp-".length), 10) % 4 !== 0);

    expect(nonMultiples).toEqual([]);
  });
});
