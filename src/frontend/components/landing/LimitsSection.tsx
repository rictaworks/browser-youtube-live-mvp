import { KeyValueList, KeyValueRow } from "@/components/ui";
import { LIMITS } from "@/core/contract";
import { t } from "@/messages";
import { LANDING_SECTION_IDS } from "./config";
import { formatInteger } from "./format";
import { LandingSection } from "./LandingSection";
import { LimitsBox } from "./LimitsBox";
import styles from "./LimitsSection.module.css";

interface Stat {
  readonly key: string;
  /** 数値。契約の定数（core/contract）の値 */
  readonly value: number;
  readonly unit: string;
  readonly caption: string;
  readonly note?: string;
}

/**
 * 制限（Fair Use）: 4 つの数値と、その他の制限。数値は、契約の定数から表示する（直書きしない。契約が変われば、画面も変わる）。
 * 出どころ: app-ui/Landing.dc.html の 02 LIMITS。
 */
export function LimitsSection() {
  const stats: readonly Stat[] = [
    {
      key: "count",
      value: LIMITS.setting_defaults.daily_allowance,
      unit: t("provisional.landing.limits.stats.count.unit"),
      caption: t("provisional.landing.limits.stats.count.caption"),
      note: t("provisional.landing.limits.stats.count.captionNote"),
    },
    {
      key: "length",
      value: LIMITS.setting_defaults.time_limit_minutes,
      unit: t("provisional.landing.limits.stats.length.unit"),
      caption: t("provisional.landing.limits.stats.length.caption"),
    },
    {
      key: "concurrent",
      value: LIMITS.setting_defaults.concurrent_limit,
      unit: t("provisional.landing.limits.stats.concurrent.unit"),
      caption: t("provisional.landing.limits.stats.concurrent.caption"),
    },
    {
      key: "line",
      // 必要な上り回線: 軽量プロファイル（480p）の回線の閾値（要件 30.3: 1,200 kbps）
      value: LIMITS.profiles["480p"].line_threshold_kbps,
      unit: t("provisional.landing.limits.stats.line.unit"),
      caption: t("provisional.landing.limits.stats.line.caption"),
      note: t("provisional.landing.limits.stats.line.captionNote"),
    },
  ];
  return (
    <LandingSection
      id={LANDING_SECTION_IDS.limits}
      label={{ number: t("provisional.landing.limits.number"), text: t("provisional.landing.limits.label") }}
      heading={t("provisional.landing.limits.heading")}
    >
      <p className={styles.lead}>{t("provisional.landing.limits.lead")}</p>
      <dl className={styles.stats}>
        {stats.map((stat) => (
          <div key={stat.key} className={styles.stat}>
            <dt className={styles.caption}>
              {stat.caption}
              {stat.note !== undefined && <span className={styles.captionNote}>{stat.note}</span>}
            </dt>
            <dd className={styles.figure}>
              {formatInteger(stat.value)}
              <small className={styles.unit}>{stat.unit}</small>
            </dd>
          </div>
        ))}
      </dl>
      <LimitsBox title={t("provisional.landing.limits.other.eyebrow")} className={styles.other}>
        <KeyValueList>
          <KeyValueRow
            label={t("provisional.landing.limits.other.daily.label")}
            value={t("provisional.landing.limits.other.daily.value")}
          />
          <KeyValueRow
            label={t("provisional.landing.limits.other.monthly.label")}
            value={t("provisional.landing.limits.other.monthly.value")}
          />
          <KeyValueRow
            label={t("provisional.landing.limits.other.quality.label")}
            value={t("provisional.landing.limits.other.quality.value")}
          />
          <KeyValueRow
            label={t("provisional.landing.limits.other.resume.label")}
            value={t("provisional.landing.limits.other.resume.value", {
              seconds: LIMITS.deadlines.interrupted_relay_notified_seconds,
              resumes: LIMITS.deadlines.max_resumes,
            })}
          />
          <KeyValueRow
            label={t("provisional.landing.limits.other.deletion.label")}
            value={t("provisional.landing.limits.other.deletion.value")}
          />
        </KeyValueList>
      </LimitsBox>
    </LandingSection>
  );
}
