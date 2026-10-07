import { act, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { t } from "@/messages";
import { emptyResponse, headerOf, jsonResponse, DUMMY_CSRF_TOKEN } from "@/lib/api/test-support";
import { renderAccount, stateWith } from "./test-support";

// アカウント画面: 接続の解除・アカウントの削除（確認のダイアログ）・ログアウト。ネイティブの confirm は使わない。

const mockReplace = jest.fn();
jest.mock("next/navigation", () => ({ useRouter: () => ({ replace: mockReplace }) }));

beforeEach(() => {
  mockReplace.mockClear();
  window.history.replaceState(null, "", "/account");
});

const DISCONNECT = t("provisional.account.youtube.actions.disconnect");
const DISCONNECT_BUSY = t("provisional.account.youtube.actions.disconnectBusy");
const CONNECT = t("provisional.account.youtube.actions.connect");
const DELETE_ACCOUNT = t("provisional.account.danger.delete");
const DELETE_BUSY = t("provisional.account.danger.deleteBusy");
const CANCEL = t("provisional.account.dialog.cancel");
const LOGOUT = t("provisional.account.logout.label");

async function loaded(): Promise<void> {
  await screen.findByRole("heading", { level: 2, name: t("provisional.account.youtube.eyebrow") });
}

describe("アカウント画面: 接続の解除（確認のダイアログ）", () => {
  it("「接続を解除」を押すと、確認のダイアログ（alertdialog）を開く。題と説明は、操作の名前と、解除で起きること。背景の画面は、操作できなくする（inert）", async () => {
    const user = userEvent.setup();
    const nativeConfirm = jest.spyOn(window, "confirm").mockImplementation(() => true);
    const { calls } = renderAccount();
    await loaded();

    await user.click(screen.getByRole("button", { name: DISCONNECT }));

    const dialog = screen.getByRole("alertdialog", { name: DISCONNECT });
    expect(dialog).toHaveAccessibleDescription(t("provisional.account.youtube.disconnectNote"));
    expect(dialog).toHaveAttribute("aria-modal", "true");
    expect(within(dialog).getByRole("button", { name: CANCEL })).toHaveFocus();
    expect(document.querySelector("[inert]")).not.toBeNull();
    expect(calls.some((call) => call.url === "/api/youtube/disconnect")).toBe(false);
    expect(nativeConfirm).not.toHaveBeenCalled();
    nativeConfirm.mockRestore();
  });

  it("キャンセル・Escape では、API を呼ばずに閉じ、「接続を解除」へフォーカスを戻す。背景の画面は、操作できるようになる", async () => {
    const user = userEvent.setup();
    const { calls } = renderAccount();
    await loaded();

    await user.click(screen.getByRole("button", { name: DISCONNECT }));
    await user.click(screen.getByRole("button", { name: CANCEL }));
    expect(screen.queryByRole("alertdialog")).toBeNull();
    expect(screen.getByRole("button", { name: DISCONNECT })).toHaveFocus();
    expect(document.querySelector("[inert]")).toBeNull();

    await user.click(screen.getByRole("button", { name: DISCONNECT }));
    await user.keyboard("{Escape}");
    expect(screen.queryByRole("alertdialog")).toBeNull();
    expect(screen.getByRole("button", { name: DISCONNECT })).toHaveFocus();
    expect(calls.some((call) => call.url === "/api/youtube/disconnect")).toBe(false);
  });

  it("確認すると、POST /api/youtube/disconnect を CSRF つきで呼び、処理中は進行形の文言にする。成功したら、ダイアログを閉じて、未接続の表示にする", async () => {
    const user = userEvent.setup();
    let release: () => void = () => undefined;
    const { calls } = renderAccount({
      handlers: {
        disconnect: () =>
          new Promise((resolve) => {
            release = () => resolve(jsonResponse(200, { youtube: { state: "not_connected", channel_title: null, can_recheck_at: null } }));
          }),
      },
    });
    await loaded();
    await user.click(screen.getByRole("button", { name: DISCONNECT }));

    await user.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: DISCONNECT }));

    const busy = await screen.findByRole("button", { name: DISCONNECT_BUSY });
    expect(busy).toHaveAttribute("aria-busy", "true");
    const request = calls.find((call) => call.url === "/api/youtube/disconnect");
    expect(request?.init.method).toBe("POST");
    expect(headerOf(request, "x-csrf-token")).toBe(DUMMY_CSRF_TOKEN);
    await act(async () => release());

    await waitFor(() => expect(screen.queryByRole("alertdialog")).toBeNull());
    expect(screen.getByText(t("provisional.account.youtube.states.notConnected.chip"))).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: DISCONNECT })).toBeNull();
  });

  it("解除が成功して、押したボタンが無くなったら、次に取れる操作（接続）へフォーカスを移す", async () => {
    const user = userEvent.setup();
    renderAccount();
    await loaded();
    await user.click(screen.getByRole("button", { name: DISCONNECT }));

    await user.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: DISCONNECT }));

    await waitFor(() => expect(screen.getByRole("button", { name: CONNECT })).toHaveFocus());
  });

  it("処理中は、キャンセルも Escape も効かず、ダイアログは閉じない", async () => {
    const user = userEvent.setup();
    renderAccount({ handlers: { disconnect: () => new Promise(() => undefined) } });
    await loaded();
    await user.click(screen.getByRole("button", { name: DISCONNECT }));
    await user.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: DISCONNECT }));
    await screen.findByRole("button", { name: DISCONNECT_BUSY });

    await user.keyboard("{Escape}");

    expect(screen.getByRole("alertdialog")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: CANCEL })).toBeDisabled();
  });

  it("409 broadcast_in_progress（その間に配信が始まった）: ダイアログを閉じ、状態を取得し直して、案内を出す", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    renderAccount({
      state: [
        stateWith(),
        stateWith(
          {},
          {
            broadcast: {
              id: "2f6c1d0e-7b5a-4f0e-9a43-5c8f1e2d3a4b",
              state: "live",
              end_reason: null,
              profile: "720p",
              accepted_at: "2026-10-07T13:30:00+09:00",
              live_at: "2026-10-07T13:31:10+09:00",
              ended_at: null,
              time_limit_ends_at: "2026-10-07T14:31:10+09:00",
              watch_url: null,
              resumable: true,
              duration_seconds: null,
              next_available_at: null,
            },
          },
        ),
      ],
      handlers: { disconnect: () => jsonResponse(409, { error: { code: "broadcast_in_progress" } }) },
    });
    await loaded();
    await user.click(screen.getByRole("button", { name: DISCONNECT }));

    await user.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: DISCONNECT }));

    expect(await screen.findByText(t("provisional.account.broadcastInProgress.title"))).toBeInTheDocument();
    expect(screen.queryByRole("alertdialog")).toBeNull();
    expect(screen.getByRole("button", { name: DISCONNECT })).toBeDisabled();
    consoleError.mockRestore();
  });

  it("契約に無い失敗（500）: ダイアログは開いたまま、失敗の通知（エラー）を中に出す。確認は、もう一度押せる", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    renderAccount({ handlers: { disconnect: () => jsonResponse(500, { error: { code: "internal_error" } }) } });
    await loaded();
    await user.click(screen.getByRole("button", { name: DISCONNECT }));

    await user.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: DISCONNECT }));

    const dialog = screen.getByRole("alertdialog");
    const failure = await within(dialog).findByRole("alert");
    expect(failure).toHaveTextContent(t("provisional.error.notice.title"));
    expect(failure).toHaveTextContent(t("provisional.error.notice.body"));
    expect(within(dialog).getByRole("button", { name: DISCONNECT })).toBeEnabled();
    expect(within(dialog).getByRole("button", { name: CANCEL })).toBeEnabled();
    consoleError.mockRestore();
  });

  it("401（セッション切れ）: ランディングへ戻す", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    renderAccount({ handlers: { disconnect: () => jsonResponse(401, { error: { code: "not_logged_in" } }) } });
    await loaded();
    await user.click(screen.getByRole("button", { name: DISCONNECT }));

    await user.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: DISCONNECT }));

    await waitFor(() => expect(mockReplace).toHaveBeenCalledWith("/"));
    consoleError.mockRestore();
  });
});

describe("アカウント画面: アカウントの削除（Danger Zone と確認のダイアログ）", () => {
  it("Danger Zone に、削除の説明（紐づく全ての記録・受理と同時・再登録は次の利用日から）と、アカウントを削除の操作（停止の赤）を出す", async () => {
    renderAccount();
    await loaded();

    expect(screen.getByText(t("provisional.account.danger.note"))).toBeInTheDocument();
    expect(screen.getByRole("button", { name: DELETE_ACCOUNT })).toHaveClass("stop");
  });

  it("押すと、確認のダイアログ（alertdialog）を開く。題は操作の名前、説明は削除で起きること。API は、まだ呼ばない", async () => {
    const user = userEvent.setup();
    const { calls } = renderAccount();
    await loaded();

    await user.click(screen.getByRole("button", { name: DELETE_ACCOUNT }));

    const dialog = screen.getByRole("alertdialog", { name: DELETE_ACCOUNT });
    expect(dialog).toHaveAccessibleDescription(t("provisional.account.danger.note"));
    expect(within(dialog).getByRole("button", { name: CANCEL })).toHaveFocus();
    expect(calls.some((call) => call.url === "/api/account")).toBe(false);
  });

  it("確認すると、DELETE /api/account を CSRF つきで呼び、成功したら、ランディング（/）へ移る。移るまで、処理中のまま（二重に押せない）", async () => {
    const user = userEvent.setup();
    const { calls } = renderAccount();
    await loaded();
    await user.click(screen.getByRole("button", { name: DELETE_ACCOUNT }));

    await user.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: DELETE_ACCOUNT }));

    await waitFor(() => expect(mockReplace).toHaveBeenCalledWith("/"));
    const request = calls.find((call) => call.url === "/api/account");
    expect(request?.init.method).toBe("DELETE");
    expect(headerOf(request, "x-csrf-token")).toBe(DUMMY_CSRF_TOKEN);
    expect(headerOf(request, "x-bl-client")).toBe("web");
    expect(within(screen.getByRole("alertdialog")).getByRole("button", { name: DELETE_BUSY })).toHaveAttribute("aria-busy", "true");
    expect(mockReplace).toHaveBeenCalledTimes(1);
  });

  it("処理中は、進行形の文言（削除中…）にする", async () => {
    const user = userEvent.setup();
    renderAccount({ handlers: { deleteAccount: () => new Promise(() => undefined) } });
    await loaded();
    await user.click(screen.getByRole("button", { name: DELETE_ACCOUNT }));

    await user.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: DELETE_ACCOUNT }));

    expect(await screen.findByRole("button", { name: DELETE_BUSY })).toHaveAttribute("aria-busy", "true");
  });

  it("キャンセル・Escape では、削除しない（API を呼ばず、画面に留まる）", async () => {
    const user = userEvent.setup();
    const { calls } = renderAccount();
    await loaded();

    await user.click(screen.getByRole("button", { name: DELETE_ACCOUNT }));
    await user.click(screen.getByRole("button", { name: CANCEL }));
    await user.click(screen.getByRole("button", { name: DELETE_ACCOUNT }));
    await user.keyboard("{Escape}");

    expect(screen.queryByRole("alertdialog")).toBeNull();
    expect(screen.getByRole("button", { name: DELETE_ACCOUNT })).toHaveFocus();
    expect(calls.some((call) => call.url === "/api/account")).toBe(false);
    expect(mockReplace).not.toHaveBeenCalled();
  });

  it("409 broadcast_in_progress: ダイアログを閉じ、状態を取得し直して、案内を出す。ランディングへは移らない", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    renderAccount({
      state: [
        stateWith(),
        stateWith({}, { broadcast: { id: "x", state: "live", end_reason: null, profile: "720p", accepted_at: "2026-10-07T13:30:00+09:00", live_at: null, ended_at: null, time_limit_ends_at: null, watch_url: null, resumable: true, duration_seconds: null, next_available_at: null } }),
      ],
      handlers: { deleteAccount: () => jsonResponse(409, { error: { code: "broadcast_in_progress" } }) },
    });
    await loaded();
    await user.click(screen.getByRole("button", { name: DELETE_ACCOUNT }));

    await user.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: DELETE_ACCOUNT }));

    expect(await screen.findByText(t("provisional.account.broadcastInProgress.title"))).toBeInTheDocument();
    expect(screen.queryByRole("alertdialog")).toBeNull();
    expect(mockReplace).not.toHaveBeenCalled();
    consoleError.mockRestore();
  });

  it("契約に無い失敗（500）: ダイアログは開いたまま、失敗の通知を中に出す。ランディングへは移らない", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    renderAccount({ handlers: { deleteAccount: () => jsonResponse(500, { error: { code: "internal_error" } }) } });
    await loaded();
    await user.click(screen.getByRole("button", { name: DELETE_ACCOUNT }));

    await user.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: DELETE_ACCOUNT }));

    expect(await within(screen.getByRole("alertdialog")).findByRole("alert")).toHaveTextContent(t("provisional.error.notice.title"));
    expect(mockReplace).not.toHaveBeenCalled();
    consoleError.mockRestore();
  });

  it("ネイティブの confirm・alert を、使わない（削除の流れの全体で）", async () => {
    const user = userEvent.setup();
    const nativeConfirm = jest.spyOn(window, "confirm").mockImplementation(() => true);
    const nativeAlert = jest.spyOn(window, "alert").mockImplementation(() => undefined);
    renderAccount();
    await loaded();

    await user.click(screen.getByRole("button", { name: DELETE_ACCOUNT }));
    await user.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: DELETE_ACCOUNT }));
    await waitFor(() => expect(mockReplace).toHaveBeenCalled());

    expect(nativeConfirm).not.toHaveBeenCalled();
    expect(nativeAlert).not.toHaveBeenCalled();
    nativeConfirm.mockRestore();
    nativeAlert.mockRestore();
  });
});

describe("アカウント画面: ログアウト", () => {
  it("押すと、POST /api/auth/logout を CSRF つきで呼び、成功したら、ランディング（/）へ移る。処理中は、進行形の文言", async () => {
    const user = userEvent.setup();
    let release: () => void = () => undefined;
    const { calls } = renderAccount({
      handlers: {
        logout: () =>
          new Promise((resolve) => {
            release = () => resolve(emptyResponse(204));
          }),
      },
    });
    await loaded();

    await user.click(screen.getByRole("button", { name: LOGOUT }));

    const busy = await screen.findByRole("button", { name: t("provisional.account.logout.busy") });
    expect(busy).toHaveAttribute("aria-busy", "true");
    await act(async () => release());

    await waitFor(() => expect(mockReplace).toHaveBeenCalledWith("/"));
    const request = calls.find((call) => call.url === "/api/auth/logout");
    expect(request?.init.method).toBe("POST");
    expect(headerOf(request, "x-csrf-token")).toBe(DUMMY_CSRF_TOKEN);
  });

  it("401（すでにセッションが無い）でも、ランディングへ移る", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    renderAccount({ handlers: { logout: () => jsonResponse(401, { error: { code: "not_logged_in" } }) } });
    await loaded();

    await user.click(screen.getByRole("button", { name: LOGOUT }));

    await waitFor(() => expect(mockReplace).toHaveBeenCalledWith("/"));
    consoleError.mockRestore();
  });

  it("契約に無い失敗（500）: 失敗の通知（エラー）を出し、ランディングへは移らない。ボタンを元に戻す", async () => {
    const user = userEvent.setup();
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    renderAccount({ handlers: { logout: () => jsonResponse(500, { error: { code: "internal_error" } }) } });
    await loaded();

    await user.click(screen.getByRole("button", { name: LOGOUT }));

    expect(await screen.findByRole("alert")).toHaveTextContent(t("provisional.error.notice.title"));
    expect(mockReplace).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: LOGOUT })).not.toHaveAttribute("aria-busy");
    consoleError.mockRestore();
  });
});

describe("アカウント画面: キーボード操作", () => {
  it("すべての操作（再確認・再接続・接続を解除・アカウントを削除・ログアウト）へ、Tab で到達できる", async () => {
    const user = userEvent.setup();
    renderAccount();
    await loaded();

    const reached: string[] = [];
    for (let index = 0; index < 8; index += 1) {
      await user.tab();
      const active = document.activeElement;
      if (active instanceof HTMLButtonElement || active instanceof HTMLAnchorElement) {
        reached.push(active.textContent ?? "");
      }
    }

    for (const label of [
      t("provisional.account.youtube.actions.recheck"),
      t("provisional.account.youtube.actions.reconnect"),
      DISCONNECT,
      DELETE_ACCOUNT,
      LOGOUT,
    ]) {
      expect(reached.some((text) => text.includes(label))).toBe(true);
    }
  });

  it("ログアウトのボタンは、Enter で操作できる", async () => {
    const user = userEvent.setup();
    renderAccount();
    await loaded();

    screen.getByRole("button", { name: LOGOUT }).focus();
    await user.keyboard("{Enter}");

    await waitFor(() => expect(mockReplace).toHaveBeenCalledWith("/"));
  });
});
