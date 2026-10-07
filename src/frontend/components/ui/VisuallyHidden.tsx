import type { ReactNode } from "react";
import styles from "./VisuallyHidden.module.css";

/** 画面には出さず、支援技術へ読ませる文字（状態を文言でも伝える・リンクの補足など）。 */
export function VisuallyHidden({ children }: { children: ReactNode }) {
  return <span className={styles.visuallyHidden}>{children}</span>;
}
