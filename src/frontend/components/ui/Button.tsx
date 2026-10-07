"use client";

import type { ComponentPropsWithoutRef, MouseEvent, ReactNode } from "react";
import { classNames } from "@/lib/class-names";
import styles from "./Button.module.css";
import { Icon } from "./Icon";
import type { IconName } from "./icons";

export type ButtonVariant = "default" | "primary" | "stop";
export type ButtonSize = "medium" | "small";

type BusyProps =
  | {
      /** 処理中でない（既定）。busyLabel は、処理中になったときの文言 */
      busy?: false;
      busyLabel?: string;
    }
  | {
      /** 処理中: 文言を busyLabel（進行形）へ替え、二重の操作を受け付けない */
      busy: true;
      busyLabel: string;
    };

export type ButtonProps = Omit<ComponentPropsWithoutRef<"button">, "type" | "disabled" | "children"> &
  BusyProps & {
    variant?: ButtonVariant;
    size?: ButtonSize;
    /** 文言の前に置く装飾のアイコン（処理中は、回転するアイコンへ替わる） */
    icon?: IconName;
    /** 既定は button（フォームの中でも、誤って送信しない） */
    type?: "button" | "submit" | "reset";
    disabled?: boolean;
    children: ReactNode;
  };

/**
 * ボタン（要件 17.5）。通常・ホバー・押下・フォーカス・無効・処理中の状態を持つ。
 * クリックの処理（処理中の二重操作の遮断）を持つため、クライアントコンポーネント（サーバーコンポーネントからは、onClick を渡さずに描画できる）。
 * 処理中（busy）は、文言を進行形（busyLabel）へ替え、クリック・Enter・Space を受け付けない。
 * 無効（disabled）にはしない（無効にするとフォーカスを失い、キーボードの利用者が操作の位置を見失うため）。
 */
export function Button({
  variant = "default",
  size = "medium",
  icon,
  type = "button",
  disabled = false,
  busy = false,
  busyLabel,
  children,
  className,
  onClick,
  ...rest
}: ButtonProps) {
  if (busy && !busyLabel) {
    throw new Error("Button: busyLabel is required while busy (the label must change to its progressive form)");
  }

  function handleClick(event: MouseEvent<HTMLButtonElement>) {
    if (busy) {
      // 二重送信の防止: 処理中は、フォームの送信も既定の動作も止め、呼び出し側へも通知しない
      event.preventDefault();
      return;
    }
    onClick?.(event);
  }

  return (
    <button
      {...rest}
      type={type}
      disabled={disabled}
      aria-busy={busy || undefined}
      aria-disabled={busy || undefined}
      className={classNames(
        styles.button,
        variant !== "default" && styles[variant],
        size === "small" && styles.small,
        className,
      )}
      onClick={handleClick}
    >
      {busy ? <Icon name="busy" spin /> : icon && <Icon name={icon} />}
      {busy ? busyLabel : children}
    </button>
  );
}
