/** reCAPTCHA v3 の、使う範囲のブラウザ API（window.grecaptcha） */
export interface GreCaptcha {
  /** スクリプトの準備ができたら、コールバックを呼ぶ */
  ready(callback: () => void): void;
  /** トークンを取得する。action は、行為名 */
  execute(siteKey: string, options: { action: string }): Promise<string>;
}

/** スクリプトを読み込んで、準備のできた grecaptcha を返す関数（注入できる） */
export type ScriptLoader = (siteKey: string) => Promise<GreCaptcha>;
