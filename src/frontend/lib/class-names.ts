export type ClassNamePart = string | false | null | undefined;

/**
 * CSS Modules のクラス名をつなぐ。false・null・undefined・空文字は除く。
 * 条件式（`busy && styles.busy`）の結果をそのまま渡せる。
 */
export function classNames(...parts: ClassNamePart[]): string {
  return parts.filter((part): part is string => typeof part === "string" && part !== "").join(" ");
}
