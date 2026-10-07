import type { ReactNode } from "react";
import { classNames } from "@/lib/class-names";
import styles from "./Note.module.css";

export interface NoteProps {
  /** body: 本文の大きさ（既定）。fine: 補足の大きさ */
  size?: "body" | "fine";
  children: ReactNode;
  className?: string;
}

/** カードなどの中の段落（説明・補足）。 */
export function Note({ size = "body", children, className }: NoteProps) {
  return <p className={classNames(styles.note, size === "fine" && styles.fine, className)}>{children}</p>;
}
