import type { ReactNode } from "react";
import { classNames } from "@/lib/class-names";
import styles from "./LimitsBox.module.css";

export interface LimitsBoxProps {
  /** 箱の見出し（英語の短い見出し。h3） */
  title: string;
  className?: string;
  children: ReactNode;
}

/** 見出し（h3）つきの囲み（Other Limits・Supported・Before You Start）。出どころ: app-ui/Landing.dc.html の .box */
export function LimitsBox({ title, className, children }: LimitsBoxProps) {
  return (
    <div className={classNames(styles.box, className)}>
      <h3 lang="en" className={styles.title}>
        {title}
      </h3>
      {children}
    </div>
  );
}
