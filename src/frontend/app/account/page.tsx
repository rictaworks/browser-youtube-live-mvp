import type { Metadata } from "next";
import { PageContainer } from "@/components/layout";
import { CONNECT_QUERY } from "@/components/account/config";
import { AccountScreen } from "@/components/account/AccountScreen";
import { isConnectResult, type ConnectResult } from "@/core/contract";
import { buildPageMetadata } from "@/lib/page-metadata";
import { t } from "@/messages";

// ログインが要る画面（未ログインは、ランディングへ誘導する）。検索エンジンへ載せない。
export const metadata: Metadata = {
  ...buildPageMetadata({
    title: t("provisional.account.heading"),
    description: t("provisional.account.subheading"),
  }),
  robots: { index: false, follow: false },
};

type SearchParams = Promise<Record<string, string | string[] | undefined>>;

/** URL の connect（YouTube 接続の戻り先）を検証する。未知の値・複数の値は、無いものとして扱う（別の通知へ倒さない） */
function parseConnectResult(value: string | string[] | undefined): ConnectResult | null {
  return typeof value === "string" && isConnectResult(value) ? value : null;
}

/**
 * アカウント（/account）。ログインが要る。YouTube の接続状態・再確認・接続・接続の解除・アカウントの削除・ログアウト（requirements.md 16.1）。
 * 構成・文言は app-ui/Account.dc.html（文言は仮置き。公開用の文章は Gemini が書く）。
 * YouTube 接続の結果（/account?connect=<結果>）は、不成立なら通知で示し、結果のクエリは、画面が URL から取り除く。
 */
export default async function AccountPage({ searchParams }: { searchParams: SearchParams }) {
  const query = await searchParams;
  return (
    <PageContainer>
      <AccountScreen initialConnectResult={parseConnectResult(query[CONNECT_QUERY])} />
    </PageContainer>
  );
}
