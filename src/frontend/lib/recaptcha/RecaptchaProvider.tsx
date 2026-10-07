"use client";

import { createContext, useContext, useMemo, type ReactNode } from "react";
import { clientAppEnvironment } from "@/lib/api/client-environment";
import { RecaptchaClient, type RecaptchaTokenSource } from "./recaptcha-client";
import { createScriptLoader } from "./script-loader";

const RecaptchaContext = createContext<RecaptchaTokenSource | null>(null);

export interface RecaptchaProviderProps {
  /** サイトキー（公開鍵）。ルートのレイアウト（動的）が、サーバー側の環境変数から読んで渡す。無ければ null */
  siteKey: string | null;
  /** 画面のテストで、トークンの取得を差し替える（本番のコードは、渡さない） */
  client?: RecaptchaTokenSource;
  children: ReactNode;
}

/**
 * bot 判定のトークンの取得を、配下の画面へ渡す。スクリプトは、最初のトークンの取得（操作の直前）まで、読み込まない。
 * 環境（development・test・production）は NODE_ENV。サイトキーが空のとき、開発・テストは疑似のトークン、本番は設定エラー。
 */
export function RecaptchaProvider({ siteKey, client, children }: RecaptchaProviderProps) {
  const value = useMemo<RecaptchaTokenSource>(
    () =>
      client ??
      new RecaptchaClient({
        siteKey,
        environment: clientAppEnvironment(),
        loadScript: createScriptLoader(),
      }),
    [client, siteKey],
  );
  return <RecaptchaContext.Provider value={value}>{children}</RecaptchaContext.Provider>;
}

/** bot 判定のトークンの取得。RecaptchaProvider の配下で使う（無ければ、例外にする） */
export function useRecaptcha(): RecaptchaTokenSource {
  const value = useContext(RecaptchaContext);
  if (value === null) {
    throw new Error("useRecaptcha must be used within RecaptchaProvider");
  }
  return value;
}
