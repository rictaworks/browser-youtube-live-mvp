import type { ReactNode } from "react";
import { classNames } from "@/lib/class-names";
import { t } from "@/messages";
import { Icon } from "./Icon";
import type { IconName } from "./icons";
import styles from "./Notice.module.css";
import { VisuallyHidden } from "./VisuallyHidden";

export type NoticeTone = "info" | "warning" | "error";

export interface NoticeProps {
  /** 情報・警告・エラー（要件 17.5）。既定の図形（アイコン）は、種類ごとに形が異なる */
  tone: NoticeTone;
  /** 何が起きたか（断定。要件 17.1） */
  title: string;
  /** 状態ごとの別の図形（既定は、種類に対応する図形） */
  icon?: IconName;
  /** 次に何をすればよいか（対処）。省略できる */
  children?: ReactNode;
  /** 対処の操作の欄（ボタンなど）。エラーの通知は、対処の操作を伴える */
  action?: ReactNode;
  className?: string;
}

/**
 * 通知。エラーは role=alert（すぐに読み上げる）、情報・警告は role=status（控えめに読み上げる）。
 * 種類は、図形（アイコン）に加えて、支援技術へ読ませる文言（画面には出さない）でも伝える。
 */
export function Notice({ tone, title, icon, children, action, className }: NoticeProps) {
  return (
    <div role={tone === "error" ? "alert" : "status"} className={classNames(styles.notice, styles[tone], className)}>
      <Icon name={icon ?? tone} className={styles.icon} />
      <div className={styles.body}>
        <VisuallyHidden>{t(`provisional.ui.notice.severity.${tone}`)}</VisuallyHidden>
        <strong className={styles.title}>{title}</strong> {children}
      </div>
      {action && <div className={styles.action}>{action}</div>}
    </div>
  );
}
