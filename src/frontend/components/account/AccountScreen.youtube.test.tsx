import { act, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { t } from "@/messages";
import { headerOf, jsonResponse, DUMMY_AUTHORIZATION_URL, DUMMY_CSRF_TOKEN, DUMMY_RECAPTCHA_TOKEN } from "@/lib/api/test-support";
import { RecaptchaConfigurationError, RecaptchaExecuteError } from "@/lib/recaptcha";
import { DUMMY_CHANNEL_TITLE, renderAccount, stateWith } from "./test-support";

// アカウント画面: 進行中の配信（解除・削除・再接続の無効）・再確認（制限・時刻・状態の更新）・接続（bot 判定 → 認可 URL）。

const mockReplace = jest.fn();
jest.mock("next/navigation", () => ({ useRouter: () => ({ replace: mockReplace }) }));

beforeEach(() => {
  mockReplace.mockClear();
  window.history.replaceState(null, "", "/account");
});

const RECHECK = t("provisional.account.youtube.actions.recheck");
const RECHECK_BUSY = t("provisional.account.youtube.actions.recheckBusy");
const CONNECT = t("provisional.account.youtube.actions.connect");
const RECONNECT = t("provisional.account.youtube.actions.reconnect");
const CONNECT_BUSY = t("provisional.account.youtube.actions.connectBusy");
const DISCONNECT = t("provisional.account.youtube.actions.disconnect");
const DELETE_ACCOUNT = t("provisional.account.danger.delete");

async function loaded(): Promise<void> {
  await screen.findByRole("heading", { level: 2, name: t("provisional.account.youtube.eyebrow") });
}

function notice(title: string): HTMLElement {
  return screen.getByText(title).closest("[role]") as HTMLElement;
}

describe("アカウント画面: 進行中の配信（解除・削除・再接続を無効にし、先に停止するよう案内する）", () => {
  const BROADCAST = {
    id: "2f6c1d0e-7b5a-4f0e-9a43-5c8f1e2d3a4b",
    state: "live",
    end_reason: null,
    profile: "720p",
    accepted_at: "2026-10-07T13:30:00+09:00",
    live_at: "2026-10-07T13:31:10+09:00",
    ended_at: null,
    time_limit_ends_at: "2026-10-07T14:31:10+09:00",
    watch_url: "https://www.youtube.com/watch?v=dummyVideoId",
    resumable: true,
    duration_seconds: null,
    next_available_at: null,
  };

  it("案内（警告。断定と対処）を出し、再接続・接続を解除・アカウントを削除を無効にする。再確認と、ログアウトは、操作できる", async () => {
    renderAccount({ state: stateWith({}, { broadcast: BROADCAST }) });
    await loaded();

    const banner = notice(t("provisional.account.broadcastInProgress.title"));
    expect(banner).toHaveAttribute("role", "status");
    expect(banner).toHaveTextContent(t("provisional.account.broadcastInProgress.body"));
    expect(screen.getByRole("button", { name: RECONNECT })).toBeDisabled();
    expect(screen.getByRole("button", { name: DISCONNECT })).toBeDisabled();
    expect(screen.getByRole("button", { name: DELETE_ACCOUNT })).toBeDisabled();
    expect(screen.getByRole("button", { name: RECHECK })).toBeEnabled();
    expect(screen.getByRole("button", { name: t("provisional.account.logout.label") })).toBeEnabled();
  });

  it("無効のボタンは、無効の理由（案内）を、説明として持つ", async () => {
    renderAccount({ state: stateWith({}, { broadcast: BROADCAST }) });
    await loaded();

    expect(screen.getByRole("button", { name: DISCONNECT })).toHaveAccessibleDescription(
      new RegExp(t("provisional.account.broadcastInProgress.title")),
    );
  });

  it("接続済みの案内は、「配信を開始できます」を除く（進行中の配信があるため）", async () => {
    renderAccount({ state: stateWith({}, { broadcast: BROADCAST }) });
    await loaded();

    expect(screen.getByText(t("provisional.account.youtube.states.connected.guideBroadcasting"))).toBeInTheDocument();
    expect(screen.queryByText(t("provisional.account.youtube.states.connected.guide"))).toBeNull();
  });

  it("進行中の配信が無ければ、案内を出さず、操作を無効にしない", async () => {
    renderAccount();
    await loaded();

    expect(screen.queryByText(t("provisional.account.broadcastInProgress.title"))).toBeNull();
    expect(screen.getByRole("button", { name: DISCONNECT })).toBeEnabled();
    expect(screen.getByRole("button", { name: DELETE_ACCOUNT })).toBeEnabled();
  });

  it("サーバーが 409 broadcast_in_progress で拒否したら（その間に配信が始まった）、状態を取得し直して、案内を出す", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    const { calls } = renderAccount({
      state: [stateWith(), stateWith({}, { broadcast: BROADCAST })],
      handlers: { connect: () => jsonResponse(409, { error: { code: "broadcast_in_progress" } }) },
    });
    await loaded();

    await user.click(screen.getByRole("button", { name: RECONNECT }));

    expect(await screen.findByText(t("provisional.account.broadcastInProgress.title"))).toBeInTheDocument();
    expect(calls.filter((call) => call.url === "/api/state?with_channel=1")).toHaveLength(2);
    expect(screen.getByRole("button", { name: RECONNECT })).toBeDisabled();
    consoleError.mockRestore();
  });
});

describe("アカウント画面: 再確認", () => {
  it("押すと、POST /api/youtube/recheck を CSRF つきで呼び、処理中は進行形の文言にする。成功したら、状態を更新する", async () => {
    const user = userEvent.setup();
    let release: () => void = () => undefined;
    const { calls } = renderAccount({
      state: stateWith({ state: "live_not_enabled" }),
      handlers: {
        recheck: () =>
          new Promise((resolve) => {
            release = () => resolve(jsonResponse(200, { youtube: { state: "connected", channel_title: null, can_recheck_at: null } }));
          }),
      },
    });
    await loaded();

    await user.click(screen.getByRole("button", { name: RECHECK }));

    const busy = await screen.findByRole("button", { name: RECHECK_BUSY });
    expect(busy).toHaveAttribute("aria-busy", "true");
    const request = calls.find((call) => call.url === "/api/youtube/recheck");
    expect(request?.init.method).toBe("POST");
    expect(headerOf(request, "x-csrf-token")).toBe(DUMMY_CSRF_TOKEN);
    expect(headerOf(request, "x-bl-client")).toBe("web");
    await act(async () => release());

    expect(await screen.findByText(t("provisional.account.youtube.states.connected.chip"))).toBeInTheDocument();
    expect(screen.getByText(t("provisional.account.youtube.states.connected.guide"))).toBeInTheDocument();
  });

  it("再確認の結果が、チャンネル名の無い応答でも、取得済みのチャンネル名を表示し続ける", async () => {
    const user = userEvent.setup();
    renderAccount();
    await loaded();

    await user.click(screen.getByRole("button", { name: RECHECK }));
    await waitFor(() => expect(screen.getByRole("button", { name: RECHECK })).toBeEnabled());

    expect(screen.getByText(DUMMY_CHANNEL_TITLE)).toBeInTheDocument();
  });

  it("再確認の結果が認可失効なら、認可失効の表示（再接続を案内）にし、再確認の操作を出さない", async () => {
    const user = userEvent.setup();
    renderAccount({ handlers: { recheck: () => jsonResponse(200, { youtube: { state: "revoked", channel_title: null, can_recheck_at: null } }) } });
    await loaded();

    await user.click(screen.getByRole("button", { name: RECHECK }));

    expect(await screen.findByText(t("provisional.account.youtube.states.revoked.guide"))).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: RECHECK })).toBeNull();
  });

  it("次に再確認できる時刻（can_recheck_at）が未来の間は、無効にし、時刻を示す。時刻を過ぎたら、有効に戻る", async () => {
    jest.useFakeTimers({ now: new Date("2026-10-07T13:30:00+09:00") });
    try {
      const user = userEvent.setup({ advanceTimers: jest.advanceTimersByTime });
      renderAccount({
        handlers: {
          recheck: () => jsonResponse(200, { youtube: { state: "connected", channel_title: null, can_recheck_at: "2026-10-07T13:31:00+09:00" } }),
        },
      });
      await loaded();

      await user.click(screen.getByRole("button", { name: RECHECK }));

      await waitFor(() => expect(screen.getByRole("button", { name: RECHECK })).toBeDisabled());
      expect(screen.getByText(t("provisional.account.youtube.actions.recheckAvailableAt", { time: "2026-10-07 13:31" }))).toBeInTheDocument();
      expect(screen.getByRole("button", { name: RECHECK })).toHaveAccessibleDescription(
        new RegExp(t("provisional.account.youtube.actions.recheckAvailableAt", { time: "2026-10-07 13:31" })),
      );

      act(() => {
        jest.advanceTimersByTime(61_000);
      });

      await waitFor(() => expect(screen.getByRole("button", { name: RECHECK })).toBeEnabled());
      expect(screen.queryByText(t("provisional.account.youtube.actions.recheckAvailableAt", { time: "2026-10-07 13:31" }))).toBeNull();
    } finally {
      jest.useRealTimers();
    }
  });

  it("状態の取得時点で、再確認できる時刻が未来なら、最初から無効にする", async () => {
    jest.useFakeTimers({ now: new Date("2026-10-07T13:30:00+09:00") });
    try {
      renderAccount({ state: stateWith({ can_recheck_at: "2026-10-07T13:30:30+09:00" }) });
      await loaded();

      expect(screen.getByRole("button", { name: RECHECK })).toBeDisabled();
    } finally {
      jest.useRealTimers();
    }
  });

  it("再確認できる時刻が、すでに過去なら、有効にする", async () => {
    jest.useFakeTimers({ now: new Date("2026-10-07T13:30:00+09:00") });
    try {
      renderAccount({ state: stateWith({ can_recheck_at: "2026-10-07T13:29:00+09:00" }) });
      await loaded();

      expect(screen.getByRole("button", { name: RECHECK })).toBeEnabled();
    } finally {
      jest.useRealTimers();
    }
  });

  it("429（頻度の上限）: 通知（警告）に再試行の目安時刻（retry_at）を示し、その時刻まで無効にする", async () => {
    jest.useFakeTimers({ now: new Date("2026-10-07T13:30:00+09:00") });
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const user = userEvent.setup({ advanceTimers: jest.advanceTimersByTime });
      renderAccount({
        handlers: {
          recheck: () => jsonResponse(429, { error: { code: "rate_limited", details: { retry_at: "2026-10-07T13:31:00+09:00" } } }),
        },
      });
      await loaded();

      await user.click(screen.getByRole("button", { name: RECHECK }));

      const limited = await screen.findByText(t("provisional.account.notice.recheckRateLimited.title"));
      const alertElement = limited.closest("[role]") as HTMLElement;
      expect(alertElement).toHaveAttribute("role", "status");
      expect(alertElement).toHaveTextContent(t("provisional.apiNotice.retryAt", { time: "2026-10-07 13:31" }));
      expect(screen.getByRole("button", { name: RECHECK })).toBeDisabled();
    } finally {
      consoleError.mockRestore();
      jest.useRealTimers();
    }
  });

  it("503 unverifiable: 確認できなかった旨の通知を出し、接続の状態は変えない", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    renderAccount({ handlers: { recheck: () => jsonResponse(503, { error: { code: "unverifiable" } }) } });
    await loaded();

    await user.click(screen.getByRole("button", { name: RECHECK }));

    expect(await screen.findByText(t("provisional.account.connectResult.unverifiable.title"))).toBeInTheDocument();
    expect(screen.getByText(t("provisional.account.youtube.states.connected.chip"))).toBeInTheDocument();
    consoleError.mockRestore();
  });

  it("409 not_connected: 状態を取得し直して、未接続の表示にする", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    renderAccount({
      state: [stateWith(), stateWith({ state: "not_connected", channel_title: null })],
      handlers: { recheck: () => jsonResponse(409, { error: { code: "not_connected" } }) },
    });
    await loaded();

    await user.click(screen.getByRole("button", { name: RECHECK }));

    expect(await screen.findByText(t("provisional.account.youtube.states.notConnected.chip"))).toBeInTheDocument();
    consoleError.mockRestore();
  });

  it("401（セッション切れ）: ランディングへ戻す", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    renderAccount({ handlers: { recheck: () => jsonResponse(401, { error: { code: "not_logged_in" } }) } });
    await loaded();

    await user.click(screen.getByRole("button", { name: RECHECK }));

    await waitFor(() => expect(mockReplace).toHaveBeenCalledWith("/"));
    consoleError.mockRestore();
  });

  it("403 csrf_invalid: 状態を取得し直して（新しいトークン）、失敗の通知を出す。もう一度押せば、新しいトークンで送る", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    let attempts = 0;
    const { calls } = renderAccount({
      state: [stateWith(), { ...stateWith(), csrf_token: "dummy-csrf-token-renewed" }],
      handlers: {
        recheck: () => {
          attempts += 1;
          return attempts === 1
            ? jsonResponse(403, { error: { code: "csrf_invalid" } })
            : jsonResponse(200, { youtube: { state: "connected", channel_title: null, can_recheck_at: null } });
        },
      },
    });
    await loaded();

    await user.click(screen.getByRole("button", { name: RECHECK }));
    expect(await screen.findByText(t("provisional.error.notice.title"))).toBeInTheDocument();
    await user.click(await screen.findByRole("button", { name: RECHECK }));

    await waitFor(() => expect(calls.filter((call) => call.url === "/api/youtube/recheck")).toHaveLength(2));
    const second = calls.filter((call) => call.url === "/api/youtube/recheck")[1];
    expect(headerOf(second, "x-csrf-token")).toBe("dummy-csrf-token-renewed");
    consoleError.mockRestore();
  });

  it("契約に無い応答（500・通信の失敗）は、一般的な失敗の通知（断定と対処）", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    renderAccount({ handlers: { recheck: () => Promise.reject(new TypeError("fetch failed")) } });
    await loaded();

    await user.click(screen.getByRole("button", { name: RECHECK }));

    const failure = await screen.findByRole("alert");
    expect(failure).toHaveTextContent(t("provisional.error.notice.title"));
    expect(failure).toHaveTextContent(t("provisional.error.notice.body"));
    await waitFor(() => expect(screen.getByRole("button", { name: RECHECK })).toBeEnabled());
    consoleError.mockRestore();
  });
});

describe("アカウント画面: 接続・再接続（bot 判定 → 接続の開始 → 認可 URL へ遷移）", () => {
  const notConnected = stateWith({ state: "not_connected", channel_title: null });

  it("押すと、行為名 youtube_connect で bot 判定のトークンを取得し、POST /api/youtube/connect/start へ渡し、認可 URL へ遷移する", async () => {
    const user = userEvent.setup();
    const { calls, recaptcha, navigate } = renderAccount({ state: notConnected });
    await loaded();

    await user.click(screen.getByRole("button", { name: CONNECT }));

    await waitFor(() => expect(navigate).toHaveBeenCalledWith(DUMMY_AUTHORIZATION_URL));
    expect(recaptcha.getToken).toHaveBeenCalledWith("youtube_connect");
    const request = calls.find((call) => call.url === "/api/youtube/connect/start");
    expect(JSON.parse(request?.init.body ?? "")).toEqual({ recaptcha_token: DUMMY_RECAPTCHA_TOKEN });
    expect(headerOf(request, "x-csrf-token")).toBe(DUMMY_CSRF_TOKEN);
  });

  it("接続済みの再接続も、同じ流れで、認可 URL へ遷移する", async () => {
    const user = userEvent.setup();
    const { navigate } = renderAccount();
    await loaded();

    await user.click(screen.getByRole("button", { name: RECONNECT }));

    await waitFor(() => expect(navigate).toHaveBeenCalledWith(DUMMY_AUTHORIZATION_URL));
  });

  it("処理中は、進行形の文言（接続中…）にし、ほかの操作を無効にする。二重に押しても、1 回だけ", async () => {
    const user = userEvent.setup();
    let release: (token: string) => void = () => undefined;
    const { recaptcha, navigate } = renderAccount({
      state: notConnected,
      getToken: () => new Promise<string>((resolve) => (release = resolve)),
    });
    await loaded();

    await user.click(screen.getByRole("button", { name: CONNECT }));

    const busy = await screen.findByRole("button", { name: CONNECT_BUSY });
    expect(busy).toHaveAttribute("aria-busy", "true");
    expect(screen.getByRole("button", { name: t("provisional.account.danger.delete") })).toBeDisabled();
    expect(screen.getByRole("button", { name: t("provisional.account.logout.label") })).toBeDisabled();
    await user.click(busy);
    await user.dblClick(busy);
    expect(recaptcha.getToken).toHaveBeenCalledTimes(1);

    await act(async () => release(DUMMY_RECAPTCHA_TOKEN));
    await waitFor(() => expect(navigate).toHaveBeenCalledTimes(1));
  });

  it("戻る操作でページが復元されたとき（bfcache の pageshow）、処理中を解除する", async () => {
    const user = userEvent.setup();
    const { navigate } = renderAccount({ state: notConnected });
    await loaded();
    await user.click(screen.getByRole("button", { name: CONNECT }));
    await waitFor(() => expect(navigate).toHaveBeenCalledTimes(1));
    expect(screen.getByRole("button", { name: CONNECT_BUSY })).toBeInTheDocument();

    act(() => {
      window.dispatchEvent(Object.assign(new Event("pageshow"), { persisted: true }));
    });

    expect(await screen.findByRole("button", { name: CONNECT })).toBeInTheDocument();
  });

  const failures: Array<[string, Parameters<typeof renderAccount>[0], "alert" | "status", string]> = [
    [
      "403 bot_check_failed",
      { state: notConnected, handlers: { connect: () => jsonResponse(403, { error: { code: "bot_check_failed" } }) } },
      "status",
      t("provisional.apiNotice.botCheckFailed.title"),
    ],
    [
      "bot 判定のトークンの取得の失敗",
      { state: notConnected, getToken: () => Promise.reject(new RecaptchaExecuteError("reCAPTCHA execute failed")) },
      "status",
      t("provisional.apiNotice.botCheckFailed.title"),
    ],
    [
      "サイトキーの設定エラー",
      { state: notConnected, getToken: () => Promise.reject(new RecaptchaConfigurationError("missing")) },
      "alert",
      t("provisional.apiNotice.recaptchaNotConfigured.title"),
    ],
    [
      "429（接続の試行が多すぎる）",
      {
        state: notConnected,
        handlers: { connect: () => jsonResponse(429, { error: { code: "rate_limited", details: { retry_at: "2026-10-07T14:30:00+09:00" } } }) },
      },
      "status",
      t("provisional.account.notice.connectRateLimited.title"),
    ],
    [
      "中継の 502（bad_gateway）",
      { state: notConnected, handlers: { connect: () => jsonResponse(502, { error: { code: "bad_gateway" } }) } },
      "alert",
      t("provisional.error.notice.title"),
    ],
    [
      "遷移してはならない認可 URL（javascript:）",
      { state: notConnected, handlers: { connect: () => jsonResponse(200, { authorization_url: "javascript:alert(1)" }) } },
      "alert",
      t("provisional.error.notice.title"),
    ],
  ];

  it.each(failures)("%s: 通知を出し、遷移せず、ボタンを元に戻す", async (_title, options, role, title) => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    const { navigate } = renderAccount(options);
    await loaded();

    await user.click(screen.getByRole("button", { name: CONNECT }));

    const element = (await screen.findByText(title)).closest("[role]") as HTMLElement;
    expect(element).toHaveAttribute("role", role);
    expect(navigate).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: CONNECT })).not.toHaveAttribute("aria-busy");
    consoleError.mockRestore();
  });

  it("429 の通知には、再試行の目安時刻（JST）を添える", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    renderAccount({
      state: notConnected,
      handlers: { connect: () => jsonResponse(429, { error: { code: "rate_limited", details: { retry_at: "2026-10-07T14:30:00+09:00" } } }) },
    });
    await loaded();

    await user.click(screen.getByRole("button", { name: CONNECT }));

    const element = (await screen.findByText(t("provisional.account.notice.connectRateLimited.title"))).closest("[role]") as HTMLElement;
    expect(element).toHaveTextContent(t("provisional.apiNotice.retryAt", { time: "2026-10-07 14:30" }));
    consoleError.mockRestore();
  });

  it("401（セッション切れ）: ランディングへ戻す", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    renderAccount({ state: notConnected, handlers: { connect: () => jsonResponse(401, { error: { code: "not_logged_in" } }) } });
    await loaded();

    await user.click(screen.getByRole("button", { name: CONNECT }));

    await waitFor(() => expect(mockReplace).toHaveBeenCalledWith("/"));
    consoleError.mockRestore();
  });

  it("失敗のあと、もう一度押すと、前の通知を消して、やり直せる", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    let attempts = 0;
    const { navigate } = renderAccount({
      state: notConnected,
      getToken: async () => {
        attempts += 1;
        if (attempts === 1) {
          throw new RecaptchaExecuteError("reCAPTCHA execute failed");
        }
        return DUMMY_RECAPTCHA_TOKEN;
      },
    });
    await loaded();

    await user.click(screen.getByRole("button", { name: CONNECT }));
    await screen.findByText(t("provisional.apiNotice.botCheckFailed.title"));
    await user.click(screen.getByRole("button", { name: CONNECT }));

    await waitFor(() => expect(navigate).toHaveBeenCalledTimes(1));
    expect(screen.queryByText(t("provisional.apiNotice.botCheckFailed.title"))).toBeNull();
    consoleError.mockRestore();
  });

  it("失敗は、コンソールへ記録する（原因の種類。トークンを含めない）", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    renderAccount({ state: notConnected, getToken: () => Promise.reject(new RecaptchaExecuteError("reCAPTCHA execute failed")) });
    await loaded();

    await user.click(screen.getByRole("button", { name: CONNECT }));
    await screen.findByText(t("provisional.apiNotice.botCheckFailed.title"));

    const logged = JSON.stringify(consoleError.mock.calls.map((args) => args.map(String)));
    expect(logged).toContain("connect");
    expect(logged).not.toContain(DUMMY_RECAPTCHA_TOKEN);
    expect(within(document.body).queryByText(DUMMY_RECAPTCHA_TOKEN)).toBeNull();
    consoleError.mockRestore();
  });
});
