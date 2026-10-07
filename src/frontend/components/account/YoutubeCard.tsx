"use client";

import { Button, Card, ExternalLink, KeyValueList, KeyValueRow, LiveRegion, Note } from "@/components/ui";
import { LIMITS } from "@/core/contract";
import type { YoutubeView } from "@/lib/api";
import { t } from "@/messages";
import { AccountIcon } from "./AccountIcon";
import { chipViewFor, connectViewFor, guideFor, visibilityFor } from "./account-view";
import type { AccountAction } from "./account-notices";
import { ACCOUNT_BROADCAST_NOTICE_ID, ACCOUNT_CONNECT_BUTTON_ID, ACCOUNT_RECHECK_HINT_ID } from "./config";
import { StatusChip } from "./StatusChip";
import styles from "./YoutubeCard.module.css";

export interface YoutubeCardProps {
  readonly youtube: YoutubeView;
  /** 進行中の配信がある（接続の解除・再接続を無効にする） */
  readonly broadcasting: boolean;
  /** 接続の不成立の通知（権限の拒否・更新トークンなし・チャンネルなし）を出している */
  readonly afterConnectFailure: boolean;
  /** 処理中の操作（なければ null）。処理中の操作は進行形の文言にし、ほかの操作は無効にする */
  readonly pending: AccountAction | null;
  /** 再確認できる時刻まで、再確認を無効にしている */
  readonly cooling: boolean;
  /** 再確認できる時刻（JST の日時の文字列）。無効にしている間だけ */
  readonly recheckAvailableAt: string | null;
  onRecheck(): void;
  onConnect(): void;
  onDisconnect(): void;
}

/** 接続先のチャンネル名。取得できなければ（null）、取得できなかった旨と対処を示す（図形も伴う） */
function ChannelValue({ title }: { title: string | null }) {
  if (title !== null) {
    return <>{title}</>;
  }
  return (
    <span className={styles.unavailable}>
      <AccountIcon name="warning" className={styles.unavailableIcon} />
      <strong>{t("provisional.account.youtube.channel.unavailableTitle")}</strong> {t("provisional.account.youtube.channel.unavailableBody")}
    </span>
  );
}

/**
 * YouTube の接続のカード: 接続の状態（チップ）・接続先のチャンネル・案内・操作（再確認・接続・再接続・接続を解除）・注記・権限の管理のリンク。
 * 状態ごとの出し分けは、account-view.ts（要件 7.2・7.4）。出どころ: app-ui/Account.dc.html。
 */
export function YoutubeCard({
  youtube,
  broadcasting,
  afterConnectFailure,
  pending,
  cooling,
  recheckAvailableAt,
  onRecheck,
  onConnect,
  onDisconnect,
}: YoutubeCardProps) {
  const chip = chipViewFor(youtube.state);
  const visible = visibilityFor(youtube.state);
  const connect = connectViewFor(youtube.state);
  const busyElsewhere = (action: AccountAction): boolean => pending !== null && pending !== action;
  const broadcastNoticeId = broadcasting ? ACCOUNT_BROADCAST_NOTICE_ID : undefined;
  return (
    <Card eyebrow={t("provisional.account.youtube.eyebrow")}>
      <KeyValueList>
        <KeyValueRow
          label={t("provisional.account.youtube.statusLabel")}
          value={
            <LiveRegion>
              <StatusChip tone={chip.tone} icon={chip.icon}>
                {chip.label}
              </StatusChip>
            </LiveRegion>
          }
        />
        {visible.channel && (
          <KeyValueRow label={t("provisional.account.youtube.channelLabel")} value={<ChannelValue title={youtube.channel_title} />} />
        )}
      </KeyValueList>
      <Note>{guideFor(youtube.state, { broadcasting, afterConnectFailure })}</Note>
      <div className={styles.actions}>
        {visible.recheck && (
          <>
            <Button
              icon="retry"
              busy={pending === "recheck"}
              busyLabel={t("provisional.account.youtube.actions.recheckBusy")}
              disabled={cooling || busyElsewhere("recheck")}
              aria-describedby={cooling ? ACCOUNT_RECHECK_HINT_ID : undefined}
              onClick={onRecheck}
            >
              {t("provisional.account.youtube.actions.recheck")}
            </Button>
            <span id={ACCOUNT_RECHECK_HINT_ID} className={styles.hint}>
              {t("provisional.account.youtube.actions.recheckLimit", {
                windowMinutes: LIMITS.rate_limits.recheck_per_minute.window_seconds / 60,
                perWindow: LIMITS.rate_limits.recheck_per_minute.limit,
                perDay: LIMITS.rate_limits.recheck_per_day.limit,
              })}
              {cooling && recheckAvailableAt !== null && (
                <>
                  {" "}
                  <span>{t("provisional.account.youtube.actions.recheckAvailableAt", { time: recheckAvailableAt })}</span>
                </>
              )}
            </span>
          </>
        )}
        {visible.connect && (
          <Button
            id={ACCOUNT_CONNECT_BUTTON_ID}
            variant={connect.primary ? "primary" : "default"}
            busy={pending === "connect"}
            busyLabel={t("provisional.account.youtube.actions.connectBusy")}
            disabled={broadcasting || busyElsewhere("connect")}
            aria-describedby={broadcastNoticeId}
            onClick={onConnect}
          >
            <AccountIcon name="youtube" />
            {connect.label}
          </Button>
        )}
        {visible.disconnect && (
          <Button disabled={broadcasting || pending !== null} aria-describedby={broadcastNoticeId} onClick={onDisconnect}>
            {t("provisional.account.youtube.actions.disconnect")}
          </Button>
        )}
      </div>
      {visible.disconnect && <Note size="fine">{t("provisional.account.youtube.disconnectNote")}</Note>}
      {visible.channel && (
        <Note size="fine">
          {t("provisional.account.youtube.channel.note", { minutes: LIMITS.retention.channel_title_memory_max_minutes })}
        </Note>
      )}
      <Note size="fine">
        {t("provisional.account.youtube.permissionsNote")}{" "}
        <ExternalLink href={t("provisional.privacy.youtubeApi.permissions.href")}>
          {t("provisional.privacy.youtubeApi.permissions.label")}
        </ExternalLink>
      </Note>
    </Card>
  );
}
