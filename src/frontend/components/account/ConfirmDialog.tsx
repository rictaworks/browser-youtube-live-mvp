"use client";

import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { Button } from "@/components/ui";
import styles from "./ConfirmDialog.module.css";

export interface ConfirmDialogProps {
  /** 題（h2）。ダイアログの名前 */
  readonly title: string;
  /** 説明。ダイアログの説明（aria-describedby） */
  readonly description: string;
  readonly confirmLabel: string;
  /** 確認の処理中の文言（進行形） */
  readonly confirmBusyLabel: string;
  readonly cancelLabel: string;
  /** 確認の見た目。取り消せない破壊的な操作は stop（ライブの赤） */
  readonly confirmVariant?: "default" | "stop";
  /** 確認の処理中。二重に押せず、閉じられない */
  readonly busy: boolean;
  /** 失敗の通知（ダイアログの中に出す） */
  readonly notice?: ReactNode;
  /** 閉じたとき、開いたときに押したボタンが無くなっていたら、フォーカスを戻す先の要素の id */
  readonly fallbackFocusId?: string;
  onConfirm(): void;
  onCancel(): void;
}

const FOCUSABLE_SELECTOR = 'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
const INITIAL_FOCUS_ATTRIBUTE = "data-initial-focus";

function focusableElements(container: HTMLElement): HTMLElement[] {
  return Array.from(container.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR));
}

/**
 * ダイアログを開く直前に、フォーカスのあった要素（閉じたときに、フォーカスを戻す先）。フォーカスが無ければ（body）、null。
 * 描画の時点で読む。背景を inert にする（コミットで、DOM へ反映される）と、ブラウザは、フォーカスのあった要素からフォーカスを外すため、
 * 効果（コミットの後）で読むと、body になる。開発サーバーの Strict Mode は、効果を 2 回実行し、2 回目は、ダイアログ自身のボタンを読んでしまう。
 */
function focusedElementBeforeOpen(): HTMLElement | null {
  const active = document.activeElement;
  return active instanceof HTMLElement && active !== document.body ? active : null;
}

/** Tab の移動を、ダイアログの中に閉じる（最後から最初へ、最初から最後へ循環する。外にフォーカスがあれば、中へ入れる） */
function trapTab(event: KeyboardEvent, container: HTMLElement): void {
  const elements = focusableElements(container);
  if (elements.length === 0) {
    event.preventDefault();
    return;
  }
  const first = elements[0];
  const last = elements[elements.length - 1];
  const active = document.activeElement;
  const inside = active instanceof Node && container.contains(active);
  if (event.shiftKey && (!inside || active === first)) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && (!inside || active === last)) {
    event.preventDefault();
    first.focus();
  }
}

/**
 * 確認用のダイアログ（ネイティブの confirm の代わり。取り消せない操作の前に、利用者へ確かめる）。
 *   - role=alertdialog・aria-modal。題と説明で、何の確認かを伝える
 *   - 開いた直後は、取り消せる側（キャンセル）へフォーカスを置く。Tab はダイアログの中を循環し、外へ出たフォーカスは、中へ戻す（フォーカストラップ）
 *   - Escape でキャンセルする。背景のクリックでは閉じない。処理中は、閉じられず、確認を二重に押せない
 *   - 閉じたら、開いたときに押したボタンへフォーカスを戻す（そのボタンが無くなっていた・開いたときにフォーカスが無かったときは、fallbackFocusId の要素へ）。
 *     押したボタンは、描画の時点（背景を inert にする前）で控える
 * 背景の画面を操作できなくする（inert）のは、呼び出し側。この部品は、文言を持たない。
 */
export function ConfirmDialog({
  title,
  description,
  confirmLabel,
  confirmBusyLabel,
  cancelLabel,
  confirmVariant = "default",
  busy,
  notice,
  fallbackFocusId,
  onConfirm,
  onCancel,
}: ConfirmDialogProps) {
  const titleId = useId();
  const descriptionId = useId();
  const dialogRef = useRef<HTMLDivElement>(null);
  // 開く直前にフォーカスのあった要素（押したボタン）。最初の描画の値を、そのまま持つ
  const [opener] = useState<HTMLElement | null>(focusedElementBeforeOpen);

  // 開いたとき: キャンセルへフォーカスを置く。閉じたとき: 押したボタンへ戻す（無くなっていれば、指定の要素へ）
  useEffect(() => {
    const dialog = dialogRef.current;
    const initial = dialog?.querySelector<HTMLElement>(`[${INITIAL_FOCUS_ATTRIBUTE}]:not([disabled])`) ?? (dialog ? focusableElements(dialog)[0] : undefined);
    initial?.focus();
    return () => {
      if (opener?.isConnected) {
        opener.focus();
      } else if (fallbackFocusId !== undefined) {
        document.getElementById(fallbackFocusId)?.focus();
      }
    };
  }, [fallbackFocusId, opener]);

  // Escape・Tab・外へ出たフォーカス
  useEffect(() => {
    const dialog = dialogRef.current;
    if (dialog === null) {
      return undefined;
    }
    const handleKeyDown = (event: KeyboardEvent): void => {
      if (event.key === "Escape") {
        event.preventDefault();
        if (!busy) {
          onCancel();
        }
      } else if (event.key === "Tab") {
        trapTab(event, dialog);
      }
    };
    const handleFocusIn = (event: FocusEvent): void => {
      if (event.target instanceof Node && !dialog.contains(event.target)) {
        focusableElements(dialog)[0]?.focus();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    document.addEventListener("focusin", handleFocusIn);
    return () => {
      document.removeEventListener("keydown", handleKeyDown);
      document.removeEventListener("focusin", handleFocusIn);
    };
  }, [busy, onCancel]);

  return (
    <div className={styles.overlay}>
      <div
        ref={dialogRef}
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={descriptionId}
        className={styles.dialog}
      >
        <h2 id={titleId} className={styles.title}>
          {title}
        </h2>
        <p id={descriptionId} className={styles.description}>
          {description}
        </p>
        {notice}
        <div className={styles.actions}>
          <Button disabled={busy} onClick={onCancel} {...{ [INITIAL_FOCUS_ATTRIBUTE]: "" }}>
            {cancelLabel}
          </Button>
          <Button variant={confirmVariant === "stop" ? "stop" : "default"} busy={busy} busyLabel={confirmBusyLabel} onClick={onConfirm}>
            {confirmLabel}
          </Button>
        </div>
      </div>
    </div>
  );
}
