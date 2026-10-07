// アカウント画面のテストの共通部品。テストからだけ使う（実行時のコードから import しない）。
// バックエンドの API は、契約どおりの疑似の応答（fetch の疑似）。bot 判定・遷移は、関数の疑似。
import { render } from "@testing-library/react";
import type { ConnectResult } from "@/core/contract";
import { ApiClient } from "@/lib/api";
import {
  authenticatedState,
  createFakeFetch,
  DUMMY_AUTHORIZATION_URL,
  DUMMY_RECAPTCHA_TOKEN,
  emptyResponse,
  jsonResponse,
  UNAUTHENTICATED_STATE,
  type FakeCall,
  type FakeRespond,
} from "@/lib/api/test-support";
import { RecaptchaProvider, type RecaptchaTokenSource } from "@/lib/recaptcha";
import { AccountScreen } from "./AccountScreen";

export const DUMMY_CHANNEL_TITLE = "dummy-channel-title";

/** ログイン済みの状態の応答。YouTube の接続は、既定で、接続済み（チャンネル名つき） */
export function stateWith(youtube: Record<string, unknown> = {}, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return authenticatedState({
    youtube: { state: "connected", channel_title: DUMMY_CHANNEL_TITLE, can_recheck_at: null, ...youtube },
    ...extra,
  });
}

export type BackendHandlerName = "recheck" | "connect" | "disconnect" | "deleteAccount" | "logout";

export interface AccountHarnessOptions {
  initialConnectResult?: ConnectResult | null;
  /** GET /api/state の応答。配列なら、呼ぶたびに、順に返す（最後の値を、以後も返す） */
  state?: Record<string, unknown> | ReadonlyArray<Record<string, unknown>>;
  /** 各 API の応答（既定は、成功） */
  handlers?: Partial<Record<BackendHandlerName, FakeRespond>>;
  getToken?: () => Promise<string>;
  now?: () => number;
  /** 通信そのものを失敗させる（getState を含む） */
  failAll?: boolean;
  /** GET /api/state の応答を、この Promise が解決するまで、返さない（取得中の状態を作る） */
  stateGate?: Promise<void>;
}

export interface AccountHarness {
  readonly calls: FakeCall[];
  readonly navigate: jest.Mock;
  readonly recaptcha: { getToken: jest.Mock };
  readonly unmount: () => void;
}

const DEFAULT_HANDLERS: Record<BackendHandlerName, FakeRespond> = {
  recheck: () => jsonResponse(200, { youtube: { state: "connected", channel_title: null, can_recheck_at: null } }),
  connect: () => jsonResponse(200, { authorization_url: DUMMY_AUTHORIZATION_URL }),
  disconnect: () => jsonResponse(200, { youtube: { state: "not_connected", channel_title: null, can_recheck_at: null } }),
  deleteAccount: () => emptyResponse(204),
  logout: () => emptyResponse(204),
};

/** 経路ごとの応答を返す、バックエンドの疑似 */
export function createBackend(options: AccountHarnessOptions): { fetch: ReturnType<typeof createFakeFetch>["fetch"]; calls: FakeCall[] } {
  const states = Array.isArray(options.state) ? options.state : [options.state ?? stateWith()];
  let stateCalls = 0;
  const handlers = { ...DEFAULT_HANDLERS, ...options.handlers };
  const fake = createFakeFetch((url, init) => {
    if (options.failAll === true) {
      return Promise.reject(new TypeError("fetch failed"));
    }
    if (url.startsWith("/api/state")) {
      const index = Math.min(stateCalls, states.length - 1);
      stateCalls += 1;
      const response = jsonResponse(200, states[index]);
      return options.stateGate === undefined ? response : options.stateGate.then(() => response);
    }
    const routes: Array<[string, string, BackendHandlerName]> = [
      ["POST", "/api/youtube/recheck", "recheck"],
      ["POST", "/api/youtube/connect/start", "connect"],
      ["POST", "/api/youtube/disconnect", "disconnect"],
      ["DELETE", "/api/account", "deleteAccount"],
      ["POST", "/api/auth/logout", "logout"],
    ];
    const route = routes.find(([method, path]) => init.method === method && url === path);
    if (route === undefined) {
      return jsonResponse(404, { error: { code: "not_found" } });
    }
    return handlers[route[2]](url, init);
  });
  return fake;
}

export function renderAccount(options: AccountHarnessOptions = {}): AccountHarness {
  const backend = createBackend(options);
  const client = new ApiClient({ fetch: backend.fetch });
  const navigate = jest.fn();
  const recaptcha = { getToken: jest.fn(options.getToken ?? (async () => DUMMY_RECAPTCHA_TOKEN)) };
  const view = render(
    <RecaptchaProvider siteKey={null} client={recaptcha as RecaptchaTokenSource}>
      <AccountScreen
        initialConnectResult={options.initialConnectResult ?? null}
        client={client}
        navigate={navigate}
        {...(options.now === undefined ? {} : { now: options.now })}
      />
    </RecaptchaProvider>,
  );
  return { calls: backend.calls, navigate, recaptcha, unmount: view.unmount };
}

export { UNAUTHENTICATED_STATE };
