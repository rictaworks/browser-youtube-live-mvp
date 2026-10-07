// ランディング（/）の設定値。画面の URL・クエリ名・見出しの識別子は、ここへ集める。

/** ログイン済みの利用者を誘導する、スタジオの URL（requirements.md 16.1。画面は、別の issue が作る） */
export const STUDIO_ROUTE = "/studio";

/** ログインの失敗を知らせるクエリの名前（契約 http-api.md: /?login_error=<login_error>） */
export const LOGIN_ERROR_QUERY = "login_error";

/** 区画の識別子（見出しの id は、区画の識別子 + -heading。section の名前に使う） */
export const LANDING_SECTION_IDS = {
  hero: "landing-hero",
  value: "landing-value",
  limits: "landing-limits",
  environment: "landing-environment",
  final: "landing-final",
} as const;
