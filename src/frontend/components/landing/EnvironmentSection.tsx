import { KeyValueList, KeyValueRow } from "@/components/ui";
import { LIMITS } from "@/core/contract";
import { t } from "@/messages";
import { LANDING_SECTION_IDS } from "./config";
import styles from "./EnvironmentSection.module.css";
import { formatInteger } from "./format";
import { LandingIcon } from "./LandingIcon";
import { LandingSection } from "./LandingSection";
import { LimitsBox } from "./LimitsBox";

/**
 * 対応環境（Supported）と、利用前の確認（Before You Start）。上り回線の数値は、契約の定数から表示する。
 * 出どころ: app-ui/Landing.dc.html の 03 ENVIRONMENT。
 */
export function EnvironmentSection() {
  const requirements: readonly string[] = [
    t("provisional.landing.environment.before.youtube"),
    t("provisional.landing.environment.before.age"),
    t("provisional.landing.environment.before.line", { kbps: formatInteger(LIMITS.profiles["480p"].line_threshold_kbps) }),
  ];
  return (
    <LandingSection
      id={LANDING_SECTION_IDS.environment}
      alt
      label={{ number: t("provisional.landing.environment.number"), text: t("provisional.landing.environment.label") }}
      heading={t("provisional.landing.environment.heading")}
    >
      <div className={styles.two}>
        <LimitsBox title={t("provisional.landing.environment.supported.eyebrow")}>
          <KeyValueList>
            <KeyValueRow
              label={t("provisional.landing.environment.supported.guaranteed.label")}
              value={t("provisional.landing.environment.supported.guaranteed.value")}
            />
            <KeyValueRow
              label={t("provisional.landing.environment.supported.others.label")}
              value={t("provisional.landing.environment.supported.others.value")}
            />
            <KeyValueRow
              label={t("provisional.landing.environment.supported.mobile.label")}
              value={t("provisional.landing.environment.supported.mobile.value")}
            />
          </KeyValueList>
        </LimitsBox>
        <LimitsBox title={t("provisional.landing.environment.before.eyebrow")}>
          <ul className={styles.list}>
            {requirements.map((requirement) => (
              <li key={requirement} className={styles.item}>
                <LandingIcon name="bullet" className={styles.bullet} />
                {requirement}
              </li>
            ))}
          </ul>
        </LimitsBox>
      </div>
    </LandingSection>
  );
}
