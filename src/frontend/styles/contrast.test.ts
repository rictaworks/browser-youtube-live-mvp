/**
 * @jest-environment node
 */
import fs from "node:fs";
import path from "node:path";
import { compositeOver, contrastRatio, flattenLayers, parseColor, type Rgb } from "@/lib/contrast";
import { parseCustomProperties, resolveCustomProperty } from "@/lib/css-custom-properties";
import { COLOR_PAIRS, MINIMUM_RATIO, type ColorPair } from "./color-pairs";

// 配色のコントラストの検査（要件 17.2・受け入れ条件）。
//   文字と背景: 4.5:1 以上。操作部品の境界と、状態の図形（アイコン・フォーカスの輪郭）: 3:1 以上。
// 検査する色の組は、実際に使う組（color-pairs.ts）。値は、トークンのファイルから読む（ここへ値を写さない）。
// 半透明の色（rgba・oklch の不透明度）は、重なる背景（--card-bg など）を重ねた合成後の色で計算する。

const TOKEN_FILES = ["tokens/colors.css", "app-colors.css"];

function loadTokens(): Map<string, string> {
  const properties = new Map<string, string>();
  for (const file of TOKEN_FILES) {
    const css = fs.readFileSync(path.join(__dirname, file), "utf8");
    for (const [name, value] of parseCustomProperties(css)) {
      properties.set(name, value);
    }
  }
  return properties;
}

const tokens = loadTokens();

function colorOf(token: string) {
  return parseColor(resolveCustomProperty(token, tokens));
}

function surfaceOf(layers: readonly string[]): Rgb {
  return flattenLayers(layers.map(colorOf));
}

function ratioOf(pair: ColorPair): number {
  const surface = surfaceOf(pair.surface);
  return contrastRatio(compositeOver(colorOf(pair.foreground), surface), surface);
}

function describePair(pair: ColorPair): string {
  return `${pair.id}: ${pair.use}（${pair.foreground} / ${pair.surface.join(" + ")}）`;
}

const enforced = COLOR_PAIRS.filter((pair) => pair.inactive === undefined);
const exempt = COLOR_PAIRS.filter((pair) => pair.inactive !== undefined);

describe("配色のコントラスト: 実際に使う色の組", () => {
  it("検査の基準は、文字 4.5:1・操作部品の境界と状態の図形 3:1", () => {
    expect(MINIMUM_RATIO).toEqual({ text: 4.5, boundary: 3, graphic: 3 });
  });

  it("色の組の識別子は、重複しない", () => {
    const ids = COLOR_PAIRS.map((pair) => pair.id);

    expect(new Set(ids).size).toBe(ids.length);
  });

  it("文字・境界・図形の、すべての種類を検査している", () => {
    const kinds = new Set(COLOR_PAIRS.map((pair) => pair.kind));

    expect(kinds).toEqual(new Set(["text", "boundary", "graphic"]));
  });

  it("本文・補足・ボタン・枠・ライブ・警告・フォーカスの組を、すべて含む", () => {
    const text = COLOR_PAIRS.map((pair) => `${pair.id} ${pair.use}`).join("\n");

    for (const keyword of ["本文", "補足", "ボタン", "枠", "ライブ", "警告", "フォーカス"]) {
      expect(text).toContain(keyword);
    }
  });

  it.each(enforced.map((pair) => [describePair(pair), pair] as const))("%s", (_description, pair) => {
    expect(ratioOf(pair)).toBeGreaterThanOrEqual(MINIMUM_RATIO[pair.kind]);
  });
});

describe("配色のコントラスト: 無効の状態（基準に届かないが、WCAG 2.2 が対象外とする組）", () => {
  // 無効（inactive）の部品は、WCAG 2.2 の 1.4.3・1.4.11 の対象外。要件 17.2 は免除を明記していないため、完了報告で「要判断」として伝える。
  // 注記が古くならないよう、基準へ届いたら、この検査が落ちる（注記を外す）。
  it.each(exempt.map((pair) => [describePair(pair), pair] as const))("%s", (_description, pair) => {
    expect(ratioOf(pair)).toBeLessThan(MINIMUM_RATIO[pair.kind]);
  });
});
