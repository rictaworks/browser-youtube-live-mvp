// CSS のカスタムプロパティ（トークン）を、ファイルの文字列から読む。
// コントラストの検査が「トークンの値」から計算するための部品（実行時の画面は使わない）。

export class UnknownCustomPropertyError extends Error {
  readonly propertyName: string;

  constructor(propertyName: string) {
    super(`custom property ${propertyName} is not defined`);
    this.name = "UnknownCustomPropertyError";
    this.propertyName = propertyName;
  }
}

export class CircularCustomPropertyError extends Error {
  readonly propertyName: string;

  constructor(propertyName: string, trail: readonly string[]) {
    super(`custom property ${propertyName} refers to itself: ${trail.join(" -> ")}`);
    this.name = "CircularCustomPropertyError";
    this.propertyName = propertyName;
  }
}

const COMMENT_PATTERN = /\/\*[\s\S]*?\*\//g;
const DECLARATION_PATTERN = /(--[A-Za-z0-9_-]+)\s*:\s*([^;{}]+?)\s*(?=;|\})/g;
const VAR_REFERENCE_PATTERN = /var\(\s*(--[A-Za-z0-9_-]+)\s*\)/g;

/**
 * CSS の文字列から、カスタムプロパティの宣言（`--name: value;`）を読む。
 * コメントは除く。同じ名前が複数あれば、あとの宣言が勝つ。
 */
export function parseCustomProperties(css: string): Map<string, string> {
  const properties = new Map<string, string>();
  const withoutComments = css.replace(COMMENT_PATTERN, "");
  for (const match of withoutComments.matchAll(DECLARATION_PATTERN)) {
    properties.set(match[1], match[2]);
  }
  return properties;
}

/**
 * カスタムプロパティの値を、`var(--other)` を再帰的に置き換えて返す。
 * 未定義の名前・循環する参照は、既定値を補わず例外にする。
 */
export function resolveCustomProperty(
  name: string,
  properties: ReadonlyMap<string, string>,
  trail: readonly string[] = [],
): string {
  if (trail.includes(name)) {
    throw new CircularCustomPropertyError(name, [...trail, name]);
  }
  const value = properties.get(name);
  if (value === undefined) {
    throw new UnknownCustomPropertyError(name);
  }
  return value.replace(VAR_REFERENCE_PATTERN, (_match, referenced: string) =>
    resolveCustomProperty(referenced, properties, [...trail, name]),
  );
}
