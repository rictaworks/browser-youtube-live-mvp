"use client";

import { useEffect } from "react";
import { PageContainer } from "@/components/layout";
import { Button, Notice, PageHeading } from "@/components/ui";
import { t } from "@/messages";

interface ErrorPageProps {
  error: Error & { digest?: string };
  /** 再取得して、再描画する（Next.js 16.3 で安定。error.js の retry） */
  retry: () => void;
}

/**
 * 予期しないエラーの画面（エラー境界。クライアントコンポーネントでなければならない）。
 * 文言は、断定（何が起きたか）と対処（次に何をすればよいか）で構成し、対処の操作（再試行）を伴う（要件 17.1・17.5）。
 * エラーの内容（message）は、利用者へ表示しない（内部の詳細を出さないため）。
 * デバッグで追えるよう、console.error へ出す。サーバー側の例外は、digest でサーバーのログと突き合わせられる。
 */
export default function ErrorPage({ error, retry }: ErrorPageProps) {
  useEffect(() => {
    console.error(`route error boundary (digest: ${error.digest ?? "none"})`, error);
  }, [error]);

  return (
    <PageContainer>
      <PageHeading title={t("provisional.error.heading")} subtitle={t("provisional.error.subheading")} />
      <Notice
        tone="error"
        title={t("provisional.error.notice.title")}
        action={
          <Button variant="primary" icon="retry" onClick={() => retry()}>
            {t("provisional.error.action")}
          </Button>
        }
      >
        {t("provisional.error.notice.body")}
      </Notice>
    </PageContainer>
  );
}
