import { render, screen, waitFor } from "@testing-library/react";
import { RecaptchaProvider } from "@/lib/recaptcha";
import { t } from "@/messages";
import HomePage from "./page";

// ランディング（/）。バックエンドの API は、fetch の疑似（未ログイン）。構成（見出しの階層・区画・ログインのボタン）と、
// URL の login_error から通知を出すことを検査する。区画ごとの中身は components/landing/ のテスト。

type SearchParams = Record<string, string | string[] | undefined>;

async function renderHome(searchParams: SearchParams = {}) {
  const page = await HomePage({ searchParams: Promise.resolve(searchParams) });
  return render(<RecaptchaProvider siteKey={null}>{page}</RecaptchaProvider>);
}

const originalFetch = globalThis.fetch;

beforeEach(() => {
  Object.defineProperty(globalThis, "fetch", {
    configurable: true,
    writable: true,
    value: jest.fn(async () => ({
      status: 200,
      headers: { get: () => "application/json; charset=utf-8" },
      text: async () => JSON.stringify({ authenticated: false, csrf_token: null }),
    })),
  });
});

afterEach(() => {
  Object.defineProperty(globalThis, "fetch", { configurable: true, writable: true, value: originalFetch });
});

describe("ランディング（/）: 構成", () => {
  it("h1 は 1 つ。h2 は、価値・制限・対応環境・最後の CTA の 4 つを、この順に持つ。見出しの階層を飛ばさない", async () => {
    await renderHome();

    expect(screen.getAllByRole("heading", { level: 1 })).toHaveLength(1);
    expect(screen.getAllByRole("heading", { level: 2 }).map((heading) => heading.textContent)).toEqual([
      t("provisional.landing.value.heading"),
      t("provisional.landing.limits.heading"),
      t("provisional.landing.environment.heading"),
      `${t("provisional.landing.final.heading.lead")} ${t("provisional.landing.final.heading.accent")}`,
    ]);
    expect(screen.queryAllByRole("heading", { level: 4 })).toHaveLength(0);
    await waitFor(() => expect(screen.getAllByRole("button", { name: t("provisional.landing.hero.login") })).toHaveLength(2));
  });

  it("ログインのボタンは、ヒーローと最後の 2 か所。開発者向けの近道（疑似ログインなど）を出さない", async () => {
    await renderHome();

    expect(screen.getAllByRole("button")).toHaveLength(2);
    expect(screen.queryByRole("button", { name: /dev|mock|疑似/i })).toBeNull();
    await waitFor(() => expect(screen.getAllByRole("button", { name: t("provisional.landing.hero.login") })).toHaveLength(2));
  });

  it("main は含めない（共通レイアウトの main に 1 つだけ置く）", async () => {
    await renderHome();

    expect(screen.queryByRole("main")).toBeNull();
    await waitFor(() => expect(screen.getAllByRole("button")).toHaveLength(2));
  });

  it("画像（hero.webp など）を使わない（出どころと利用許諾が未確認）", async () => {
    const { container } = await renderHome();

    expect(container.querySelectorAll("img")).toHaveLength(0);
    expect(container.innerHTML).not.toContain("hero.webp");
    await waitFor(() => expect(screen.getAllByRole("button")).toHaveLength(2));
  });
});

describe("ランディング（/）: login_error（ログインの拒否・失敗）", () => {
  it("login_error が無ければ、通知を出さない", async () => {
    await renderHome();

    expect(screen.queryByRole("alert")).toBeNull();
    expect(screen.queryByRole("status")).toBeNull();
    await waitFor(() => expect(screen.getAllByRole("button")).toHaveLength(2));
  });

  it("registration_held: 再登録の保留の通知（情報）を出す", async () => {
    await renderHome({ login_error: "registration_held" });

    expect(screen.getByRole("status")).toHaveTextContent(t("provisional.landing.notice.registrationHeld.title"));
    await waitFor(() => expect(screen.getAllByRole("button")).toHaveLength(2));
  });

  it("oauth_failed: ログインの失敗の通知（エラー）を出す", async () => {
    await renderHome({ login_error: "oauth_failed" });

    expect(screen.getByRole("alert")).toHaveTextContent(t("provisional.landing.notice.oauthFailed.title"));
    await waitFor(() => expect(screen.getAllByRole("button")).toHaveLength(2));
  });

  it.each([
    ["未知の値", { login_error: "something_else" }],
    ["空", { login_error: "" }],
    ["同じキーが複数（配列）", { login_error: ["registration_held", "oauth_failed"] }],
    ["別のキー", { connect: "scope_denied" }],
  ])("%s は、無視する（通知を出さない。別の通知へ倒さない）", async (_title, searchParams) => {
    await renderHome(searchParams as SearchParams);

    expect(screen.queryByRole("alert")).toBeNull();
    expect(screen.queryByRole("status")).toBeNull();
    await waitFor(() => expect(screen.getAllByRole("button")).toHaveLength(2));
  });
});
