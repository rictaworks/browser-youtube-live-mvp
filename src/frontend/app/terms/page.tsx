import { PageContainer } from "@/components/layout";
import { Card, ExternalLink, KeyValueList, KeyValueRow, Note, PageHeading } from "@/components/ui";
import { buildPageMetadata } from "@/lib/page-metadata";
import { t } from "@/messages";

export const metadata = buildPageMetadata({
  title: t("provisional.legal.terms"),
  description: t("provisional.terms.metaDescription"),
});

/**
 * 利用規約（/terms）。ログイン不要。静的に生成する（動的な API を使わない）。
 * 構成・文言は app-ui/Terms.dc.html（文言は仮置き。公開用の文章は Gemini が書く）。
 */
export default function TermsPage() {
  return (
    <PageContainer>
      <PageHeading title={t("provisional.terms.heading")} subtitle={t("provisional.legal.terms")} />

      <Card eyebrow={t("provisional.terms.service.eyebrow")}>
        <Note>{t("provisional.terms.service.body")}</Note>
      </Card>

      <Card eyebrow={t("provisional.terms.eligibility.eyebrow")}>
        <KeyValueList>
          <KeyValueRow
            label={t("provisional.terms.eligibility.youtube.label")}
            value={t("provisional.terms.eligibility.youtube.value")}
          />
          <KeyValueRow
            label={t("provisional.terms.eligibility.age.label")}
            value={t("provisional.terms.eligibility.age.value")}
          />
          <KeyValueRow
            label={t("provisional.terms.eligibility.line.label")}
            value={t("provisional.terms.eligibility.line.value")}
          />
        </KeyValueList>
      </Card>

      <Card eyebrow={t("provisional.terms.limits.eyebrow")}>
        <KeyValueList>
          <KeyValueRow label={t("provisional.terms.limits.count.label")} value={t("provisional.terms.limits.count.value")} />
          <KeyValueRow
            label={t("provisional.terms.limits.length.label")}
            value={t("provisional.terms.limits.length.value")}
          />
          <KeyValueRow
            label={t("provisional.terms.limits.concurrent.label")}
            value={t("provisional.terms.limits.concurrent.value")}
          />
          <KeyValueRow
            label={t("provisional.terms.limits.frequency.label")}
            value={t("provisional.terms.limits.frequency.value")}
          />
          <KeyValueRow
            label={t("provisional.terms.limits.monthly.label")}
            value={t("provisional.terms.limits.monthly.value")}
          />
          <KeyValueRow label={t("provisional.terms.limits.daily.label")} value={t("provisional.terms.limits.daily.value")} />
        </KeyValueList>
        <Note size="fine">{t("provisional.terms.limits.note")}</Note>
      </Card>

      <Card eyebrow={t("provisional.terms.youtubeTerms.eyebrow")}>
        <Note>{t("provisional.terms.youtubeTerms.body")}</Note>
        <Note>
          <ExternalLink href={t("provisional.terms.youtubeTerms.link.href")}>
            {t("provisional.terms.youtubeTerms.link.label")}
          </ExternalLink>
        </Note>
      </Card>

      <Card eyebrow={t("provisional.terms.provision.eyebrow")}>
        <KeyValueList>
          <KeyValueRow label={t("provisional.terms.provision.fee.label")} value={t("provisional.terms.provision.fee.value")} />
          <KeyValueRow
            label={t("provisional.terms.provision.uptime.label")}
            value={t("provisional.terms.provision.uptime.value")}
          />
          <KeyValueRow
            label={t("provisional.terms.provision.maintenance.label")}
            value={t("provisional.terms.provision.maintenance.value")}
          />
        </KeyValueList>
      </Card>

      <Card eyebrow={t("provisional.legal.contact.eyebrow")}>
        <KeyValueList>
          <KeyValueRow
            label={t("provisional.legal.contact.operator.label")}
            value={t("provisional.legal.contact.operator.value")}
          />
          <KeyValueRow
            label={t("provisional.legal.contact.address.label")}
            value={t("provisional.legal.contact.address.value")}
          />
          <KeyValueRow
            label={t("provisional.legal.contact.effectiveDate.label")}
            value={t("provisional.legal.contact.effectiveDate.value")}
          />
        </KeyValueList>
      </Card>
    </PageContainer>
  );
}
