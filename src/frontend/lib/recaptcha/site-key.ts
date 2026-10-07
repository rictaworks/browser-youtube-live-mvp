import { RECAPTCHA_SITE_KEY_ENV_NAME } from "./config";

/**
 * サイトキー（bot 判定の公開鍵）を、サーバー側の環境変数 RECAPTCHA_SITE_KEY から読む。
 * NEXT_PUBLIC_ を付けない（ビルド時に、ブラウザのコードへ固定しない）。ルートのレイアウト（動的）が、要求のたびに呼び、
 * RecaptchaProvider へ渡す。未設定・空・空白だけなら null（キーが無い）。
 */
export function readRecaptchaSiteKey(env: Readonly<Record<string, string | undefined>> = process.env): string | null {
  const value = env[RECAPTCHA_SITE_KEY_ENV_NAME]?.trim();
  return value === undefined || value === "" ? null : value;
}
