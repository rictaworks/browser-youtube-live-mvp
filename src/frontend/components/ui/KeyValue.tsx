import type { ReactNode } from "react";
import { classNames } from "@/lib/class-names";
import styles from "./KeyValue.module.css";

export interface KeyValueListProps {
  /** KeyValueRow を並べる */
  children: ReactNode;
  className?: string;
}

/** キー・バリュー行の一覧。項目名と値の組を、定義リスト（dl）として支援技術へ伝える。 */
export function KeyValueList({ children, className }: KeyValueListProps) {
  return <dl className={classNames(styles.list, className)}>{children}</dl>;
}

export interface KeyValueRowProps {
  /** 項目名 */
  label: ReactNode;
  /** 値（文字列のほか、リンクなどの要素も渡せる） */
  value: ReactNode;
  /** 詰めた表示（スタジオの健全性・利用状況）。既定は、利用規約のような、ゆとりのある表示 */
  compact?: boolean;
}

/** 項目名と値の 1 行。KeyValueList の中に置く。 */
export function KeyValueRow({ label, value, compact = false }: KeyValueRowProps) {
  return (
    <div className={classNames(styles.row, compact && styles.compact)}>
      <dt className={styles.label}>{label}</dt>
      <dd className={styles.value}>{value}</dd>
    </div>
  );
}
