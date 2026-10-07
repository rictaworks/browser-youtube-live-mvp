// 測定用のブラウザの分類（requirements.md 18.2：ブラウザの種別は、分類（系統と対応の可否）のみを記録する。http-api.md の browser_class）。
// ユーザーエージェントの文字列そのものを返さない・保持しない。呼び出し側が、系統の符号（chromium・firefox・webkit・other）だけを渡す。
// 系統の符号に当てはまらない値（長い文字列を含む）は other で、その値は、結果にも、内部にも残らない。

/** 系統（測定イベントの browser_class.family）。 */
export const BROWSER_FAMILIES = Object.freeze(["chromium", "firefox", "webkit", "other"] as const);
export type BrowserFamily = (typeof BROWSER_FAMILIES)[number];

/** 測定用の分類。 */
export interface BrowserClass {
  readonly family: BrowserFamily;
  /** 能力検出の結果（対応の可否。canStart） */
  readonly supported: boolean;
}

/**
 * 系統の符号と、能力検出の結果（canStart）から、測定用の分類を返す。
 * 符号は、大文字小文字・前後の空白を無視して照合する。当てはまらない値は other。対応の可否が真偽値でなければ RangeError。
 */
export function classifyBrowser(userAgentFamily: string, canStart: boolean): BrowserClass {
  if (typeof canStart !== "boolean") {
    throw new RangeError(`canStart must be a boolean: ${String(canStart)}`);
  }
  const normalized = typeof userAgentFamily === "string" ? userAgentFamily.trim().toLowerCase() : "";
  const family = BROWSER_FAMILIES.find((candidate) => candidate === normalized) ?? "other";
  return Object.freeze({ family, supported: canStart });
}
