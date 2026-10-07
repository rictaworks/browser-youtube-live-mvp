import { t } from "@/messages";
import { LANDING_SECTION_IDS } from "./config";
import styles from "./FinalSection.module.css";
import { LandingSection } from "./LandingSection";
import { LoginButton } from "./LoginButton";
import { LoginNotice } from "./LoginNotice";

/** 最後の CTA（Ready When You Are. と、2 つ目のログインのボタン）。出どころ: app-ui/Landing.dc.html の最後の区画 */
export function FinalSection() {
  return (
    <LandingSection
      id={LANDING_SECTION_IDS.final}
      innerClassName={styles.final}
      heading={
        <>
          {t("provisional.landing.final.heading.lead")} <span className={styles.accent}>{t("provisional.landing.final.heading.accent")}</span>
        </>
      }
    >
      <LoginButton placement="final" />
      <LoginNotice placement="final" />
    </LandingSection>
  );
}
