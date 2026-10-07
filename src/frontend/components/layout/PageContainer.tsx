import type { ReactNode } from "react";
import { classNames } from "@/lib/class-names";
import styles from "./PageContainer.module.css";

export interface PageContainerProps {
  children: ReactNode;
  className?: string;
}

/**
 * 1 カラムの本文の入れ物（利用規約・プライバシーポリシー・アカウント・404 など）。
 * main 要素は、共通レイアウト（app/layout.tsx）に 1 つだけ置くため、ここでは包まない。
 */
export function PageContainer({ children, className }: PageContainerProps) {
  return <div className={classNames(styles.page, className)}>{children}</div>;
}
