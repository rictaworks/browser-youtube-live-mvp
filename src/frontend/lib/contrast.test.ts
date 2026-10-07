import {
  ColorParseError,
  compositeOver,
  contrastRatio,
  flattenLayers,
  parseColor,
  relativeLuminance,
  type Rgb,
} from "./contrast";

// 値の出どころの注記:
// - oklch の変換の期待値は、Chromium 153（Playwright）が canvas で実際に描いた画素（8 ビット）を読み戻した値。
//   範囲外の色（oklch(0.72 0.2 22)）は、ブラウザと同じく sRGB の範囲へ丸める。
// - 純色（赤・緑・青）の oklch は CSS Color 4 が示す値。

function expectRgb(actual: Rgb, expected: Rgb, tolerance: number) {
  expect(Math.abs(actual.r - expected.r)).toBeLessThanOrEqual(tolerance);
  expect(Math.abs(actual.g - expected.g)).toBeLessThanOrEqual(tolerance);
  expect(Math.abs(actual.b - expected.b)).toBeLessThanOrEqual(tolerance);
}

describe("parseColor: 16 進", () => {
  it.each([
    ["#fff", { r: 255, g: 255, b: 255, a: 1 }],
    ["#FFF", { r: 255, g: 255, b: 255, a: 1 }],
    ["#080c18", { r: 8, g: 12, b: 24, a: 1 }],
    ["#f0f4ff", { r: 240, g: 244, b: 255, a: 1 }],
    ["#00000080", { r: 0, g: 0, b: 0, a: 128 / 255 }],
    ["#0008", { r: 0, g: 0, b: 0, a: 136 / 255 }],
  ])("%s を読める", (value, expected) => {
    const actual = parseColor(value);

    expect(actual.r).toBeCloseTo(expected.r, 6);
    expect(actual.g).toBeCloseTo(expected.g, 6);
    expect(actual.b).toBeCloseTo(expected.b, 6);
    expect(actual.a).toBeCloseTo(expected.a, 6);
  });
});

describe("parseColor: rgb()・rgba()", () => {
  it.each([
    ["rgba(0,251,255,0.15)", { r: 0, g: 251, b: 255, a: 0.15 }],
    ["rgba(192, 192, 192, 0.5)", { r: 192, g: 192, b: 192, a: 0.5 }],
    ["rgba(8,12,24,.95)", { r: 8, g: 12, b: 24, a: 0.95 }],
    ["rgb(10, 20, 30)", { r: 10, g: 20, b: 30, a: 1 }],
    ["rgb(10 20 30 / 50%)", { r: 10, g: 20, b: 30, a: 0.5 }],
    ["  RGBA(1,2,3,0.25)  ", { r: 1, g: 2, b: 3, a: 0.25 }],
  ])("%s を読める", (value, expected) => {
    expect(parseColor(value)).toEqual(expected);
  });
});

describe("parseColor: oklch()", () => {
  it.each([
    ["白", "oklch(1 0 0)", { r: 255, g: 255, b: 255 }, 0.5],
    ["黒", "oklch(0 0 0)", { r: 0, g: 0, b: 0 }, 0.5],
    ["灰（#808080）", "oklch(0.59987 0 0)", { r: 128, g: 128, b: 128 }, 1],
    ["赤", "oklch(0.62796 0.25768 29.2339)", { r: 255, g: 0, b: 0 }, 1.5],
    ["緑", "oklch(0.86644 0.29483 142.495)", { r: 0, g: 255, b: 0 }, 1.5],
    ["青", "oklch(0.45201 0.31321 264.052)", { r: 0, g: 0, b: 255 }, 1.5],
    ["範囲内の琥珀（--warn）", "oklch(0.84 0.15 85)", { r: 247, g: 194, b: 67 }, 1.5],
    ["範囲外の赤（--live）は、sRGB の範囲へ丸める", "oklch(0.72 0.2 22)", { r: 255, g: 101, b: 105 }, 1.5],
    ["百分率の明るさ", "oklch(100% 0 0)", { r: 255, g: 255, b: 255 }, 0.5],
  ])("%s: %s", (_label, value, expected, tolerance) => {
    expectRgb(parseColor(value), expected, tolerance);
  });

  it("スラッシュの後ろをアルファとして読む（小数・百分率）", () => {
    expect(parseColor("oklch(0.72 0.2 22 / 0.12)").a).toBeCloseTo(0.12, 6);
    expect(parseColor("oklch(72% 0.2 22 / 12%)").a).toBeCloseTo(0.12, 6);
  });

  it("アルファが無ければ 1", () => {
    expect(parseColor("oklch(0.84 0.15 85)").a).toBe(1);
  });

  it("sRGB の範囲（0〜255）を超える値を返さない", () => {
    const { r, g, b } = parseColor("oklch(0.72 0.2 22)");

    for (const channel of [r, g, b]) {
      expect(channel).toBeGreaterThanOrEqual(0);
      expect(channel).toBeLessThanOrEqual(255);
    }
  });
});

describe("parseColor: 読めない値は例外にする（黙って別の色にしない）", () => {
  it.each([
    ["空文字", ""],
    ["色名", "white"],
    ["var()", "var(--white)"],
    ["桁数の誤り", "#12345"],
    ["16 進以外の文字", "#12345g"],
    ["rgb の要素不足", "rgb(1, 2)"],
    ["数値でない要素", "rgba(a, b, c, d)"],
    ["oklch の要素不足", "oklch(0.5 0.1)"],
    ["アルファが範囲外", "rgba(0, 0, 0, 1.5)"],
    ["rgb の要素が範囲外", "rgb(300, 0, 0)"],
  ])("%s（%p）", (_label, value) => {
    expect(() => parseColor(value)).toThrow(ColorParseError);
  });

  it("例外は、読めなかった値を持つ", () => {
    try {
      parseColor("white");
      throw new Error("例外が投げられませんでした");
    } catch (error) {
      expect(error).toBeInstanceOf(ColorParseError);
      expect((error as ColorParseError).value).toBe("white");
    }
  });
});

describe("compositeOver", () => {
  it("不透明な前景は、背景を隠す", () => {
    expect(compositeOver({ r: 10, g: 20, b: 30, a: 1 }, { r: 200, g: 200, b: 200 })).toEqual({ r: 10, g: 20, b: 30 });
  });

  it("完全に透明な前景は、背景のまま", () => {
    expect(compositeOver({ r: 10, g: 20, b: 30, a: 0 }, { r: 200, g: 100, b: 50 })).toEqual({ r: 200, g: 100, b: 50 });
  });

  it("半透明は、sRGB の値を線形に混ぜる（ブラウザの合成と同じ）", () => {
    expect(compositeOver({ r: 255, g: 0, b: 0, a: 0.5 }, { r: 0, g: 0, b: 0 })).toEqual({ r: 127.5, g: 0, b: 0 });
  });

  it("Chromium の合成結果（rgba(0,251,255,0.15) を #080c18 へ）と 1 以内で一致する", () => {
    const actual = compositeOver(parseColor("rgba(0,251,255,0.15)"), parseColor("#080c18"));

    expectRgb(actual, { r: 6, g: 47, b: 58 }, 1);
  });
});

describe("flattenLayers", () => {
  it("下から順に重ねる。最下層は不透明でなければならない", () => {
    const flattened = flattenLayers(["#080c18", "rgba(0,251,255,0.15)"].map(parseColor));

    expectRgb(flattened, { r: 6, g: 47, b: 58 }, 1);
  });

  it("層が 1 つなら、その色", () => {
    expect(flattenLayers([parseColor("#080c18")])).toEqual({ r: 8, g: 12, b: 24 });
  });

  it("最下層が半透明なら例外にする（何の上に載るか不明なため）", () => {
    expect(() => flattenLayers([parseColor("rgba(0,0,0,0.5)")])).toThrow(RangeError);
  });

  it("層が空なら例外にする", () => {
    expect(() => flattenLayers([])).toThrow(RangeError);
  });
});

describe("relativeLuminance", () => {
  it.each([
    ["黒", { r: 0, g: 0, b: 0 }, 0],
    ["白", { r: 255, g: 255, b: 255 }, 1],
    ["赤", { r: 255, g: 0, b: 0 }, 0.2126],
    ["緑", { r: 0, g: 255, b: 0 }, 0.7152],
    ["青", { r: 0, g: 0, b: 255 }, 0.0722],
  ])("%s", (_label, color, expected) => {
    expect(relativeLuminance(color)).toBeCloseTo(expected, 4);
  });
});

describe("contrastRatio", () => {
  const black: Rgb = { r: 0, g: 0, b: 0 };
  const white: Rgb = { r: 255, g: 255, b: 255 };

  it("黒と白は 21:1", () => {
    expect(contrastRatio(black, white)).toBeCloseTo(21, 6);
  });

  it("同じ色は 1:1", () => {
    expect(contrastRatio(white, white)).toBeCloseTo(1, 6);
  });

  it("引数の順序に依らない", () => {
    expect(contrastRatio(black, white)).toBe(contrastRatio(white, black));
  });

  it.each([
    ["#777777 と白（WCAG の定番の境界値）", "#777777", "#ffffff", 4.48],
    ["#767676 と白", "#767676", "#ffffff", 4.54],
    ["#595959 と白", "#595959", "#ffffff", 7.0],
  ])("%s", (_label, a, b, expected) => {
    const ratio = contrastRatio(flattenLayers([parseColor(a)]), flattenLayers([parseColor(b)]));

    expect(ratio).toBeCloseTo(expected, 1);
  });

  it("本プロジェクトの本文（--white）と背景（--bg）は 17:1 を超える", () => {
    const ratio = contrastRatio(flattenLayers([parseColor("#f0f4ff")]), flattenLayers([parseColor("#080c18")]));

    expect(ratio).toBeGreaterThan(17);
    expect(ratio).toBeLessThan(18);
  });
});
