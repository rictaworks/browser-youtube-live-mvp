import type { ReactNode } from "react";
import type { ChipTone } from "@/components/ui";
import { classNames } from "@/lib/class-names";
import { AccountIcon } from "./AccountIcon";
import type { AccountIconName } from "./icons";
import styles from "./StatusChip.module.css";

export interface StatusChipProps {
  tone: ChipTone;
  /** 状態を表す図形。文言と対で必須（色だけで状態を区別しない。要件 17.2） */
  icon: AccountIconName;
  children: ReactNode;
}

/**
 * YouTube の接続状態のチップ（文言と、状態ごとに形の異なる図形）。見た目は、共通部品の Chip と同じ。
 * 共通部品の Chip は、レジストリのアイコンしか受け取らず、接続済み（check）・未接続（circle）の図形を使えないため、ここに置く。
 */
export function StatusChip({ tone, icon, children }: StatusChipProps) {
  return (
    <span className={classNames(styles.chip, styles[tone])}>
      <AccountIcon name={icon} className={styles.icon} />
      {children}
    </span>
  );
}
