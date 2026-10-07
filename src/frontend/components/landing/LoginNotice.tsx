"use client";

import { Notice } from "@/components/ui";
import { useLandingLogin, type LoginPlacement } from "./LandingLogin";
import { viewOfLoginNotice } from "./login-notices";
import styles from "./LoginNotice.module.css";

export interface LoginNoticeProps {
  /** この場所に、通知を出す（押したボタンの場所と、URL の login_error の通知はヒーロー） */
  placement: LoginPlacement;
}

/** ログインの拒否・失敗の通知（断定と対処）。種類は、色と図形と文言で伝える。通知が無い・別の場所のときは、何も出さない */
export function LoginNotice({ placement }: LoginNoticeProps) {
  const { notice } = useLandingLogin();
  if (notice === null || notice.placement !== placement) {
    return null;
  }
  const view = viewOfLoginNotice(notice.notice);
  return (
    <Notice tone={view.tone} title={view.title} className={styles.notice}>
      {view.body}
    </Notice>
  );
}
