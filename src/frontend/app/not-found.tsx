import { PageContainer } from "@/components/layout";
import { ButtonLink, Notice, PageHeading } from "@/components/ui";
import { buildPageMetadata } from "@/lib/page-metadata";
import { ROUTES } from "@/lib/routes";
import { t } from "@/messages";

// 404 の画面。Next.js が、404 の応答に noindex を付ける
export const metadata = buildPageMetadata({
  title: t("provisional.notFound.heading"),
  description: t("provisional.notFound.notice.title"),
});

/** 404（存在しないページ）。文言は、断定（何が起きたか）と対処（次に何をすればよいか）で構成する（要件 17.1）。 */
export default function NotFound() {
  return (
    <PageContainer>
      <PageHeading title={t("provisional.notFound.heading")} subtitle={t("provisional.notFound.subheading")} />
      <Notice
        tone="error"
        title={t("provisional.notFound.notice.title")}
        action={
          <ButtonLink href={ROUTES.home} variant="primary">
            {t("provisional.notFound.action")}
          </ButtonLink>
        }
      >
        {t("provisional.notFound.notice.body")}
      </Notice>
    </PageContainer>
  );
}
