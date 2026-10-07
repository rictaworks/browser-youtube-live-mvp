import { render, screen, waitFor } from "@testing-library/react";
import { RecaptchaProvider } from "@/lib/recaptcha";
import { t } from "@/messages";
import AccountPage, { metadata } from "./page";

// アカウント（/account）。ログインが要る画面。API は fetch の疑似（未ログイン: ランディングへ誘導する）、ルーターは疑似。
// 画面の中身（状態・操作・ダイアログ）は components/account/ のテスト。ここは、ページの構成と、URL の connect の検証。

const mockReplace = jest.fn();
jest.mock("next/navigation", () => ({ useRouter: () => ({ replace: mockReplace }) }));

type SearchParams = Record<string, string | string[] | undefined>;

async function renderAccountPage(searchParams: SearchParams = {}) {
  const page = await AccountPage({ searchParams: Promise.resolve(searchParams) });
  return render(<RecaptchaProvider siteKey={null}>{page}</RecaptchaProvider>);
}

const originalFetch = globalThis.fetch;

function stubFetch(state: Record<string, unknown>): void {
  Object.defineProperty(globalThis, "fetch", {
    configurable: true,
    writable: true,
    value: jest.fn(async () => ({
      status: 200,
      headers: { get: () => "application/json; charset=utf-8" },
      text: async () => JSON.stringify(state),
    })),
  });
}

const authenticated = {
  authenticated: true,
  csrf_token: "dummy-csrf-token-0123456789abcdef",
  usage: {
    usage_date: "2026-10-07",
    allowance_total: 1,
    allowance_remaining: 1,
    attempts_remaining: 3,
    next_available_at: null,
    monthly_intake_closed: false,
    intake_paused: false,
  },
  youtube: { state: "not_connected", channel_title: null, can_recheck_at: null },
  broadcast: null,
};

beforeEach(() => {
  mockReplace.mockClear();
  window.history.replaceState(null, "", "/account");
  stubFetch(authenticated);
});

afterEach(() => {
  Object.defineProperty(globalThis, "fetch", { configurable: true, writable: true, value: originalFetch });
});

describe("アカウントの画面（/account）", () => {
  it("h1（Account と副題）と、YouTube のカード・Danger Zone のカード・ログアウトを表示する。main は含めない", async () => {
    await renderAccountPage();

    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(t("provisional.account.heading"));
    expect(await screen.findByRole("heading", { level: 2, name: t("provisional.account.youtube.eyebrow") })).toBeInTheDocument();
    expect(screen.getByRole("heading", { level: 2, name: t("provisional.account.danger.eyebrow") })).toBeInTheDocument();
    expect(screen.queryByRole("main")).toBeNull();
  });

  it("未ログインなら、ランディング（/）へ誘導する", async () => {
    stubFetch({ authenticated: false, csrf_token: null });

    await renderAccountPage();

    await waitFor(() => expect(mockReplace).toHaveBeenCalledWith("/"));
  });

  it("title は Account（製品名つき）。ログインが要る画面のため、検索エンジンへ載せない（noindex）", () => {
    expect(metadata.title).toBe(t("provisional.account.heading"));
    expect(metadata.robots).toEqual({ index: false, follow: false });
    expect(metadata.description).toBe(t("provisional.account.subheading"));
  });
});

describe("アカウントの画面（/account）: URL の connect（YouTube 接続の結果）", () => {
  it.each([
    ["scope_denied", t("provisional.account.connectResult.scopeDenied.title")],
    ["no_refresh_token", t("provisional.account.connectResult.noRefreshToken.title")],
    ["no_channel", t("provisional.account.connectResult.noChannel.title")],
    ["unverifiable", t("provisional.account.connectResult.unverifiable.title")],
  ])("%s: 通知を出す", async (result, title) => {
    window.history.replaceState(null, "", `/account?connect=${result}`);

    await renderAccountPage({ connect: result });

    expect(await screen.findByText(title)).toBeInTheDocument();
    expect(window.location.search).toBe("");
  });

  it.each([["connected"], ["live_not_enabled"]])("成功 %s: 通知を出さない。クエリは取り除く", async (result) => {
    window.history.replaceState(null, "", `/account?connect=${result}`);

    await renderAccountPage({ connect: result });

    await screen.findByRole("heading", { level: 2, name: t("provisional.account.youtube.eyebrow") });
    expect(screen.queryByRole("alert")).toBeNull();
    expect(window.location.search).toBe("");
  });

  it.each([
    ["未知の値", { connect: "something_else" }],
    ["空", { connect: "" }],
    ["同じキーが複数（配列）", { connect: ["scope_denied", "no_channel"] }],
    ["別のキー", { login_error: "oauth_failed" }],
  ])("%s は、無視する（別の通知へ倒さない）", async (_title, searchParams) => {
    await renderAccountPage(searchParams as SearchParams);

    await screen.findByRole("heading", { level: 2, name: t("provisional.account.youtube.eyebrow") });
    expect(screen.queryByRole("alert")).toBeNull();
  });
});
