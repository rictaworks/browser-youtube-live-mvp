/**
 * @jest-environment node
 */
import fs from "node:fs";
import path from "node:path";
import { parseCustomProperties } from "@/lib/css-custom-properties";
import { parseDeclarations, tokensReferencedBy } from "@/lib/css-declarations";
import { listFiles } from "@/lib/source-policy/files";
import { COLOR_PAIRS } from "./color-pairs";

// 実際に使う色の組の検査（contrast.test.ts）が、CSS の実態と食い違わないことの検査。
// CSS が、文字・背景・枠・輪郭へ使う色のトークンは、すべて color-pairs.ts に載っている（載せ忘れると落ちる）。
// 載っていれば、contrast.test.ts が、トークンの値からコントラスト比を計算して、基準を満たすことを確かめる。

const PROJECT_ROOT = path.resolve(__dirname, "..");
const STYLE_FILES = listFiles(PROJECT_ROOT).filter(
  (file) => file.endsWith(".css") && (file.startsWith("components/") || file.startsWith("app/")),
);

function read(relativePath: string): string {
  return fs.readFileSync(path.join(PROJECT_ROOT, relativePath), "utf8");
}

const colorTokens = new Set<string>([
  ...parseCustomProperties(read("styles/tokens/colors.css")).keys(),
  ...parseCustomProperties(read("styles/app-colors.css")).keys(),
]);

// プロパティの役割: 文字・図形の色（前景）/ 背景 / 境界・輪郭。影（box-shadow・text-shadow）の光彩は、装飾なので対象外
const FOREGROUND_PROPERTY = /^(?:color|fill|stroke|caret-color|text-decoration-color)$/;
const SURFACE_PROPERTY = /^(?:background|background-color)$/;
const BOUNDARY_PROPERTY = /^(?:outline|outline-color|border(?:-(?:top|right|bottom|left))?(?:-color)?)$/;

// 装飾（情報を伝えない。内容は、文字と背景で判別できる）。コントラストの基準の対象外
const DECORATIVE: Readonly<Record<string, string>> = {
  "--border": "カードの枠（装飾。部品の境界ではなく、内容は文字と背景で判別できる）",
  "--silver-08": "行の区切り線（装飾）",
  "--silver-10": "見出しの横の線（装飾）",
};

interface Usage {
  readonly file: string;
  readonly line: number;
  readonly property: string;
  readonly token: string;
}

function usagesOf(propertyPattern: RegExp): Usage[] {
  return STYLE_FILES.flatMap((file) =>
    parseDeclarations(read(file))
      .filter((declaration) => propertyPattern.test(declaration.property))
      .flatMap((declaration) =>
        tokensReferencedBy(declaration.value)
          .filter((token) => colorTokens.has(token))
          .map((token) => ({ file, line: declaration.line, property: declaration.property, token })),
      ),
  );
}

const describeUsage = (usage: Usage) => `${usage.file}:${usage.line} ${usage.property}: ${usage.token}`;

describe("CSS が使う色は、color-pairs.ts（コントラストの検査の対象）に載っている", () => {
  const pairForegrounds = new Set(COLOR_PAIRS.map((pair) => pair.foreground));
  const pairSurfaceLayers = new Set(COLOR_PAIRS.flatMap((pair) => pair.surface));
  const boundaryForegrounds = new Set(
    COLOR_PAIRS.filter((pair) => pair.kind === "boundary" || pair.kind === "graphic").map((pair) => pair.foreground),
  );

  it("走査が、色のトークンの使用を見つけている（空振りしていない）", () => {
    expect(usagesOf(FOREGROUND_PROPERTY).length).toBeGreaterThan(10);
    expect(usagesOf(SURFACE_PROPERTY).length).toBeGreaterThan(5);
    expect(usagesOf(BOUNDARY_PROPERTY).length).toBeGreaterThan(5);
  });

  it("文字・図形の色（color など）は、前景として載っている", () => {
    const missing = usagesOf(FOREGROUND_PROPERTY).filter((usage) => !pairForegrounds.has(usage.token));

    expect(missing.map(describeUsage)).toEqual([]);
  });

  it("背景（background）は、背景の層として載っている（装飾を除く）", () => {
    const missing = usagesOf(SURFACE_PROPERTY).filter(
      (usage) => !pairSurfaceLayers.has(usage.token) && !(usage.token in DECORATIVE),
    );

    expect(missing.map(describeUsage)).toEqual([]);
  });

  it("枠・輪郭（border・outline）は、境界・図形の前景として載っている（装飾を除く）", () => {
    const missing = usagesOf(BOUNDARY_PROPERTY).filter(
      (usage) => !boundaryForegrounds.has(usage.token) && !(usage.token in DECORATIVE),
    );

    expect(missing.map(describeUsage)).toEqual([]);
  });

  it("装飾として除いた色は、理由つきで最小（3 件）", () => {
    expect(Object.keys(DECORATIVE)).toHaveLength(3);
    for (const reason of Object.values(DECORATIVE)) {
      expect(reason.length).toBeGreaterThan(5);
    }
  });

  it("装飾として除いた色は、文字・図形の色（前景）としては使われていない（情報を伝える色を除外していない）", () => {
    const misused = usagesOf(FOREGROUND_PROPERTY).filter((usage) => usage.token in DECORATIVE);

    expect(misused.map(describeUsage)).toEqual([]);
  });
});
