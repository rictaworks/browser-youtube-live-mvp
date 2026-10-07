import Link from "next/link";
import { ROUTES } from "@/lib/routes";
import { splitWordmark } from "@/lib/wordmark";
import { t } from "@/messages";
import { NavLink } from "./NavLink";
import styles from "./SiteHeader.module.css";

/**
 * 全画面のヘッダー。ワードマーク（製品名は config/brand.ts。最後の語を強調する）と、ナビ。
 * 画面ごとのナビ（スタジオ・アカウントなど）は、後続の画面の issue が、ここへ足す。
 */
export function SiteHeader() {
  const { lead, accent } = splitWordmark(t("brand.name"));
  return (
    <header className={styles.header}>
      <Link href={ROUTES.home} className={styles.wordmark}>
        {lead}
        {accent !== "" && (
          <>
            {" "}
            <span className={styles.accent}>{accent}</span>
          </>
        )}
      </Link>
      <nav className={styles.nav}>
        <NavLink href={ROUTES.terms} className={styles.navLink}>
          {t("provisional.legal.terms")}
        </NavLink>
        <NavLink href={ROUTES.privacy} className={styles.navLink}>
          {t("provisional.legal.privacy")}
        </NavLink>
      </nav>
    </header>
  );
}
