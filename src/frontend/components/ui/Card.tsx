import type { ReactNode } from "react";
import { classNames } from "@/lib/class-names";
import styles from "./Card.module.css";

export interface CardProps {
  /** カードの見出し（アイブロウ）。デザインシステムの流儀で、英語の短い見出し（例: Service） */
  eyebrow: string;
  /** アイブロウの言語（既定は en）。日本語の見出しを使うときは ja */
  eyebrowLang?: string;
  children: ReactNode;
  className?: string;
}

/**
 * 見出し（h2）のアイブロウ付きのカード。
 * section 要素だが、名前（aria-label）は付けない（名前を付けるとランドマークになり、カードの数だけ増えてしまうため）。
 */
export function Card({ eyebrow, eyebrowLang = "en", children, className }: CardProps) {
  return (
    <section className={classNames(styles.card, className)}>
      <h2 lang={eyebrowLang} className={styles.eyebrow}>
        {eyebrow}
      </h2>
      {children}
    </section>
  );
}
