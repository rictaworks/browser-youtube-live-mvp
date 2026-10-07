import type { ReactNode } from "react";
import { classNames } from "@/lib/class-names";
import styles from "./TwoColumnLayout.module.css";

export interface TwoColumnLayoutProps {
  /** 左のカラム（プレビューと配信制御など）。1 カラムでは先に積む */
  main: ReactNode;
  /** 右のカラム（幅 320 px のパネル。ソース・健全性・記録など）。1 カラムでは、主な内容のあとに積む */
  aside: ReactNode;
  className?: string;
}

/**
 * 2 カラムの入れ物。表示幅が 1,024 px 以上で 2 カラム、未満で 1 カラムになる（切り替えは CSS。要件 17.4）。
 * main 要素は、共通レイアウト（app/layout.tsx）に 1 つだけ置くため、ここでは包まない。
 */
export function TwoColumnLayout({ main, aside, className }: TwoColumnLayoutProps) {
  return (
    <div className={classNames(styles.layout, className)}>
      <div className={styles.main}>{main}</div>
      <aside className={styles.aside}>{aside}</aside>
    </div>
  );
}
