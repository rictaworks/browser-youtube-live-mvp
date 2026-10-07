import { t } from "@/messages";
import { LANDING_SECTION_IDS } from "./config";
import { LandingIcon } from "./LandingIcon";
import type { LandingIconName } from "./icons";
import { LandingSection } from "./LandingSection";
import styles from "./ValueSection.module.css";

interface ValueCard {
  readonly icon: LandingIconName;
  readonly title: string;
  readonly body: string;
}

/** 価値の 4 点（No Install・No Stream Key・One Screen・Auto Close）。出どころ: app-ui/Landing.dc.html の 01 VALUE */
export function ValueSection() {
  const cards: readonly ValueCard[] = [
    {
      icon: "noInstall",
      title: t("provisional.landing.value.noInstall.title"),
      body: t("provisional.landing.value.noInstall.body"),
    },
    {
      icon: "noStreamKey",
      title: t("provisional.landing.value.noStreamKey.title"),
      body: t("provisional.landing.value.noStreamKey.body"),
    },
    {
      icon: "oneScreen",
      title: t("provisional.landing.value.oneScreen.title"),
      body: t("provisional.landing.value.oneScreen.body"),
    },
    {
      icon: "autoClose",
      title: t("provisional.landing.value.autoClose.title"),
      body: t("provisional.landing.value.autoClose.body"),
    },
  ];
  return (
    <LandingSection
      id={LANDING_SECTION_IDS.value}
      alt
      label={{ number: t("provisional.landing.value.number"), text: t("provisional.landing.value.label") }}
      heading={t("provisional.landing.value.heading")}
    >
      <ul className={styles.grid}>
        {cards.map((card) => (
          <li key={card.icon} className={styles.card}>
            <LandingIcon name={card.icon} className={styles.icon} />
            <h3 className={styles.title} lang="en">
              {card.title}
            </h3>
            <p className={styles.body}>{card.body}</p>
          </li>
        ))}
      </ul>
    </LandingSection>
  );
}
