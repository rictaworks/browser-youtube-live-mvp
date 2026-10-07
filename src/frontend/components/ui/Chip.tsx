import type { ReactNode } from "react";
import { classNames } from "@/lib/class-names";
import styles from "./Chip.module.css";
import { Icon } from "./Icon";
import type { IconName } from "./icons";

export type ChipTone = "neutral" | "ok" | "warn" | "bad";

export interface ChipProps {
  tone?: ChipTone;
  /** 状態を表す図形。文言と対で必須（色だけで状態を区別しない。要件 17.2） */
  icon: IconName;
  /** 状態の文言 */
  children: ReactNode;
  className?: string;
}

/** チップ。状態の文言と、形の異なる図形（アイコン）を伴って表示する。 */
export function Chip({ tone = "neutral", icon, children, className }: ChipProps) {
  return (
    <span className={classNames(styles.chip, styles[tone], className)}>
      <Icon name={icon} className={styles.icon} />
      {children}
    </span>
  );
}
