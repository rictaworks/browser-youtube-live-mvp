/**
 * @jest-environment node
 */
import fs from "node:fs";
import path from "node:path";
import { parseCustomProperties } from "@/lib/css-custom-properties";
import { listFiles } from "@/lib/source-policy/files";

// 書体（Inter・Noto Sans JP・Playfair Display）は、next/font/google で、ビルド時に取得して自己ホストする。
// 実際の取得は next build で確認する。ここでは、設定の接続（layout.tsx と、トークン --font-sans・--font-display）の整合を確かめる。

const PROJECT_ROOT = path.resolve(__dirname, "..");

function read(relativePath: string): string {
  return fs.readFileSync(path.join(PROJECT_ROOT, relativePath), "utf8");
}

const layout = read("app/layout.tsx");
const appTokens = parseCustomProperties(read("styles/app-tokens.css"));

describe("app/layout.tsx: 書体の読み込み", () => {
  it("Inter・Noto Sans JP・Playfair Display を、next/font/google から読み込む", () => {
    expect(layout).toMatch(/import\s*\{\s*Inter,\s*Noto_Sans_JP,\s*Playfair_Display\s*\}\s*from\s*"next\/font\/google";/);
  });

  it("書体のファイルを、リポジトリへ同梱しない・next/font/local を使わない（ビルド時の取得で自己ホストする）", () => {
    expect(layout).not.toContain("next/font/local");
    const binaries = listFiles(PROJECT_ROOT).filter((file) => /\.(woff2?|ttf|otf|eot)$/i.test(file));

    expect(binaries).toEqual([]);
  });

  it("3 つの書体の変数（--font-inter・--font-noto-sans-jp・--font-playfair-display）を、html 要素へ付ける", () => {
    const variables = Array.from(layout.matchAll(/variable:\s*"(--[a-z-]+)"/g), (match) => match[1]);

    expect(variables).toEqual(["--font-inter", "--font-noto-sans-jp", "--font-playfair-display"]);
    for (const name of ["inter", "notoSansJp", "playfairDisplay"]) {
      expect(layout).toContain(`${name}.variable`);
    }
  });

  it("表示は swap（書体の取得を待たず、システム書体で先に表示する）。イタリックは Playfair Display だけ", () => {
    expect(layout.match(/display:\s*"swap"/g)).toHaveLength(3);
    expect(layout).toMatch(/style:\s*\["normal",\s*"italic"\]/);
  });

  it("外部の CDN の <link>・@import を使わない", () => {
    expect(layout).not.toMatch(/fonts\.googleapis\.com|fonts\.gstatic\.com|cdnjs\.cloudflare\.com|fontawesome\.com/);
  });
});

describe("トークンへの接続（styles/app-tokens.css）", () => {
  it("--font-sans は、Inter・Noto Sans JP の変数のあと、システム書体（sans-serif）へ落ちる並び", () => {
    expect(appTokens.get("--font-sans")).toBe("var(--font-inter), var(--font-noto-sans-jp), sans-serif");
  });

  it("--font-display は、Playfair Display の変数のあと、システム書体（serif）へ落ちる並び", () => {
    expect(appTokens.get("--font-display")).toBe("var(--font-playfair-display), serif");
  });

  it("デザインシステムのコピー（tokens/typography.css）は、書き換えない（書体名の並びは、そのまま）", () => {
    const original = parseCustomProperties(read("styles/tokens/typography.css"));

    expect(original.get("--font-sans")).toBe("'Inter', 'Noto Sans JP', sans-serif");
    expect(original.get("--font-display")).toBe("'Playfair Display', serif");
  });

  it("tokens/fonts.css・fonts-local.css（CDN の @import・同梱の書体ファイル）は、取り込まない", () => {
    const names = listFiles(PROJECT_ROOT).map((file) => path.basename(file));

    expect(names).not.toContain("fonts.css");
    expect(names).not.toContain("fonts-local.css");
    expect(read("app/globals.css")).not.toMatch(/fonts(-local)?\.css/);
  });

  it("本文の書体は、トークン --font-sans（next/font につながったもの）", () => {
    expect(read("app/globals.css")).toMatch(/body\s*\{[^}]*font-family:\s*var\(--font-sans\)/);
  });
});

describe("THIRD_PARTY_NOTICES.md: 書体のライセンス表示", () => {
  const notices = read("THIRD_PARTY_NOTICES.md");

  it.each([
    ["Inter", "Copyright 2020 The Inter Project Authors"],
    ["Noto Sans JP", "Copyright 2014-2021 Adobe"],
    ["Playfair Display", "Copyright 2017 The Playfair Display Project Authors"],
  ])("%s の著作権表示がある", (_font, copyright) => {
    expect(notices).toContain(copyright);
  });

  it("SIL Open Font License 1.1 の全文を含む", () => {
    expect(notices).toContain("SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007");
    expect(notices).toContain("PERMISSION & CONDITIONS");
    expect(notices).toContain("DISCLAIMER");
  });

  it("Font Awesome Free の帰属表示（アイコン: CC BY 4.0）がある", () => {
    expect(notices).toContain("Font Awesome Free");
    expect(notices).toContain("CC BY 4.0");
  });
});
