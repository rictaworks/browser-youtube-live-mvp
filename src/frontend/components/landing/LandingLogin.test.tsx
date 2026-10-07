import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { ApiClient } from "@/lib/api";
import { createFakeFetch, DUMMY_AUTHORIZATION_URL, DUMMY_RECAPTCHA_TOKEN, authenticatedState, jsonResponse, UNAUTHENTICATED_STATE } from "@/lib/api/test-support";
import type { FakeRespond } from "@/lib/api/test-support";
import { RecaptchaConfigurationError, RecaptchaExecuteError, RecaptchaProvider, type RecaptchaTokenSource } from "@/lib/recaptcha";
import { t } from "@/messages";
import { LandingLoginProvider } from "./LandingLogin";
import { LoginButton } from "./LoginButton";
import { LoginNotice } from "./LoginNotice";

// ランディングのログイン（2 か所の「LOG IN WITH GOOGLE」・通知）の動作。API は fetch の疑似、bot 判定は差し替え、遷移は関数の疑似で検査する。

const LOGIN_LABEL = t("provisional.landing.hero.login");
const BUSY_LABEL = t("provisional.landing.hero.loginBusy");
const STUDIO_LABEL = t("provisional.landing.hero.openStudio");

interface Setup {
  navigate: jest.Mock;
  calls: ReturnType<typeof createFakeFetch>["calls"];
  recaptcha: { getToken: jest.Mock };
}

function setup(options: { respond?: FakeRespond; getToken?: () => Promise<string>; loginError?: "registration_held" | "oauth_failed" | null } = {}): Setup {
  const fake = createFakeFetch(
    options.respond ??
      ((url) => (url === "/api/state" ? jsonResponse(200, UNAUTHENTICATED_STATE) : jsonResponse(200, { authorization_url: DUMMY_AUTHORIZATION_URL }))),
  );
  const client = new ApiClient({ fetch: fake.fetch });
  const navigate = jest.fn();
  const recaptcha = { getToken: jest.fn(options.getToken ?? (async () => DUMMY_RECAPTCHA_TOKEN)) };
  render(
    <RecaptchaProvider siteKey={null} client={recaptcha as RecaptchaTokenSource}>
      <LandingLoginProvider initialLoginError={options.loginError ?? null} client={client} navigate={navigate}>
        <div data-testid="hero">
          <LoginButton placement="hero" />
          <LoginNotice placement="hero" />
        </div>
        <div data-testid="final">
          <LoginButton placement="final" />
          <LoginNotice placement="final" />
        </div>
      </LandingLoginProvider>
    </RecaptchaProvider>,
  );
  return { navigate, calls: fake.calls, recaptcha };
}

function loginButtons(): HTMLElement[] {
  return screen.getAllByRole("button", { name: LOGIN_LABEL });
}

describe("ログインのボタン: 初期表示とログイン済みの判定", () => {
  it("未ログインなら、2 か所のボタン（LOG IN WITH GOOGLE）を表示し、マウント時に getState を 1 回だけ呼ぶ", async () => {
    const { calls } = setup();

    expect(loginButtons()).toHaveLength(2);
    await waitFor(() => expect(calls.filter((call) => call.url === "/api/state")).toHaveLength(1));
    expect(loginButtons()).toHaveLength(2);
    expect(screen.queryByRole("link", { name: STUDIO_LABEL })).toBeNull();
  });

  it("ログイン済みなら、2 か所とも、スタジオへのリンク（/studio）に替わる。ログインのボタンを出さない", async () => {
    setup({ respond: () => jsonResponse(200, authenticatedState()) });

    const links = await screen.findAllByRole("link", { name: STUDIO_LABEL });

    expect(links).toHaveLength(2);
    for (const link of links) {
      expect(link).toHaveAttribute("href", "/studio");
    }
    expect(screen.queryByRole("button", { name: LOGIN_LABEL })).toBeNull();
  });

  it("getState が失敗しても、ログインのボタンを残し、通知は出さない（失敗は、コンソールへ記録する）", async () => {
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    setup({ respond: () => Promise.reject(new TypeError("fetch failed")) });

    await waitFor(() => expect(consoleError).toHaveBeenCalled());

    expect(loginButtons()).toHaveLength(2);
    expect(screen.queryByRole("alert")).toBeNull();
    expect(screen.queryByRole("status")).toBeNull();
    consoleError.mockRestore();
  });

  it("画面を離れたら（アンマウント）、取得中の getState を中断する", async () => {
    const fake = createFakeFetch(
      (_url, init) =>
        new Promise((_resolve, reject) => {
          init.signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
        }),
    );
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    const { unmount } = render(
      <RecaptchaProvider siteKey={null} client={{ getToken: async () => "x" }}>
        <LandingLoginProvider initialLoginError={null} client={new ApiClient({ fetch: fake.fetch })} navigate={jest.fn()}>
          <LoginButton placement="hero" />
        </LandingLoginProvider>
      </RecaptchaProvider>,
    );

    await waitFor(() => expect(fake.calls).toHaveLength(1));
    unmount();

    expect(fake.calls[0].init.signal.aborted).toBe(true);
    expect(consoleError).not.toHaveBeenCalled();
    consoleError.mockRestore();
  });

  it("ボタンは、キーボードで到達でき、アクセシブルな名前を持つ", async () => {
    const user = userEvent.setup();
    setup();

    await user.tab();

    expect(loginButtons()[0]).toHaveFocus();
  });
});

describe("ログインのボタン: 操作（bot 判定 → ログインの開始 → 認可 URL へ遷移）", () => {
  it("押すと、行為名 login で bot 判定のトークンを取得し、startLogin へ渡し、返った認可 URL へ遷移する", async () => {
    const user = userEvent.setup();
    const { calls, recaptcha, navigate } = setup();

    await user.click(loginButtons()[0]);

    await waitFor(() => expect(navigate).toHaveBeenCalledTimes(1));
    expect(recaptcha.getToken).toHaveBeenCalledWith("login");
    const start = calls.find((call) => call.url === "/api/auth/login/start");
    expect(start?.init.method).toBe("POST");
    expect(JSON.parse(start?.init.body ?? "")).toEqual({ recaptcha_token: DUMMY_RECAPTCHA_TOKEN });
    expect(navigate).toHaveBeenCalledWith(DUMMY_AUTHORIZATION_URL);
  });

  it("2 つ目のボタンでも、同じ流れで、1 回だけ遷移する", async () => {
    const user = userEvent.setup();
    const { navigate } = setup();

    await user.click(loginButtons()[1]);

    await waitFor(() => expect(navigate).toHaveBeenCalledTimes(1));
  });

  it("処理中は、2 つのボタンとも、文言が進行形になり（aria-busy）、二重に押しても、取得・開始を 1 回しか行わない", async () => {
    const user = userEvent.setup();
    let release: (token: string) => void = () => undefined;
    const { recaptcha, navigate } = setup({ getToken: () => new Promise<string>((resolve) => (release = resolve)) });

    await user.click(loginButtons()[0]);

    const busyButtons = await screen.findAllByRole("button", { name: BUSY_LABEL });
    expect(busyButtons).toHaveLength(2);
    for (const button of busyButtons) {
      expect(button).toHaveAttribute("aria-busy", "true");
    }
    await user.click(busyButtons[0]);
    await user.dblClick(busyButtons[1]);
    expect(recaptcha.getToken).toHaveBeenCalledTimes(1);

    await act(async () => release(DUMMY_RECAPTCHA_TOKEN));
    await waitFor(() => expect(navigate).toHaveBeenCalledTimes(1));
  });

  it("遷移を始めたあとも、ページを離れるまで、処理中のまま（二重の遷移を防ぐ）", async () => {
    const user = userEvent.setup();
    const { navigate } = setup();

    await user.click(loginButtons()[0]);
    await waitFor(() => expect(navigate).toHaveBeenCalledTimes(1));

    expect(screen.getAllByRole("button", { name: BUSY_LABEL })).toHaveLength(2);
  });

  it("キーボード（Enter）でも、同じ操作ができる", async () => {
    const user = userEvent.setup();
    const { navigate } = setup();

    await user.tab();
    await user.keyboard("{Enter}");

    await waitFor(() => expect(navigate).toHaveBeenCalledTimes(1));
  });

  it("戻る操作でページが復元されたとき（bfcache の pageshow）、処理中を解除し、もう一度押せる", async () => {
    const user = userEvent.setup();
    const { navigate } = setup();
    await user.click(loginButtons()[0]);
    await waitFor(() => expect(navigate).toHaveBeenCalledTimes(1));
    expect(screen.getAllByRole("button", { name: BUSY_LABEL })).toHaveLength(2);

    act(() => {
      window.dispatchEvent(Object.assign(new Event("pageshow"), { persisted: true }));
    });

    expect(await screen.findAllByRole("button", { name: LOGIN_LABEL })).toHaveLength(2);
  });

  it("開発の疑似の認可 URL（同じオリジンの /api/dev/）へも、遷移できる（開発・テストの環境）", async () => {
    const user = userEvent.setup();
    const { navigate } = setup({
      respond: (url) =>
        url === "/api/state" ? jsonResponse(200, UNAUTHENTICATED_STATE) : jsonResponse(200, { authorization_url: "/api/dev/google/authorize?state=x" }),
    });

    await user.click(loginButtons()[0]);

    await waitFor(() => expect(navigate).toHaveBeenCalledWith(`${window.location.origin}/api/dev/google/authorize?state=x`));
  });
});

describe("ログインの失敗の通知（断定と対処）", () => {
  const failures: Array<[string, { respond?: FakeRespond; getToken?: () => Promise<string> }, "alert" | "status", string, string | null]> = [
    [
      "403 bot_check_failed",
      { respond: (url) => (url === "/api/state" ? jsonResponse(200, UNAUTHENTICATED_STATE) : jsonResponse(403, { error: { code: "bot_check_failed" } })) },
      "status",
      t("provisional.apiNotice.botCheckFailed.title"),
      t("provisional.apiNotice.botCheckFailed.body"),
    ],
    [
      "bot 判定のトークンの取得の失敗",
      { getToken: () => Promise.reject(new RecaptchaExecuteError("reCAPTCHA execute failed")) },
      "status",
      t("provisional.apiNotice.botCheckFailed.title"),
      t("provisional.apiNotice.botCheckFailed.body"),
    ],
    [
      "サイトキーの設定エラー",
      { getToken: () => Promise.reject(new RecaptchaConfigurationError("missing")) },
      "alert",
      t("provisional.apiNotice.recaptchaNotConfigured.title"),
      t("provisional.apiNotice.recaptchaNotConfigured.body"),
    ],
    [
      "中継の 502（bad_gateway）",
      { respond: (url) => (url === "/api/state" ? jsonResponse(200, UNAUTHENTICATED_STATE) : jsonResponse(502, { error: { code: "bad_gateway" } })) },
      "alert",
      t("provisional.error.notice.title"),
      t("provisional.error.notice.body"),
    ],
    [
      "契約に無い応答（バックエンドの HTML）",
      {
        respond: (url) =>
          url === "/api/state"
            ? jsonResponse(200, UNAUTHENTICATED_STATE)
            : { status: 404, headers: { get: () => "text/html" }, text: async () => "<html></html>" },
      },
      "alert",
      t("provisional.error.notice.title"),
      t("provisional.error.notice.body"),
    ],
    [
      "通信の失敗",
      { respond: (url) => (url === "/api/state" ? jsonResponse(200, UNAUTHENTICATED_STATE) : Promise.reject(new TypeError("fetch failed"))) },
      "alert",
      t("provisional.error.notice.title"),
      t("provisional.error.notice.body"),
    ],
    [
      "遷移してはならない認可 URL（javascript:）",
      { respond: (url) => (url === "/api/state" ? jsonResponse(200, UNAUTHENTICATED_STATE) : jsonResponse(200, { authorization_url: "javascript:alert(1)" })) },
      "alert",
      t("provisional.error.notice.title"),
      t("provisional.error.notice.body"),
    ],
  ];

  it.each(failures)("%s: 通知を、ボタンを押した場所（ヒーロー）に出し、ボタンを元に戻す。遷移しない", async (_title, options, role, title, body) => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    const { navigate } = setup(options);

    await user.click(loginButtons()[0]);

    const notice = await within(screen.getByTestId("hero")).findByRole(role);
    expect(notice).toHaveTextContent(title);
    if (body !== null) {
      expect(notice).toHaveTextContent(body);
    }
    expect(within(screen.getByTestId("final")).queryByRole(role)).toBeNull();
    expect(navigate).not.toHaveBeenCalled();
    expect(loginButtons()).toHaveLength(2);
    expect(loginButtons()[0]).not.toHaveAttribute("aria-busy");
    consoleError.mockRestore();
  });

  it("最後のボタンを押したときは、通知を、そのボタンの場所（最後の CTA）に出す", async () => {
    const user = userEvent.setup();
    setup({ getToken: () => Promise.reject(new RecaptchaExecuteError("reCAPTCHA execute failed")) });
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);

    await user.click(loginButtons()[1]);

    expect(await within(screen.getByTestId("final")).findByRole("status")).toHaveTextContent(t("provisional.apiNotice.botCheckFailed.title"));
    expect(within(screen.getByTestId("hero")).queryByRole("status")).toBeNull();
    consoleError.mockRestore();
  });

  it("429 rate_limited: 頻度超過の通知に、再試行の目安時刻（JST）を添える", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    setup({
      respond: (url) =>
        url === "/api/state"
          ? jsonResponse(200, UNAUTHENTICATED_STATE)
          : jsonResponse(429, { error: { code: "rate_limited", details: { retry_at: "2026-10-07T14:30:00+09:00" } } }),
    });

    await user.click(loginButtons()[0]);

    const notice = await screen.findByRole("status");
    expect(notice).toHaveTextContent(t("provisional.landing.notice.rateLimited.title"));
    expect(notice).toHaveTextContent(t("provisional.apiNotice.retryAt", { time: "2026-10-07 14:30" }));
    consoleError.mockRestore();
  });

  it("失敗のあと、もう一度押すと、前の通知を消して、やり直せる", async () => {
    const user = userEvent.setup();
    let attempts = 0;
    const { navigate } = setup({
      getToken: async () => {
        attempts += 1;
        if (attempts === 1) {
          throw new RecaptchaExecuteError("reCAPTCHA execute failed");
        }
        return DUMMY_RECAPTCHA_TOKEN;
      },
    });
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);

    await user.click(loginButtons()[0]);
    await screen.findByRole("status");
    await user.click(loginButtons()[0]);

    await waitFor(() => expect(navigate).toHaveBeenCalledTimes(1));
    expect(screen.queryByRole("status")).toBeNull();
    consoleError.mockRestore();
  });

  it("失敗は、コンソールへ記録する（原因の種類。トークン・認可 URL を含めない）", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    setup({ getToken: () => Promise.reject(new RecaptchaExecuteError("reCAPTCHA execute failed")) });

    await user.click(loginButtons()[0]);
    await screen.findByRole("status");

    const logged = JSON.stringify(consoleError.mock.calls.map((args) => args.map(String)));
    expect(logged).toContain("login");
    expect(logged).not.toContain(DUMMY_RECAPTCHA_TOKEN);
    consoleError.mockRestore();
  });
});

describe("ログインの拒否・失敗の通知（URL の login_error）", () => {
  it("registration_held（再登録の保留）: 情報の通知（モックの文言）を、ヒーローに出す", async () => {
    setup({ loginError: "registration_held" });

    const notice = within(screen.getByTestId("hero")).getByRole("status");

    expect(notice).toHaveTextContent(t("provisional.landing.notice.registrationHeld.title"));
    expect(notice).toHaveTextContent(t("provisional.landing.notice.registrationHeld.body"));
    await waitFor(() => expect(loginButtons()).toHaveLength(2));
  });

  it("oauth_failed: エラーの通知を、ヒーローに出す", async () => {
    setup({ loginError: "oauth_failed" });

    const notice = within(screen.getByTestId("hero")).getByRole("alert");

    expect(notice).toHaveTextContent(t("provisional.landing.notice.oauthFailed.title"));
    expect(notice).toHaveTextContent(t("provisional.landing.notice.oauthFailed.body"));
    await waitFor(() => expect(loginButtons()).toHaveLength(2));
  });

  it("login_error が無ければ、通知を出さない", async () => {
    setup();

    expect(screen.queryByRole("alert")).toBeNull();
    expect(screen.queryByRole("status")).toBeNull();
    await waitFor(() => expect(loginButtons()).toHaveLength(2));
  });

  it("login_error の通知があるときに、ログインをやり直すと、その通知は消える", async () => {
    const user = userEvent.setup();
    setup({ loginError: "oauth_failed" });

    await user.click(loginButtons()[0]);

    await waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
  });
});
