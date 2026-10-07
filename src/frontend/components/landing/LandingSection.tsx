import type { ReactNode } from "react";
import { classNames } from "@/lib/class-names";
import styles from "./LandingSection.module.css";

export interface LandingSectionProps {
  /** 区画の識別子。見出しの id は、これに -heading を付けたもの（section の名前になる） */
  id: string;
  /** 見出し（英語の短い見出し。h2） */
  heading: ReactNode;
  /** 区画の番号と名前（例: 01・VALUE）。装飾のため、支援技術へ読ませない。最後の CTA は、持たない */
  label?: { number: string; text: string };
  /** 背景を、上から下へ濃くするグラデーションにする（モックの .alt） */
  alt?: boolean;
  /** 本文の入れ物へ足すクラス */
  innerClassName?: string;
  children: ReactNode;
}

/** ランディングの区画（section。h2 を名前にする）。出どころ: app-ui/Landing.dc.html の .sec・.sl・.st */
export function LandingSection({ id, heading, label, alt = false, innerClassName, children }: LandingSectionProps) {
  const headingId = `${id}-heading`;
  return (
    <section aria-labelledby={headingId} className={classNames(styles.section, alt && styles.alt)}>
      {label !== undefined && (
        <div aria-hidden="true" className={styles.label}>
          <span className={styles.number}>{label.number}</span>
          {label.text}
        </div>
      )}
      <div className={classNames(styles.inner, innerClassName)}>
        <h2 id={headingId} lang="en" className={styles.heading}>
          {heading}
        </h2>
        {children}
      </div>
    </section>
  );
}
