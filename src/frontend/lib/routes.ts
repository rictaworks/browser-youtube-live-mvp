/**
 * 画面の URL（パス）。リンクの宛先は、ここから参照する。後続の画面（スタジオ・アカウントなど）は、ここへ足す。
 * ランディング（/）は、別の issue が作る。
 */
export const ROUTES = {
  home: "/",
  terms: "/terms",
  privacy: "/privacy",
} as const;
