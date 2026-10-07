import styles from "./PageHeading.module.css";

export interface PageHeadingProps {
  /** ページ題。デザインシステムの流儀で、英語の見出し（例: Terms） */
  title: string;
  /** 題の言語（既定は en）。日本語の題を使うときは ja */
  titleLang?: string;
  /** 日本語の副題（例: 利用規約） */
  subtitle?: string;
}

/** ページの h1。1 画面に 1 つだけ置く。 */
export function PageHeading({ title, titleLang = "en", subtitle }: PageHeadingProps) {
  return (
    <h1 className={styles.heading}>
      <span lang={titleLang} className={styles.title}>
        {title}
      </span>
      {subtitle !== undefined && (
        <>
          {" "}
          <span className={styles.subtitle}>{subtitle}</span>
        </>
      )}
    </h1>
  );
}
