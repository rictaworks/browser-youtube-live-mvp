// bot 判定（reCAPTCHA v3）の設定値。行為名・URL・待ち時間は、ここへ集める。
// 出どころ: src/contracts/http-api.md 1.8（行為名）、requirements.md 28.1。

/** 行為名（契約 1.8。アプリケーションが、トークンの行為名として検証する）。contract-actions.test.ts が、契約の表との一致を保証する */
export const RECAPTCHA_ACTIONS = {
  /** POST /api/auth/login/start */
  login: "login",
  /** POST /api/youtube/connect/start */
  youtubeConnect: "youtube_connect",
  /** POST /api/broadcasts */
  broadcastStart: "broadcast_start",
} as const;

export type RecaptchaAction = (typeof RECAPTCHA_ACTIONS)[keyof typeof RECAPTCHA_ACTIONS];

/**
 * 開発・テストでサイトキーが空のときだけ返す、疑似のトークン。アプリケーションの開発・テスト用の疑似の判定が、受け付ける。
 * 本番では、サイトキーが無ければ、このトークンへ倒さず、設定エラーにする。
 */
export const RECAPTCHA_DEV_PASS_TOKEN = "dev-pass";

/** v3 のスクリプト（api.js?render=<サイトキー>）の URL。操作の直前に読み込む */
export const RECAPTCHA_SCRIPT_URL = "https://www.google.com/recaptcha/api.js";

/** スクリプトの読み込みを待つ上限（ミリ秒） */
export const RECAPTCHA_SCRIPT_LOAD_TIMEOUT_MS = 10_000;

/** トークンの取得（execute）を待つ上限（ミリ秒） */
export const RECAPTCHA_EXECUTE_TIMEOUT_MS = 10_000;

/** サイトキーに許す文字。URL へ入れる値のため、英数字・_・- だけに限る（Google の発行するキーは、この範囲） */
export const RECAPTCHA_SITE_KEY_PATTERN = /^[A-Za-z0-9_-]+$/;

/** サイトキーを渡す環境変数の名前（サーバー側。NEXT_PUBLIC_ を付けない。要件 29.4） */
export const RECAPTCHA_SITE_KEY_ENV_NAME = "RECAPTCHA_SITE_KEY";
