import { render, screen, within } from "@testing-library/react";
import { LIMITS } from "@/core/contract";
import { t } from "@/messages";
import { EnvironmentSection } from "./EnvironmentSection";
import { FinalSection } from "./FinalSection";
import { HeroSection } from "./HeroSection";
import { LimitsSection } from "./LimitsSection";
import { ValueSection } from "./ValueSection";

// ランディングの静的な区画（ヒーロー・価値の 4 点・制限の数値・対応環境・最後の CTA）。ログインのボタン・通知は、状態を持つため、疑似にして、置き場所だけを検査する。
jest.mock("./LoginButton", () => ({ LoginButton: ({ placement }: { placement: string }) => <button type="button" data-testid={`cta-${placement}`}>cta</button> }));
jest.mock("./LoginNotice", () => ({ LoginNotice: ({ placement }: { placement: string }) => <div data-testid={`notice-${placement}`} /> }));

describe("HeroSection", () => {
  it("h1（英語の見出し。前半と、強調する後半）・要約・ログインのボタンと通知の置き場所・補足を、この順に持つ", () => {
    const { container } = render(<HeroSection />);

    const heading = screen.getByRole("heading", { level: 1 });
    expect(heading).toHaveAttribute("lang", "en");
    expect(heading.textContent).toBe(`${t("provisional.landing.hero.headline.lead")} ${t("provisional.landing.hero.headline.accent")}`);
    expect(within(heading).getByText(t("provisional.landing.hero.headline.accent")).tagName).toBe("EM");

    const order = ["h1", "p", '[data-testid="cta-hero"]', '[data-testid="notice-hero"]', "p:last-of-type"].map((selector) => container.querySelector(selector));
    expect(order.every((element) => element !== null)).toBe(true);
    expect(container.textContent).toContain(t("provisional.landing.hero.summary"));
    expect(container.textContent).toContain(t("provisional.landing.hero.fine"));
    expect(container.querySelectorAll("h1")).toHaveLength(1);
  });

  it("section として、h1 を名前にする（ランドマークの名前）", () => {
    render(<HeroSection />);

    const heading = screen.getByRole("heading", { level: 1 });
    expect(screen.getByRole("region", { name: heading.textContent ?? "" })).toBeInTheDocument();
  });
});

describe("ValueSection（価値の 4 点）", () => {
  it("見出し（h2）と、4 点のカード（h3 と説明）を、モックの順に表示する。数字とラベルは、装飾として読ませない", () => {
    const { container } = render(<ValueSection />);

    expect(screen.getByRole("heading", { level: 2 })).toHaveTextContent(t("provisional.landing.value.heading"));
    expect(screen.getAllByRole("heading", { level: 3 }).map((heading) => heading.textContent)).toEqual([
      t("provisional.landing.value.noInstall.title"),
      t("provisional.landing.value.noStreamKey.title"),
      t("provisional.landing.value.oneScreen.title"),
      t("provisional.landing.value.autoClose.title"),
    ]);
    for (const key of [
      "provisional.landing.value.noInstall.body",
      "provisional.landing.value.noStreamKey.body",
      "provisional.landing.value.oneScreen.body",
      "provisional.landing.value.autoClose.body",
    ] as const) {
      expect(screen.getByText(t(key))).toBeInTheDocument();
    }
    expect(screen.getAllByRole("listitem")).toHaveLength(4);
    const label = screen.getByText(t("provisional.landing.value.label")).closest("[aria-hidden]");
    expect(label).toHaveAttribute("aria-hidden", "true");
    expect(container.querySelectorAll("svg[aria-hidden='true']").length).toBeGreaterThanOrEqual(4);
  });
});

describe("LimitsSection（制限の数値は、契約の定数から表示する）", () => {
  it("4 つの数値（1 日の回数・1 配信の長さ・同時配信数・必要な上り回線）を、単位と説明つきで表示する", () => {
    const { container } = render(<LimitsSection />);

    // 最初の定義リストが、4 つの数値（2 つ目は、その他の制限の行）
    const stats = Array.from(container.querySelector("dl")?.children ?? []);
    expect(stats).toHaveLength(4);
    const texts = stats.map((stat) => stat.textContent ?? "");
    expect(texts[0]).toContain(`${LIMITS.setting_defaults.daily_allowance}${t("provisional.landing.limits.stats.count.unit")}`);
    expect(texts[0]).toContain(t("provisional.landing.limits.stats.count.caption"));
    expect(texts[0]).toContain(t("provisional.landing.limits.stats.count.captionNote"));
    expect(texts[1]).toContain(`${LIMITS.setting_defaults.time_limit_minutes}${t("provisional.landing.limits.stats.length.unit")}`);
    expect(texts[2]).toContain(`${LIMITS.setting_defaults.concurrent_limit}${t("provisional.landing.limits.stats.concurrent.unit")}`);
    expect(texts[3]).toContain(`1,200${t("provisional.landing.limits.stats.line.unit")}`);
    expect(texts[3]).toContain(t("provisional.landing.limits.stats.line.captionNote"));
  });

  it("現在の契約の数値（1 回 / 日・60 分・3 本・1,200 kbps）と一致する（契約が変わったら、気づける）", () => {
    render(<LimitsSection />);

    const text = document.body.textContent ?? "";
    expect(LIMITS.setting_defaults.daily_allowance).toBe(1);
    expect(LIMITS.setting_defaults.time_limit_minutes).toBe(60);
    expect(LIMITS.setting_defaults.concurrent_limit).toBe(3);
    expect(LIMITS.profiles["480p"].line_threshold_kbps).toBe(1200);
    expect(text).toContain("1,200");
  });

  it("その他の制限（Other Limits）の 5 行を、項目名と値で表示する。中断の許容の数値は、契約から差し込む", () => {
    render(<LimitsSection />);

    const box = screen.getByRole("heading", { level: 3, name: t("provisional.landing.limits.other.eyebrow") }).parentElement as HTMLElement;
    expect(within(box).getAllByRole("term").map((term) => term.textContent)).toEqual([
      t("provisional.landing.limits.other.daily.label"),
      t("provisional.landing.limits.other.monthly.label"),
      t("provisional.landing.limits.other.quality.label"),
      t("provisional.landing.limits.other.resume.label"),
      t("provisional.landing.limits.other.deletion.label"),
    ]);
    expect(within(box).getByText(t("provisional.landing.limits.other.resume.value", {
      seconds: LIMITS.deadlines.interrupted_relay_notified_seconds,
      resumes: LIMITS.deadlines.max_resumes,
    }))).toBeInTheDocument();
    expect(box.textContent).toContain(t("provisional.landing.limits.other.daily.value"));
    expect(box.textContent).toContain(t("provisional.landing.limits.other.deletion.value"));
  });

  it("見出し（h2）と、導入の文を持つ", () => {
    render(<LimitsSection />);

    expect(screen.getByRole("heading", { level: 2 })).toHaveTextContent(t("provisional.landing.limits.heading"));
    expect(screen.getByText(t("provisional.landing.limits.lead"))).toBeInTheDocument();
  });
});

describe("EnvironmentSection（対応環境・利用前の確認）", () => {
  it("対応環境（Supported）の 3 行と、利用前の確認（Before You Start）の 3 項目を表示する。回線の数値は、契約から差し込む", () => {
    render(<EnvironmentSection />);

    expect(screen.getByRole("heading", { level: 2 })).toHaveTextContent(t("provisional.landing.environment.heading"));
    const supported = screen.getByRole("heading", { level: 3, name: t("provisional.landing.environment.supported.eyebrow") }).parentElement as HTMLElement;
    expect(within(supported).getAllByRole("term").map((term) => term.textContent)).toEqual([
      t("provisional.landing.environment.supported.guaranteed.label"),
      t("provisional.landing.environment.supported.others.label"),
      t("provisional.landing.environment.supported.mobile.label"),
    ]);
    const before = screen.getByRole("heading", { level: 3, name: t("provisional.landing.environment.before.eyebrow") }).parentElement as HTMLElement;
    expect(within(before).getAllByRole("listitem").map((item) => item.textContent)).toEqual([
      t("provisional.landing.environment.before.youtube"),
      t("provisional.landing.environment.before.age"),
      t("provisional.landing.environment.before.line", { kbps: "1,200" }),
    ]);
  });
});

describe("FinalSection（最後の CTA）", () => {
  it("見出し（h2。前半と強調する後半）と、最後のログインのボタン・通知の置き場所を持つ", () => {
    render(<FinalSection />);

    const heading = screen.getByRole("heading", { level: 2 });
    expect(heading.textContent).toBe(`${t("provisional.landing.final.heading.lead")} ${t("provisional.landing.final.heading.accent")}`);
    expect(heading).toHaveAttribute("lang", "en");
    expect(screen.getByTestId("cta-final")).toBeInTheDocument();
    expect(screen.getByTestId("notice-final")).toBeInTheDocument();
  });
});
