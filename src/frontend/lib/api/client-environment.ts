import { resolveAppEnvironment, type AppEnvironment } from "@/lib/app-environment";

/**
 * ブラウザで動くコードの環境（development・test・production）。
 * Next.js は、ブラウザ向けのコードの process.env.NODE_ENV（この形のリテラルの参照）だけを、ビルド時に値へ置き換える。
 * lib/app-environment.ts の currentAppEnvironment() は、process.env オブジェクトを渡して読む形のため、ブラウザでは空になり、例外になる
 * （サーバー側のコード、たとえばルートのレイアウトでは、そちらを使える）。未知の値は、既定の環境へ倒さず、例外にする。
 */
export function clientAppEnvironment(): AppEnvironment {
  return resolveAppEnvironment(process.env.NODE_ENV);
}
