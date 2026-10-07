import { formatJst } from "@/lib/format-jst";

/**
 * API の時刻（ISO 8601）を、画面へ出す JST の「YYYY-MM-DD HH:mm」にする。
 * 無い・解釈できない値は null（画面は、時刻を出さない。別の値で補わない）。
 */
export function formatApiTimestamp(value: string | null): string | null {
  if (value === null || value === "") {
    return null;
  }
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : formatJst(date);
}
