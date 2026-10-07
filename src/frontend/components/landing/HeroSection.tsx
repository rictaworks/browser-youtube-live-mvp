import { t } from "@/messages";
import { LANDING_SECTION_IDS } from "./config";
import styles from "./HeroSection.module.css";
import { LoginButton } from "./LoginButton";
import { LoginNotice } from "./LoginNotice";

/**
 * ヒーロー（ページの h1・要約・ログインのボタン・ログインの通知・補足）。出どころ: app-ui/Landing.dc.html の .hero。
 * 画像（hero.webp）は使わない（出どころと利用許諾が未確認。app-ui/README.md）。背景は、トークンのグラデーションだけ。
 */
export function HeroSection() {
  const headingId = `${LANDING_SECTION_IDS.hero}-heading`;
  return (
    <section aria-labelledby={headingId} className={styles.hero}>
      <div className={styles.inner}>
        <h1 id={headingId} lang="en" className={styles.headline}>
          <span className={styles.line}>{t("provisional.landing.hero.headline.lead")}</span>{" "}
          <em className={styles.accent}>{t("provisional.landing.hero.headline.accent")}</em>
        </h1>
        <p className={styles.summary}>{t("provisional.landing.hero.summary")}</p>
        <LoginButton placement="hero" />
        <LoginNotice placement="hero" />
        <p className={styles.fine}>{t("provisional.landing.hero.fine")}</p>
      </div>
    </section>
  );
}
