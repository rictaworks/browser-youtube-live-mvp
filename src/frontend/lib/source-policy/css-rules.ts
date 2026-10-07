// CSS の方針違反を検知する純粋な関数（ファイルは読まない。適用は styles/css-policy.test.ts）。
//   - 色・余白・書体・文字の大きさの値を、コンポーネントの CSS へ直書きしない（トークンの変数だけを使う）
//   - フォーカスの輪郭を消さない（outline: none など）

import { splitValueTokens, type CssDeclaration } from "../css-declarations";

export interface CssViolation {
  readonly line: number;
  readonly property: string;
  readonly value: string;
  readonly reason: string;
}

const COLOR_NOTATION = /#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color|color-mix)\(/;

// 色を持つプロパティ。値の要素は、トークンの変数・下の語・長さだけを許す（それ以外は、色名などの直書きとみなす）
const COLOR_PROPERTY =
  /^(?:color|fill|stroke|caret-color|accent-color|background|background-color|text-decoration|text-decoration-color|box-shadow|text-shadow|outline|outline-color|border(?:-(?:top|right|bottom|left))?(?:-color)?)$/;
const ALLOWED_COLOR_PROPERTY_WORDS: ReadonlySet<string> = new Set([
  "transparent",
  "currentcolor",
  "inherit",
  "initial",
  "unset",
  "revert",
  "none",
  "solid",
  "dashed",
  "dotted",
  "double",
  "hidden",
  "inset",
  "thin",
  "medium",
  "thick",
  "underline",
  "overline",
  "line-through",
]);
const LENGTH = /^[+-]?(?:\d+\.?\d*|\.\d+)(?:px|em|rem|%)?$/;

// 余白・文字のプロパティ。値の要素は、トークンの変数と、下の語だけを許す
const SIZE_PROPERTY =
  /^(?:padding|margin)(?:-(?:top|right|bottom|left|inline|block)(?:-(?:start|end))?)?$|^(?:gap|row-gap|column-gap|font-size|letter-spacing|line-height|font-family|font-weight)$/;
const ALLOWED_SIZE_PROPERTY_WORDS: ReadonlySet<string> = new Set(["0", "auto", "inherit", "initial", "unset", "normal", "none"]);

const REMOVED_OUTLINE_VALUES: ReadonlySet<string> = new Set(["none", "0", "0px", "hidden"]);

function violation(declaration: CssDeclaration, reason: string): CssViolation {
  return { line: declaration.line, property: declaration.property, value: declaration.value, reason };
}

/** 色の記法（#hex・rgb()・oklch() など）と、色を持つプロパティの色名を見つける。色は、トークンの変数だけを使う。 */
export function findRawColorValues(declarations: readonly CssDeclaration[]): CssViolation[] {
  const violations: CssViolation[] = [];
  for (const declaration of declarations) {
    if (declaration.property.startsWith("--")) {
      continue;
    }
    if (COLOR_NOTATION.test(declaration.value)) {
      violations.push(violation(declaration, "color notation written directly (use a design token)"));
      continue;
    }
    if (!COLOR_PROPERTY.test(declaration.property)) {
      continue;
    }
    const unknown = splitValueTokens(declaration.value).filter((token) => {
      const word = token.toLowerCase();
      return !word.startsWith("var(") && !ALLOWED_COLOR_PROPERTY_WORDS.has(word) && !LENGTH.test(word);
    });
    if (unknown.length > 0) {
      violations.push(violation(declaration, `unexpected value ${unknown.join(" ")} (a named color? use a design token)`));
    }
  }
  return violations;
}

/** 余白・書体・文字の大きさの、値の直書きを見つける。トークンの変数・0・auto などだけを許す。font の省略形は使わない。 */
export function findRawSizeValues(declarations: readonly CssDeclaration[]): CssViolation[] {
  const violations: CssViolation[] = [];
  for (const declaration of declarations) {
    if (declaration.property === "font") {
      violations.push(violation(declaration, "the font shorthand cannot use design tokens (use the longhand properties)"));
      continue;
    }
    if (!SIZE_PROPERTY.test(declaration.property)) {
      continue;
    }
    const direct = splitValueTokens(declaration.value).filter(
      (token) => !token.startsWith("var(") && !ALLOWED_SIZE_PROPERTY_WORDS.has(token.toLowerCase()),
    );
    if (direct.length > 0) {
      violations.push(violation(declaration, `value written directly: ${direct.join(" ")} (use a design token)`));
    }
  }
  return violations;
}

/** フォーカスの輪郭を消す宣言（outline: none・0 など）を見つける（要件 17.6: フォーカスの輪郭を常に表示する）。 */
export function findRemovedOutlines(declarations: readonly CssDeclaration[]): CssViolation[] {
  const violations: CssViolation[] = [];
  for (const declaration of declarations) {
    if (!/^outline(?:-style|-width)?$/.test(declaration.property)) {
      continue;
    }
    const removes = splitValueTokens(declaration.value).some((token) => REMOVED_OUTLINE_VALUES.has(token.toLowerCase()));
    if (removes) {
      violations.push(violation(declaration, "removes the focus outline"));
    }
  }
  return violations;
}
