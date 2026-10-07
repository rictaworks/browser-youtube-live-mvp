import { t } from "@/messages";
import styles from "./SkipLink.module.css";

/** 本文（main 要素）の id。スキップリンクの宛先で、共通レイアウトの main がこの id を持つ。 */
export const MAIN_CONTENT_ID = "main-content";

/** 本文へ移動するスキップリンク。ページの先頭に置き、キーボードの利用者が、ヘッダーのリンクを飛ばせるようにする。 */
export function SkipLink() {
  return (
    <a href={`#${MAIN_CONTENT_ID}`} className={styles.skipLink}>
      {t("provisional.layout.skipLink")}
    </a>
  );
}
