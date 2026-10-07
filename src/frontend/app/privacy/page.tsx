import { PageContainer } from "@/components/layout";
import { Card, ExternalLink, KeyValueList, KeyValueRow, Note, PageHeading } from "@/components/ui";
import { buildPageMetadata } from "@/lib/page-metadata";
import { t } from "@/messages";

export const metadata = buildPageMetadata({
  title: t("provisional.legal.privacy"),
  description: t("provisional.privacy.metaDescription"),
});

/**
 * プライバシーポリシー（/privacy）。ログイン不要。静的に生成する（動的な API を使わない）。
 * 構成・文言は app-ui/Privacy.dc.html（文言は仮置き。公開用の文章は Gemini が書く）。
 * YouTube API サービスを利用する旨・Google プライバシーポリシーへのリンク・権限を取り消せる旨とそのリンクを含む（要件 16.1・31）。
 */
export default function PrivacyPage() {
  return (
    <PageContainer>
      <PageHeading title={t("provisional.privacy.heading")} subtitle={t("provisional.legal.privacy")} />

      <Card eyebrow={t("provisional.privacy.collected.eyebrow")}>
        <KeyValueList>
          <KeyValueRow
            label={t("provisional.privacy.collected.googleId.label")}
            value={t("provisional.privacy.collected.googleId.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.collected.refreshToken.label")}
            value={t("provisional.privacy.collected.refreshToken.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.collected.channelName.label")}
            value={t("provisional.privacy.collected.channelName.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.collected.title.label")}
            value={t("provisional.privacy.collected.title.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.collected.broadcastId.label")}
            value={t("provisional.privacy.collected.broadcastId.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.collected.ipAddress.label")}
            value={t("provisional.privacy.collected.ipAddress.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.collected.media.label")}
            value={t("provisional.privacy.collected.media.value")}
          />
        </KeyValueList>
      </Card>

      <Card eyebrow={t("provisional.privacy.notCollected.eyebrow")}>
        <KeyValueList>
          <KeyValueRow
            label={t("provisional.privacy.notCollected.email.label")}
            value={t("provisional.privacy.notCollected.email.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.notCollected.name.label")}
            value={t("provisional.privacy.notCollected.name.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.notCollected.personal.label")}
            value={t("provisional.privacy.notCollected.personal.value")}
          />
        </KeyValueList>
      </Card>

      <Card eyebrow={t("provisional.privacy.purpose.eyebrow")}>
        <KeyValueList>
          <KeyValueRow
            label={t("provisional.privacy.purpose.login.label")}
            value={t("provisional.privacy.purpose.login.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.purpose.youtube.label")}
            value={t("provisional.privacy.purpose.youtube.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.purpose.measurement.label")}
            value={t("provisional.privacy.purpose.measurement.value")}
          />
        </KeyValueList>
      </Card>

      <Card eyebrow={t("provisional.privacy.retention.eyebrow")}>
        <KeyValueList>
          <KeyValueRow
            label={t("provisional.privacy.retention.samples.label")}
            value={t("provisional.privacy.retention.samples.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.retention.ticket.label")}
            value={t("provisional.privacy.retention.ticket.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.retention.session.label")}
            value={t("provisional.privacy.retention.session.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.retention.refreshToken.label")}
            value={t("provisional.privacy.retention.refreshToken.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.retention.streamId.label")}
            value={t("provisional.privacy.retention.streamId.value")}
          />
        </KeyValueList>
      </Card>

      <Card eyebrow={t("provisional.privacy.youtubeApi.eyebrow")}>
        <Note>{t("provisional.privacy.youtubeApi.body")}</Note>
        <Note>
          <ExternalLink href={t("provisional.privacy.youtubeApi.googlePrivacy.href")}>
            {t("provisional.privacy.youtubeApi.googlePrivacy.label")}
          </ExternalLink>
        </Note>
        <Note>{t("provisional.privacy.youtubeApi.revoke")}</Note>
        <Note>
          <ExternalLink href={t("provisional.privacy.youtubeApi.permissions.href")}>
            {t("provisional.privacy.youtubeApi.permissions.label")}
          </ExternalLink>
        </Note>
      </Card>

      <Card eyebrow={t("provisional.privacy.deletion.eyebrow")}>
        <KeyValueList>
          <KeyValueRow
            label={t("provisional.privacy.deletion.disconnect.label")}
            value={t("provisional.privacy.deletion.disconnect.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.deletion.deleteAccount.label")}
            value={t("provisional.privacy.deletion.deleteAccount.value")}
          />
          <KeyValueRow
            label={t("provisional.privacy.deletion.request.label")}
            value={t("provisional.privacy.deletion.request.value")}
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
