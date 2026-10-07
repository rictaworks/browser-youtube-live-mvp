import { RECAPTCHA_SITE_KEY_ENV_NAME } from "./config";

// bot 判定のエラー。メッセージは、符号・設定の名前だけを持つ（トークン・サイトキー・URL を含めない）。
// 利用者へ表示する文言は、これらの型を見て、画面が文言カタログから選ぶ。

/** サイトキーが、無い（本番）・不正。サーバー側の設定の誤り。黙って続行しない */
export class RecaptchaConfigurationError extends Error {
  readonly reason: "missing" | "invalid";

  constructor(reason: "missing" | "invalid") {
    super(
      reason === "missing"
        ? `reCAPTCHA site key is not configured (${RECAPTCHA_SITE_KEY_ENV_NAME})`
        : `reCAPTCHA site key is invalid (${RECAPTCHA_SITE_KEY_ENV_NAME})`,
    );
    this.name = "RecaptchaConfigurationError";
    this.reason = reason;
  }
}

/** スクリプトを読み込めなかった（通信の失敗・広告ブロッカー・時間切れ） */
export class RecaptchaLoadError extends Error {
  readonly reason: string;

  constructor(reason: string) {
    super(`reCAPTCHA script load failed: ${reason}`);
    this.name = "RecaptchaLoadError";
    this.reason = reason;
  }
}

/** トークンを取得できなかった（execute の失敗・空のトークン・時間切れ） */
export class RecaptchaExecuteError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "RecaptchaExecuteError";
  }
}
