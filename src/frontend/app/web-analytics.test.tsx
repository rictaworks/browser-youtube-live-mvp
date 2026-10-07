import { render } from "@testing-library/react";
import { sanitizeAnalyticsEvent, WebAnalytics } from "./web-analytics";

// ページの閲覧の測定（Vercel Web Analytics）。測定へ、タイトル・IP・URL のクエリ（認可の結果・失敗の符号など）を含めない。
// 本物の Analytics は、スクリプトを読み込むため、疑似にして、渡す引数を検査する。

const analyticsProps: Array<Record<string, unknown>> = [];

jest.mock("@vercel/analytics/next", () => ({
  Analytics: (props: Record<string, unknown>) => {
    analyticsProps.push(props);
    return null;
  },
}));

describe("sanitizeAnalyticsEvent: 測定する URL", () => {
  it.each([
    ["クエリ", "https://app.example.test/account?connect=scope_denied", "https://app.example.test/account"],
    ["クエリとフラグメント", "https://app.example.test/?login_error=oauth_failed#top", "https://app.example.test/"],
    ["フラグメントだけ", "https://app.example.test/terms#service", "https://app.example.test/terms"],
    ["クエリが無い URL（そのまま）", "https://app.example.test/privacy", "https://app.example.test/privacy"],
  ])("%s を取り除く", (_title, url, expected) => {
    expect(sanitizeAnalyticsEvent({ type: "pageview", url })).toEqual({ type: "pageview", url: expected });
    expect(sanitizeAnalyticsEvent({ type: "event", url })).toEqual({ type: "event", url: expected });
  });

  it("URL として解釈できない値は、測定しない（null。解釈できない値を、そのまま送らない）", () => {
    expect(sanitizeAnalyticsEvent({ type: "pageview", url: "not a url" })).toBeNull();
  });
});

describe("WebAnalytics", () => {
  beforeEach(() => {
    analyticsProps.length = 0;
  });

  it("本番のモード（production）で、URL を整える関数を渡して、Analytics を描画する", () => {
    render(<WebAnalytics />);

    expect(analyticsProps).toHaveLength(1);
    expect(analyticsProps[0].mode).toBe("production");
    expect(analyticsProps[0].beforeSend).toBe(sanitizeAnalyticsEvent);
  });
});
