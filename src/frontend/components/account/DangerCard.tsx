"use client";

import { Button, Card, Note } from "@/components/ui";
import { t } from "@/messages";
import { AccountIcon } from "./AccountIcon";
import { ACCOUNT_BROADCAST_NOTICE_ID } from "./config";
import styles from "./DangerCard.module.css";

export interface DangerCardProps {
  /** 進行中の配信がある（アカウントの削除を無効にする） */
  readonly broadcasting: boolean;
  /** 別の操作を処理中（アカウントの削除を無効にする） */
  readonly busy: boolean;
  onDelete(): void;
}

/** Danger Zone: アカウントの削除の説明と、操作（取り消せないため、押すと、確認のダイアログを開く）。出どころ: app-ui/Account.dc.html */
export function DangerCard({ broadcasting, busy, onDelete }: DangerCardProps) {
  return (
    <Card eyebrow={t("provisional.account.danger.eyebrow")} className={styles.danger}>
      <Note>{t("provisional.account.danger.note")}</Note>
      <div className={styles.actions}>
        <Button
          variant="stop"
          disabled={broadcasting || busy}
          aria-describedby={broadcasting ? ACCOUNT_BROADCAST_NOTICE_ID : undefined}
          onClick={onDelete}
        >
          <AccountIcon name="trash" />
          {t("provisional.account.danger.delete")}
        </Button>
      </div>
    </Card>
  );
}
