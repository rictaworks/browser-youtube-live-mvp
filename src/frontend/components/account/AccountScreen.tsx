"use client";

import { useRouter } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import { Button, LiveRegion, Notice, PageHeading } from "@/components/ui";
import type { ConnectResult } from "@/core/contract";
import { ApiClient, browserNavigate, type Navigate } from "@/lib/api";
import { useRecaptcha } from "@/lib/recaptcha";
import { ROUTES } from "@/lib/routes";
import { t } from "@/messages";
import styles from "./AccountScreen.module.css";
import { AccountIcon } from "./AccountIcon";
import { viewOfAccountNotice, type AccountNotice } from "./account-notices";
import { ACCOUNT_BROADCAST_NOTICE_ID, ACCOUNT_CONNECT_BUTTON_ID } from "./config";
import { ConfirmDialog } from "./ConfirmDialog";
import { DangerCard } from "./DangerCard";
import { useAccount } from "./use-account";
import { YoutubeCard } from "./YoutubeCard";

export interface AccountScreenProps {
  /** URL の connect（サーバー側で検証済み）。不成立なら、通知を出す */
  initialConnectResult: ConnectResult | null;
  /** テストで差し替える。既定は、同一オリジンの /api/* を呼ぶクライアント */
  client?: ApiClient;
  /** テストで差し替える。既定は、ブラウザの遷移 */
  navigate?: Navigate;
  /** テストで差し替える。既定は、実時刻 */
  now?: () => number;
}

/** 接続の不成立の通知（権限の拒否・更新トークンなし・チャンネルなし）か。未接続の案内を、短くする条件 */
function isConnectFailureNotice(notice: AccountNotice | null): boolean {
  return notice !== null && ["connect_scope_denied", "connect_no_refresh_token", "connect_no_channel"].includes(notice.kind);
}

function NoticeView({ notice }: { notice: AccountNotice }) {
  const view = viewOfAccountNotice(notice);
  return (
    <Notice tone={view.tone} title={view.title}>
      {view.body}
    </Notice>
  );
}

/**
 * アカウント画面（/account）の本体: YouTube の接続状態・再確認・接続・接続の解除・アカウントの削除・ログアウト（要件 16.1・7.2・7.4）。
 * 状態と操作は use-account.ts。接続の解除・アカウントの削除は、確認のダイアログ（ConfirmDialog）で確かめてから、API を呼ぶ。
 * ダイアログを開いている間、背景の画面は操作できない（inert）。未ログインは、ランディングへ移る。
 */
export function AccountScreen({ initialConnectResult, client, navigate = browserNavigate, now = Date.now }: AccountScreenProps) {
  const recaptcha = useRecaptcha();
  const router = useRouter();
  const [apiClient] = useState(() => client ?? new ApiClient());
  // ルーターの参照が、描画のたびに変わっても、操作の関数を作り直さない（状態の取得が、繰り返されないように）
  const routerRef = useRef(router);
  useEffect(() => {
    routerRef.current = router;
  });
  const goHome = useCallback((): void => routerRef.current.replace(ROUTES.home), []);

  const account = useAccount({ client: apiClient, recaptcha, goHome, navigate, initialConnectResult, now });
  const { load, notice, pending, dialog } = account;
  const broadcasting = load.status === "ready" && load.state.broadcast !== null;

  return (
    <>
      <div inert={dialog !== null} className={styles.screen}>
        <PageHeading title={t("provisional.account.heading")} subtitle={t("provisional.account.subheading")} />

        {load.status === "loading" && <LiveRegion>{t("provisional.account.loading")}</LiveRegion>}

        {load.status === "failed" && (
          <Notice
            tone="error"
            title={t("provisional.error.notice.title")}
            action={
              <Button variant="primary" icon="retry" onClick={account.reload}>
                {t("provisional.error.action")}
              </Button>
            }
          >
            {t("provisional.error.notice.body")}
          </Notice>
        )}

        {load.status === "ready" && (
          <>
            {broadcasting && (
              <div id={ACCOUNT_BROADCAST_NOTICE_ID}>
                <Notice tone="warning" title={t("provisional.account.broadcastInProgress.title")}>
                  {t("provisional.account.broadcastInProgress.body")}
                </Notice>
              </div>
            )}
            {notice !== null && <NoticeView notice={notice} />}
            <YoutubeCard
              youtube={load.state.youtube}
              broadcasting={broadcasting}
              afterConnectFailure={isConnectFailureNotice(notice)}
              pending={pending}
              cooling={account.cooling}
              recheckAvailableAt={account.recheckAvailableAt}
              onRecheck={account.recheck}
              onConnect={account.connect}
              onDisconnect={() => account.openDialog("disconnect")}
            />
            <DangerCard broadcasting={broadcasting} busy={pending !== null} onDelete={() => account.openDialog("delete")} />
            <div className={styles.actions}>
              <Button disabled={pending !== null && pending !== "logout"} busy={pending === "logout"} busyLabel={t("provisional.account.logout.busy")} onClick={account.logout}>
                <AccountIcon name="logout" />
                {t("provisional.account.logout.label")}
              </Button>
            </div>
          </>
        )}
      </div>

      {dialog !== null && (
        <ConfirmDialog
          title={dialog.kind === "disconnect" ? t("provisional.account.youtube.actions.disconnect") : t("provisional.account.danger.delete")}
          description={dialog.kind === "disconnect" ? t("provisional.account.youtube.disconnectNote") : t("provisional.account.danger.note")}
          confirmLabel={dialog.kind === "disconnect" ? t("provisional.account.youtube.actions.disconnect") : t("provisional.account.danger.delete")}
          confirmBusyLabel={dialog.kind === "disconnect" ? t("provisional.account.youtube.actions.disconnectBusy") : t("provisional.account.danger.deleteBusy")}
          cancelLabel={t("provisional.account.dialog.cancel")}
          confirmVariant={dialog.kind === "delete" ? "stop" : "default"}
          busy={pending === dialog.kind}
          notice={dialog.failed ? <NoticeView notice={{ kind: "failed", retryAt: null }} /> : undefined}
          fallbackFocusId={ACCOUNT_CONNECT_BUTTON_ID}
          onConfirm={account.confirmDialog}
          onCancel={account.closeDialog}
        />
      )}
    </>
  );
}
