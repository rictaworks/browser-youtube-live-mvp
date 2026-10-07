import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { LIMITS, type ConnectResult } from "@/core/contract";
import { t } from "@/messages";
import { renderAccount, stateWith, DUMMY_CHANNEL_TITLE, UNAUTHENTICATED_STATE } from "./test-support";

// アカウント画面（/account）: 読み込み・ログインの確認・YouTube の接続状態 4 種・チャンネル名・接続の結果の通知。
// API は fetch の疑似、ルーターは疑似（未ログインを、/ へ誘導する）。

const mockReplace = jest.fn();
jest.mock("next/navigation", () => ({ useRouter: () => ({ replace: mockReplace }) }));

beforeEach(() => {
  mockReplace.mockClear();
  window.history.replaceState(null, "", "/account");
});

const STATUS_LABEL = t("provisional.account.youtube.statusLabel");

async function loaded(): Promise<void> {
  await screen.findByRole("heading", { level: 2, name: t("provisional.account.youtube.eyebrow") });
}

function chipText(): string {
  const term = screen.getByText(STATUS_LABEL);
  const row = term.closest("div") as HTMLElement;
  return within(row).getByRole("status").textContent ?? "";
}

describe("アカウント画面: 読み込みとログインの確認", () => {
  it("ページの題（h1: Account と副題）と、読み込み中の表示を出し、API の getState（チャンネル名つき）を 1 回呼ぶ", async () => {
    const { calls } = renderAccount();

    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(`${t("provisional.account.heading")} ${t("provisional.account.subheading")}`);
    expect(screen.getByRole("status")).toHaveTextContent(t("provisional.account.loading"));
    await loaded();

    expect(calls.filter((call) => call.url === "/api/state?with_channel=1")).toHaveLength(1);
    expect(screen.queryByText(t("provisional.account.loading"))).toBeNull();
  });

  it("未ログインなら、ランディング（/）へ誘導し、カードを出さない", async () => {
    renderAccount({ state: UNAUTHENTICATED_STATE });

    await waitFor(() => expect(mockReplace).toHaveBeenCalledWith("/"));

    expect(screen.queryByRole("heading", { level: 2 })).toBeNull();
    expect(screen.queryByRole("button", { name: t("provisional.account.logout.label") })).toBeNull();
  });

  it("状態を取得できなかったら、エラーの通知（断定と対処）と、再試行の操作を出す。押すと、取得し直す", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    const { calls } = renderAccount({ failAll: true });

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent(t("provisional.error.notice.title"));
    expect(alert).toHaveTextContent(t("provisional.error.notice.body"));
    await user.click(within(alert).getByRole("button", { name: t("provisional.error.action") }));

    await waitFor(() => expect(calls.filter((call) => call.url === "/api/state?with_channel=1")).toHaveLength(2));
    expect(mockReplace).not.toHaveBeenCalled();
    consoleError.mockRestore();
  });

  it("画面を離れたら（アンマウント）、取得中の getState を中断する", async () => {
    const { calls, unmount } = renderAccount({ stateGate: new Promise<void>(() => undefined) });

    await waitFor(() => expect(calls).toHaveLength(1));
    expect(calls[0].init.signal.aborted).toBe(false);
    unmount();

    expect(calls[0].init.signal.aborted).toBe(true);
  });

  it("ログイン済みなら、YouTube のカード・Danger Zone のカード・ログアウトを出す。h2 は 2 つだけ（見出しの階層を飛ばさない）", async () => {
    renderAccount();
    await loaded();

    expect(screen.getAllByRole("heading", { level: 2 }).map((heading) => heading.textContent)).toEqual([
      t("provisional.account.youtube.eyebrow"),
      t("provisional.account.danger.eyebrow"),
    ]);
    expect(screen.getByRole("button", { name: t("provisional.account.logout.label") })).toBeInTheDocument();
    expect(screen.queryAllByRole("heading", { level: 3 })).toHaveLength(0);
    expect(screen.queryByRole("main")).toBeNull();
  });
});

describe("アカウント画面: YouTube の接続状態（4 種。文言と形の異なる図形のチップ・案内・操作）", () => {
  const recheck = t("provisional.account.youtube.actions.recheck");
  const connect = t("provisional.account.youtube.actions.connect");
  const reconnect = t("provisional.account.youtube.actions.reconnect");
  const disconnect = t("provisional.account.youtube.actions.disconnect");

  const cases = [
    {
      title: "接続済み",
      youtube: { state: "connected" },
      chip: t("provisional.account.youtube.states.connected.chip"),
      icon: "check",
      guide: t("provisional.account.youtube.states.connected.guide"),
      buttons: [recheck, reconnect, disconnect],
      absent: [connect],
      channel: true,
    },
    {
      title: "未接続",
      youtube: { state: "not_connected", channel_title: null },
      chip: t("provisional.account.youtube.states.notConnected.chip"),
      icon: "circle",
      guide: t("provisional.account.youtube.states.notConnected.guide"),
      buttons: [connect],
      absent: [recheck, reconnect, disconnect],
      channel: false,
    },
    {
      title: "ライブ未有効",
      youtube: { state: "live_not_enabled" },
      chip: t("provisional.account.youtube.states.liveNotEnabled.chip"),
      icon: "triangle-exclamation",
      guide: t("provisional.account.youtube.states.liveNotEnabled.guide"),
      buttons: [recheck, reconnect, disconnect],
      absent: [connect],
      channel: true,
    },
    {
      title: "認可失効",
      youtube: { state: "revoked", channel_title: null },
      chip: t("provisional.account.youtube.states.revoked.chip"),
      icon: "circle-xmark",
      guide: t("provisional.account.youtube.states.revoked.guide"),
      buttons: [reconnect, disconnect],
      absent: [recheck, connect],
      channel: false,
    },
  ] as const;

  it.each(cases)("$title: チップ（文言と図形）・案内文・操作", async ({ youtube, chip, icon, guide, buttons, absent, channel }) => {
    renderAccount({ state: stateWith(youtube) });
    await loaded();

    const status = screen.getByText(STATUS_LABEL).closest("div") as HTMLElement;
    const chipElement = within(status).getByText(chip);
    expect(chipElement.querySelector("svg")).toHaveAttribute("data-icon", icon);
    expect(chipElement.querySelector("svg")).toHaveAttribute("aria-hidden", "true");
    expect(screen.getByText(guide)).toBeInTheDocument();
    for (const name of buttons) {
      expect(screen.getByRole("button", { name })).toBeInTheDocument();
    }
    for (const name of absent) {
      expect(screen.queryByRole("button", { name })).toBeNull();
    }
    expect(screen.queryByText(t("provisional.account.youtube.channelLabel")) !== null).toBe(channel);
  });

  it("4 状態のチップの図形は、互いに異なる（色だけで状態を区別しない）", async () => {
    const icons: string[] = [];
    for (const { youtube } of cases) {
      const { unmount } = renderAccount({ state: stateWith(youtube) });
      await loaded();
      icons.push(
        within(screen.getByText(STATUS_LABEL).closest("div") as HTMLElement)
          .getByRole("status")
          .querySelector("svg")
          ?.getAttribute("data-icon") ?? "",
      );
      unmount();
    }

    expect(new Set(icons).size).toBe(4);
  });

  it("接続状態のチップは、状態の変化を支援技術へ伝える領域（role=status）の中にある", async () => {
    renderAccount();
    await loaded();

    expect(chipText()).toContain(t("provisional.account.youtube.states.connected.chip"));
    expect(screen.getByText(STATUS_LABEL).closest("div")?.querySelector('[aria-live="polite"]')).not.toBeNull();
  });

  it("次に取れる操作を強調する: 未接続・認可失効は、接続の操作が主要（強調）。接続済みの再接続は、強調しない", async () => {
    const connected = renderAccount({ state: stateWith({ state: "connected" }) });
    await loaded();
    expect(screen.getByRole("button", { name: reconnect })).not.toHaveClass("primary");
    connected.unmount();

    const notConnected = renderAccount({ state: stateWith({ state: "not_connected", channel_title: null }) });
    await loaded();
    expect(screen.getByRole("button", { name: connect })).toHaveClass("primary");
    notConnected.unmount();

    renderAccount({ state: stateWith({ state: "revoked", channel_title: null }) });
    await loaded();
    expect(screen.getByRole("button", { name: reconnect })).toHaveClass("primary");
  });

  it("再確認の回数の制限（契約の 1 分に 1 回・1 日 20 回）を、再確認の操作の横に示す", async () => {
    renderAccount();
    await loaded();

    expect(
      screen.getByText(
        t("provisional.account.youtube.actions.recheckLimit", {
          windowMinutes: LIMITS.rate_limits.recheck_per_minute.window_seconds / 60,
          perWindow: LIMITS.rate_limits.recheck_per_minute.limit,
          perDay: LIMITS.rate_limits.recheck_per_day.limit,
        }),
      ),
    ).toBeInTheDocument();
  });

  it("接続の解除の説明（未清算の清算・権限の失効・ストリームは削除しない）を、解除の操作の下に示す。未接続では示さない", async () => {
    const connected = renderAccount();
    await loaded();
    expect(screen.getByText(t("provisional.account.youtube.disconnectNote"))).toBeInTheDocument();
    connected.unmount();

    renderAccount({ state: stateWith({ state: "not_connected", channel_title: null }) });
    await loaded();
    expect(screen.queryByText(t("provisional.account.youtube.disconnectNote"))).toBeNull();
  });
});

describe("アカウント画面: 接続先のチャンネル名", () => {
  it("取得できたチャンネル名を表示し、取得の目的と保持の時間（契約の最長 10 分）を、注記する", async () => {
    renderAccount();
    await loaded();

    expect(screen.getByText(t("provisional.account.youtube.channelLabel"))).toBeInTheDocument();
    expect(screen.getByText(DUMMY_CHANNEL_TITLE)).toBeInTheDocument();
    expect(
      screen.getByText(t("provisional.account.youtube.channel.note", { minutes: LIMITS.retention.channel_title_memory_max_minutes })),
    ).toBeInTheDocument();
  });

  it("チャンネル名を取得できなければ（null）、取得できなかった旨と対処を、断定と対処で示す。図形も伴う", async () => {
    renderAccount({ state: stateWith({ channel_title: null }) });
    await loaded();

    const row = screen.getByText(t("provisional.account.youtube.channelLabel")).closest("div") as HTMLElement;
    expect(row).toHaveTextContent(t("provisional.account.youtube.channel.unavailableTitle"));
    expect(row).toHaveTextContent(t("provisional.account.youtube.channel.unavailableBody"));
    expect(row.querySelector("svg")).toHaveAttribute("aria-hidden", "true");
  });

  it("未接続・認可失効では、チャンネルの行も、注記も出さない", async () => {
    renderAccount({ state: stateWith({ state: "revoked", channel_title: null }) });
    await loaded();

    expect(screen.queryByText(t("provisional.account.youtube.channelLabel"))).toBeNull();
    expect(screen.queryByText(t("provisional.account.youtube.channel.note", { minutes: 10 }))).toBeNull();
  });
});

describe("アカウント画面: Google の権限の管理（外部リンク）", () => {
  it("権限を取り消せる旨と、Google アカウントの権限の管理へのリンク（新しいタブ・noopener）を示す", async () => {
    renderAccount();
    await loaded();

    const link = screen.getByRole("link", { name: new RegExp(t("provisional.privacy.youtubeApi.permissions.label")) });

    expect(screen.getByText(t("provisional.account.youtube.permissionsNote"))).toBeInTheDocument();
    expect(link).toHaveAttribute("href", t("provisional.privacy.youtubeApi.permissions.href"));
    expect(link).toHaveAttribute("target", "_blank");
    expect(link).toHaveAttribute("rel", "noopener noreferrer");
  });
});

describe("アカウント画面: 接続の結果の通知（/account?connect=<結果>）と URL の整理", () => {
  const failures: Array<[ConnectResult, "alert" | "status", string, string]> = [
    ["scope_denied", "alert", t("provisional.account.connectResult.scopeDenied.title"), t("provisional.account.connectResult.scopeDenied.body")],
    ["no_refresh_token", "alert", t("provisional.account.connectResult.noRefreshToken.title"), t("provisional.account.connectResult.noRefreshToken.body")],
    ["no_channel", "status", t("provisional.account.connectResult.noChannel.title"), t("provisional.account.connectResult.noChannel.body")],
    ["unverifiable", "status", t("provisional.account.connectResult.unverifiable.title"), t("provisional.account.connectResult.unverifiable.body")],
  ];

  it.each(failures)("不成立 %s: 通知（role=%s。断定と対処）を出す", async (result, role, title, body) => {
    renderAccount({ initialConnectResult: result, state: stateWith({ state: "not_connected", channel_title: null }) });
    await loaded();

    // 状態の領域（接続の状態のチップ）も role=status のため、題の文言から、通知を特定する
    const notice = screen.getByText(title).closest("[role]") as HTMLElement;
    expect(notice).toHaveAttribute("role", role);
    expect(notice).toHaveTextContent(body);
  });

  it.each(["connected", "live_not_enabled"] as const)("成功 %s: 通知を出さない（状態の表示が変わる）", async (result) => {
    renderAccount({ initialConnectResult: result, state: stateWith({ state: result }) });
    await loaded();

    expect(screen.queryByRole("alert")).toBeNull();
    for (const [, , title] of failures) {
      expect(screen.queryByText(title)).toBeNull();
    }
  });

  it("権限の拒否・更新トークンなし・チャンネルなしのあとの未接続は、短い案内にする（通知が、チャンネルの作成などを案内するため）", async () => {
    renderAccount({ initialConnectResult: "no_channel", state: stateWith({ state: "not_connected", channel_title: null }) });
    await loaded();

    expect(screen.getByText(t("provisional.account.youtube.states.notConnected.guideAfterFailure"))).toBeInTheDocument();
    expect(screen.queryByText(t("provisional.account.youtube.states.notConnected.guide"))).toBeNull();
  });

  it("確認不能（unverifiable）のあとは、接続の状態が変わっていないため、元の案内のまま", async () => {
    renderAccount({ initialConnectResult: "unverifiable", state: stateWith({ state: "connected" }) });
    await loaded();

    expect(screen.getByText(t("provisional.account.youtube.states.connected.guide"))).toBeInTheDocument();
  });

  it("結果のクエリを読んだあと、URL からクエリを取り除く（履歴を増やさず、再読み込みで通知を繰り返さない）", async () => {
    window.history.replaceState(null, "", "/account?connect=scope_denied");
    const lengthBefore = window.history.length;
    renderAccount({ initialConnectResult: "scope_denied", state: stateWith({ state: "not_connected", channel_title: null }) });

    await loaded();

    expect(window.location.search).toBe("");
    expect(window.location.pathname).toBe("/account");
    expect(window.history.length).toBe(lengthBefore);
  });

  it("成功の結果のクエリも、取り除く", async () => {
    window.history.replaceState(null, "", "/account?connect=connected");
    renderAccount({ initialConnectResult: "connected" });

    await loaded();

    expect(window.location.search).toBe("");
  });

  it("結果のクエリが無ければ、URL を変えない", async () => {
    window.history.replaceState(null, "", "/account?other=1");
    renderAccount();

    await loaded();

    expect(window.location.search).toBe("?other=1");
  });
});
