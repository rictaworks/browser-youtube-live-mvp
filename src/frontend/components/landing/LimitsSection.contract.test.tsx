import { render } from "@testing-library/react";
import { t } from "@/messages";
import { EnvironmentSection } from "./EnvironmentSection";
import { LimitsSection } from "./LimitsSection";

// 制限の数値を、画面のコードへ直書きしていないことの検査: 契約の定数（core/contract）を差し替えると、表示が、そのとおりに替わる。

jest.mock("@/core/contract", () => {
  const actual = jest.requireActual("@/core/contract") as typeof import("@/core/contract");
  return {
    ...actual,
    LIMITS: {
      ...actual.LIMITS,
      setting_defaults: { ...actual.LIMITS.setting_defaults, daily_allowance: 2, time_limit_minutes: 90, concurrent_limit: 5 },
      profiles: {
        ...actual.LIMITS.profiles,
        "480p": { ...actual.LIMITS.profiles["480p"], line_threshold_kbps: 2345 },
      },
      deadlines: { ...actual.LIMITS.deadlines, interrupted_relay_notified_seconds: 45, max_resumes: 7 },
    },
  };
});

describe("制限の数値は、契約の定数から表示する（直書きしない）", () => {
  it("1 日の回数・1 配信の長さ・同時配信数・必要な上り回線・中断の許容が、定数の値になる", () => {
    const { container } = render(<LimitsSection />);

    const text = container.textContent ?? "";
    expect(text).toContain(`2${t("provisional.landing.limits.stats.count.unit")}`);
    expect(text).toContain(`90${t("provisional.landing.limits.stats.length.unit")}`);
    expect(text).toContain(`5${t("provisional.landing.limits.stats.concurrent.unit")}`);
    expect(text).toContain(`2,345${t("provisional.landing.limits.stats.line.unit")}`);
    expect(text).toContain(t("provisional.landing.limits.other.resume.value", { seconds: 45, resumes: 7 }));
    expect(text).not.toContain("1,200");
  });

  it("利用前の確認の、回線の数値も、定数の値になる", () => {
    const { container } = render(<EnvironmentSection />);

    expect(container.textContent).toContain(t("provisional.landing.environment.before.line", { kbps: "2,345" }));
  });
});
