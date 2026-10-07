import Link from "next/link";
import { ROUTES } from "@/lib/routes";
import { t } from "@/messages";
import styles from "./SiteFooter.module.css";

/**
 * 全画面のフッター。利用規約とプライバシーポリシーへのリンクを置く
 * （要件 16.1: すべての画面から、常に到達できる位置に置く）。
 */
export function SiteFooter() {
  return (
    <footer className={styles.footer}>
      <Link href={ROUTES.terms}>{t("provisional.legal.terms")}</Link>
      <Link href={ROUTES.privacy}>{t("provisional.legal.privacy")}</Link>
    </footer>
  );
}
