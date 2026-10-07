import type { ReactNode } from "react";
import { classNames } from "@/lib/class-names";
import styles from "./VisuallyHidden.module.css";

export interface LiveRegionProps {
  children?: ReactNode;
  /** polite: 控えめ（既定。role=status）。assertive: すぐに読み上げる（role=alert。エラー・停止など） */
  politeness?: "polite" | "assertive";
  /** 画面には出さず、支援技術へだけ伝える */
  visuallyHidden?: boolean;
  className?: string;
}

/**
 * 支援技術へ状態の変化を伝える領域（aria-live）。要件 17.6「状態の変化は、支援技術へ通知される領域で伝える」。
 * 領域は、中身が空でも常に DOM へ置く（領域が先にあり、あとから中身が変わる形でないと、読み上げられない）。
 */
export function LiveRegion({ children, politeness = "polite", visuallyHidden = false, className }: LiveRegionProps) {
  return (
    <div
      role={politeness === "assertive" ? "alert" : "status"}
      aria-live={politeness}
      aria-atomic="true"
      className={classNames(visuallyHidden && styles.visuallyHidden, className)}
    >
      {children}
    </div>
  );
}
