// 色のコントラスト比（WCAG 2.x の相対輝度）を、CSS の色の記法から計算する純粋な関数。
// 配色の検査（styles/contrast.test.ts）が、トークンの値（#hex・rgb()・rgba()・oklch()）から比を求めるために使う。
// 実行時の画面は使わない。現在時刻・環境に依存しない。

/** sRGB（ガンマ符号化）の 0〜255。小数を含む。 */
export interface Rgb {
  readonly r: number;
  readonly g: number;
  readonly b: number;
}

/** アルファ（0〜1）付きの sRGB。 */
export interface Rgba extends Rgb {
  readonly a: number;
}

export class ColorParseError extends Error {
  readonly value: string;

  constructor(value: string, reason: string) {
    super(`cannot parse color ${JSON.stringify(value)}: ${reason}`);
    this.name = "ColorParseError";
    this.value = value;
  }
}

const NUMBER_PATTERN = /^[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?$/;
// CSS Color 4: oklch() の彩度 100% は 0.4
const OKLCH_CHROMA_AT_100_PERCENT = 0.4;

function parseNumber(original: string, token: string, what: string): number {
  if (!NUMBER_PATTERN.test(token)) {
    throw new ColorParseError(original, `${what} is not a number: ${JSON.stringify(token)}`);
  }
  return Number(token);
}

/** 「50%」は割合の 50 を、数だけの「0.5」は 0.5 を、percentBase を 100% として返す。 */
function parseNumberOrPercent(original: string, token: string, what: string, percentBase: number): number {
  if (token.endsWith("%")) {
    return (parseNumber(original, token.slice(0, -1), what) / 100) * percentBase;
  }
  return parseNumber(original, token, what);
}

function requireRange(original: string, what: string, value: number, min: number, max: number): number {
  if (value < min || value > max) {
    throw new ColorParseError(original, `${what} ${value} is out of range ${min}..${max}`);
  }
  return value;
}

function parseHex(original: string, text: string): Rgba {
  const digits = text.slice(1);
  if (!/^[0-9a-f]+$/.test(digits) || ![3, 4, 6, 8].includes(digits.length)) {
    throw new ColorParseError(original, "hex color must be #rgb, #rgba, #rrggbb or #rrggbbaa");
  }
  const expanded = digits.length <= 4 ? [...digits].map((digit) => digit + digit).join("") : digits;
  const channel = (index: number) => parseInt(expanded.slice(index * 2, index * 2 + 2), 16);
  return {
    r: channel(0),
    g: channel(1),
    b: channel(2),
    a: expanded.length === 8 ? channel(3) / 255 : 1,
  };
}

/** 関数の引数を、色の要素とアルファに分ける。カンマ区切り（旧記法）とスペース区切り＋スラッシュ（新記法）の両方。 */
function splitArguments(original: string, args: string, componentCount: number): { components: string[]; alpha: string | undefined } {
  const trimmed = args.trim();
  let components: string[];
  let alpha: string | undefined;
  if (trimmed.includes("/")) {
    const [colorPart, alphaPart, ...rest] = trimmed.split("/");
    if (rest.length > 0 || alphaPart === undefined) {
      throw new ColorParseError(original, "more than one '/' in color arguments");
    }
    components = colorPart.trim().split(/\s+/);
    alpha = alphaPart.trim();
  } else if (trimmed.includes(",")) {
    const parts = trimmed.split(",").map((part) => part.trim());
    components = parts.slice(0, componentCount);
    alpha = parts[componentCount];
    if (parts.length > componentCount + 1) {
      throw new ColorParseError(original, "too many color arguments");
    }
  } else {
    components = trimmed.split(/\s+/);
  }
  if (components.length !== componentCount || components.some((component) => component === "")) {
    throw new ColorParseError(original, `expected ${componentCount} color components, got ${components.length}`);
  }
  return { components, alpha };
}

function parseAlpha(original: string, alpha: string | undefined): number {
  if (alpha === undefined) {
    return 1;
  }
  return requireRange(original, "alpha", parseNumberOrPercent(original, alpha, "alpha", 1), 0, 1);
}

function parseRgb(original: string, args: string): Rgba {
  const { components, alpha } = splitArguments(original, args, 3);
  const [r, g, b] = components.map((component, index) =>
    requireRange(
      original,
      `rgb channel ${index + 1}`,
      parseNumberOrPercent(original, component, `rgb channel ${index + 1}`, 255),
      0,
      255,
    ),
  );
  return { r, g, b, a: parseAlpha(original, alpha) };
}

function encodeGamma(linear: number): number {
  const clamped = Math.min(1, Math.max(0, linear));
  const encoded = clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * clamped ** (1 / 2.4) - 0.055;
  return encoded * 255;
}

/**
 * OKLCH（明るさ・彩度・色相の度）を、sRGB へ変換する。
 * 変換式は Björn Ottosson の OKLab（https://bottosson.github.io/posts/oklab/ ）。
 * sRGB の範囲外の色は、各チャンネルを範囲へ丸める（Chromium 153 の canvas の読み戻しで、同じ結果になることを確認済み）。
 */
function oklchToRgb(lightness: number, chroma: number, hueDegrees: number): Rgb {
  const hue = (hueDegrees * Math.PI) / 180;
  const a = chroma * Math.cos(hue);
  const b = chroma * Math.sin(hue);
  const l = (lightness + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m = (lightness - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s = (lightness - 0.0894841775 * a - 1.291485548 * b) ** 3;
  return {
    r: encodeGamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    g: encodeGamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    b: encodeGamma(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
  };
}

function parseOklch(original: string, args: string): Rgba {
  const { components, alpha } = splitArguments(original, args, 3);
  const [lightnessToken, chromaToken, hueToken] = components;
  const lightness = requireRange(original, "lightness", parseNumberOrPercent(original, lightnessToken, "lightness", 1), 0, 1);
  const chroma = parseNumberOrPercent(original, chromaToken, "chroma", OKLCH_CHROMA_AT_100_PERCENT);
  if (chroma < 0) {
    throw new ColorParseError(original, "chroma must not be negative");
  }
  const hue = parseNumber(original, hueToken.endsWith("deg") ? hueToken.slice(0, -3) : hueToken, "hue");
  return { ...oklchToRgb(lightness, chroma, hue), a: parseAlpha(original, alpha) };
}

/**
 * CSS の色（#hex・rgb()・rgba()・oklch()）を、アルファ付きの sRGB（0〜255）へ読む。
 * 色名・var()・読めない記法は、別の色へ読み替えず ColorParseError にする。
 */
export function parseColor(value: string): Rgba {
  const text = value.trim().toLowerCase();
  if (text.startsWith("#")) {
    return parseHex(value, text);
  }
  const functional = /^([a-z]+)\((.*)\)$/.exec(text);
  if (functional === null) {
    throw new ColorParseError(value, "unsupported color syntax");
  }
  const [, name, args] = functional;
  if (name === "rgb" || name === "rgba") {
    return parseRgb(value, args);
  }
  if (name === "oklch") {
    return parseOklch(value, args);
  }
  throw new ColorParseError(value, `unsupported color function ${name}()`);
}

/** 前景（アルファ付き）を、不透明な背景へ重ねた色。合成は、ブラウザと同じく sRGB の値の上で行う。 */
export function compositeOver(foreground: Rgba, background: Rgb): Rgb {
  const mix = (front: number, back: number) => front * foreground.a + back * (1 - foreground.a);
  return {
    r: mix(foreground.r, background.r),
    g: mix(foreground.g, background.g),
    b: mix(foreground.b, background.b),
  };
}

/** 層を下から順に重ねた色。最下層は、何の上にも載らないため、不透明でなければならない。 */
export function flattenLayers(layers: readonly Rgba[]): Rgb {
  if (layers.length === 0) {
    throw new RangeError("flattenLayers: at least one layer is required");
  }
  const [bottom, ...rest] = layers;
  if (bottom.a !== 1) {
    throw new RangeError(`flattenLayers: the bottom layer must be opaque (alpha ${bottom.a})`);
  }
  return rest.reduce<Rgb>((below, layer) => compositeOver(layer, below), { r: bottom.r, g: bottom.g, b: bottom.b });
}

function linearize(channel: number): number {
  const normalized = channel / 255;
  return normalized <= 0.04045 ? normalized / 12.92 : ((normalized + 0.055) / 1.055) ** 2.4;
}

/** WCAG 2.x の相対輝度（0 = 黒、1 = 白）。 */
export function relativeLuminance(color: Rgb): number {
  return 0.2126 * linearize(color.r) + 0.7152 * linearize(color.g) + 0.0722 * linearize(color.b);
}

/** WCAG 2.x のコントラスト比（1〜21）。引数の順序に依らない。 */
export function contrastRatio(a: Rgb, b: Rgb): number {
  const luminanceA = relativeLuminance(a);
  const luminanceB = relativeLuminance(b);
  return (Math.max(luminanceA, luminanceB) + 0.05) / (Math.min(luminanceA, luminanceB) + 0.05);
}
