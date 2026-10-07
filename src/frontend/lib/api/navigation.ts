import type { AppEnvironment } from "@/lib/app-environment";
import { clientAppEnvironment } from "./client-environment";
import { DEV_AUTHORIZATION_PATH_PREFIX, GOOGLE_AUTHORIZATION_HOSTS } from "./config";

/** 遷移を行う関数（テストで差し替える。既定は browserNavigate） */
export type Navigate = (url: string) => void;

/** ブラウザを、指定の URL へ遷移させる（履歴へ残る通常の遷移） */
export function browserNavigate(url: string): void {
  window.location.assign(url);
}

/** 遷移を許さない認可 URL。メッセージに URL を含めない（state などを含みうる） */
export class UnsafeAuthorizationUrlError extends Error {
  constructor() {
    super("authorization URL is not allowed");
    this.name = "UnsafeAuthorizationUrlError";
  }
}

export interface AuthorizationUrlPolicy {
  readonly environment: AppEnvironment;
  /** 現在のページのオリジン（開発の疑似の認可 URL が、同じオリジンかの判定に使う） */
  readonly currentOrigin: string;
}

function isGoogleAuthorizationUrl(url: URL): boolean {
  return url.protocol === "https:" && url.port === "" && GOOGLE_AUTHORIZATION_HOSTS.includes(url.hostname);
}

function isDevelopmentAuthorizationUrl(url: URL, currentOrigin: string): boolean {
  return url.origin === new URL(currentOrigin).origin && url.pathname.startsWith(DEV_AUTHORIZATION_PATH_PREFIX);
}

/**
 * バックエンドが返した認可 URL を、遷移の前に検査する（javascript: など、画面のスクリプトを動かす URL へ遷移させない）。
 *   - 本番: https の Google の認可の画面（accounts.google.com）だけ
 *   - 開発・テスト: 上に加えて、同じオリジンの /api/dev/ 配下（疑似の Google。契約 1.1）
 * 許す URL は、正規化した文字列で返す。許さなければ UnsafeAuthorizationUrlError。
 */
export function assertSafeAuthorizationUrl(rawUrl: string, policy: AuthorizationUrlPolicy): string {
  if (rawUrl.trim() === "") {
    throw new UnsafeAuthorizationUrlError();
  }
  let url: URL;
  try {
    url = new URL(rawUrl, policy.currentOrigin);
  } catch {
    throw new UnsafeAuthorizationUrlError();
  }
  if (url.username !== "" || url.password !== "") {
    throw new UnsafeAuthorizationUrlError();
  }
  if (isGoogleAuthorizationUrl(url)) {
    return url.href;
  }
  if (policy.environment !== "production" && isDevelopmentAuthorizationUrl(url, policy.currentOrigin)) {
    return url.href;
  }
  throw new UnsafeAuthorizationUrlError();
}

/** 認可 URL を検査して、遷移する。ブラウザの現在の環境・オリジンを使う */
export function navigateToAuthorization(rawUrl: string, navigate: Navigate = browserNavigate): void {
  navigate(
    assertSafeAuthorizationUrl(rawUrl, {
      environment: clientAppEnvironment(),
      currentOrigin: window.location.origin,
    }),
  );
}
