/**
 * @jest-environment node
 */
import { ApiClient } from "./client";
import {
  ApiAbortedError,
  ApiError,
  ApiNetworkError,
  ApiRejected,
  ApiTimeoutError,
  CsrfInvalidError,
  MissingCsrfTokenError,
  NotLoggedInError,
  UnexpectedResponse,
} from "./errors";
import {
  authenticatedState,
  BROADCAST_VIEW,
  createFakeFetch,
  DUMMY_AUTHORIZATION_URL,
  DUMMY_BROADCAST_ID,
  DUMMY_CSRF_TOKEN,
  DUMMY_RECAPTCHA_TOKEN,
  emptyResponse,
  headerOf,
  jsonResponse,
  START_ACCEPTED,
  textResponse,
  UNAUTHENTICATED_STATE,
  YOUTUBE_VIEW,
  type FakeCall,
} from "./test-support";

// API クライアント（ブラウザ → 同一オリジンの /api/*）。fetch を注入して、本物のバックエンドを呼ばずに検査する。

function loggedInClient(respond: Parameters<typeof createFakeFetch>[0]): { client: ApiClient; calls: FakeCall[] } {
  const fake = createFakeFetch((url, init) => {
    if (url === "/api/state") {
      return jsonResponse(200, authenticatedState());
    }
    return respond(url, init);
  });
  return { client: new ApiClient({ fetch: fake.fetch }), calls: fake.calls };
}

async function loggedIn(respond: Parameters<typeof createFakeFetch>[0]): Promise<{ client: ApiClient; calls: FakeCall[] }> {
  const context = loggedInClient(respond);
  await context.client.getState();
  context.calls.length = 0;
  return context;
}

async function errorOf(promise: Promise<unknown>): Promise<unknown> {
  try {
    await promise;
  } catch (error) {
    return error;
  }
  throw new Error("an error was expected, but the call succeeded");
}

describe("ApiClient: 共通の規約（ヘッダ・本文・CSRF）", () => {
  it("GET は、Accept と no-store・同一オリジンの資格情報で送り、X-BL-Client・本文を付けない", async () => {
    const { fetch, calls } = createFakeFetch(() => jsonResponse(200, UNAUTHENTICATED_STATE));
    const client = new ApiClient({ fetch });

    await client.getState();

    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("/api/state");
    expect(calls[0].init.method).toBe("GET");
    expect(headerOf(calls[0], "accept")).toBe("application/json");
    expect(headerOf(calls[0], "x-bl-client")).toBeUndefined();
    expect(headerOf(calls[0], "content-type")).toBeUndefined();
    expect(calls[0].init.body).toBeUndefined();
    expect(calls[0].init.cache).toBe("no-store");
    expect(calls[0].init.credentials).toBe("same-origin");
    expect(calls[0].init.signal).toBeInstanceOf(AbortSignal);
  });

  it("getState({ withChannel: true }) は、クエリ with_channel=1 を付ける", async () => {
    const { fetch, calls } = createFakeFetch(() => jsonResponse(200, UNAUTHENTICATED_STATE));
    const client = new ApiClient({ fetch });

    await client.getState({ withChannel: true });
    await client.getState({ withChannel: false });

    expect(calls[0].url).toBe("/api/state?with_channel=1");
    expect(calls[1].url).toBe("/api/state");
  });

  it("状態を変える要求（POST・DELETE）に、X-BL-Client: web と、本文のあるときだけ Content-Type を付ける", async () => {
    const { client, calls } = await loggedIn(() => emptyResponse(204));

    // logout は、成功するとトークンを捨てるため、最後に呼ぶ
    await client.postUsageEvent({ event_type: "watch_url_copied" });
    await client.logout();

    expect(headerOf(calls[0], "x-bl-client")).toBe("web");
    expect(headerOf(calls[0], "content-type")).toBe("application/json; charset=utf-8");
    expect(headerOf(calls[1], "x-bl-client")).toBe("web");
    expect(headerOf(calls[1], "content-type")).toBeUndefined();
    expect(calls[1].init.body).toBeUndefined();
  });

  it("ログイン済みの getState で受け取った csrf_token を、状態を変える要求の X-CSRF-Token へ付ける", async () => {
    const { client, calls } = await loggedIn(() => emptyResponse(204));

    await client.logout();

    expect(headerOf(calls[0], "x-csrf-token")).toBe(DUMMY_CSRF_TOKEN);
  });

  it("GET には、X-CSRF-Token を付けない（副作用が無く、CSRF の対象外）", async () => {
    const { client, calls } = await loggedIn(() => jsonResponse(200, { broadcast: BROADCAST_VIEW }));

    await client.getBroadcast(DUMMY_BROADCAST_ID);

    expect(headerOf(calls[0], "x-csrf-token")).toBeUndefined();
  });

  it("ログインが要る操作は、csrf_token が無ければ、要求を送らずに MissingCsrfTokenError", async () => {
    const { fetch, calls } = createFakeFetch(() => emptyResponse(204));
    const client = new ApiClient({ fetch });

    await expect(client.logout()).rejects.toBeInstanceOf(MissingCsrfTokenError);
    await expect(client.deleteAccount()).rejects.toBeInstanceOf(MissingCsrfTokenError);
    await expect(client.recheckYouTube()).rejects.toBeInstanceOf(MissingCsrfTokenError);
    await expect(client.disconnectYouTube()).rejects.toBeInstanceOf(MissingCsrfTokenError);
    await expect(client.startYouTubeConnect(DUMMY_RECAPTCHA_TOKEN)).rejects.toBeInstanceOf(MissingCsrfTokenError);
    await expect(client.reissueTicket(DUMMY_BROADCAST_ID)).rejects.toBeInstanceOf(MissingCsrfTokenError);
    await expect(client.stopBroadcast(DUMMY_BROADCAST_ID)).rejects.toBeInstanceOf(MissingCsrfTokenError);
    await expect(client.cancelBroadcast(DUMMY_BROADCAST_ID, "user_cancel")).rejects.toBeInstanceOf(MissingCsrfTokenError);
    await expect(client.postUsageEvent({ event_type: "watch_url_copied" })).rejects.toBeInstanceOf(MissingCsrfTokenError);
    expect(calls).toHaveLength(0);
  });

  it("ログイン前でも呼べる操作（startLogin）は、token が無くても、X-BL-Client だけで送る。token があれば付ける（ログイン済みで押されても 403 にならない）", async () => {
    const { fetch, calls } = createFakeFetch((url) =>
      url === "/api/state" ? jsonResponse(200, authenticatedState()) : jsonResponse(200, { authorization_url: DUMMY_AUTHORIZATION_URL }),
    );
    const client = new ApiClient({ fetch });

    await client.startLogin(DUMMY_RECAPTCHA_TOKEN);
    await client.getState();
    await client.startLogin(DUMMY_RECAPTCHA_TOKEN);

    expect(headerOf(calls[0], "x-bl-client")).toBe("web");
    expect(headerOf(calls[0], "x-csrf-token")).toBeUndefined();
    expect(headerOf(calls[2], "x-csrf-token")).toBe(DUMMY_CSRF_TOKEN);
  });

  it("未ログインの getState は、保持している csrf_token を捨てる", async () => {
    let loggedInNow = true;
    const { fetch } = createFakeFetch(() => jsonResponse(200, loggedInNow ? authenticatedState() : UNAUTHENTICATED_STATE));
    const client = new ApiClient({ fetch });

    await client.getState();
    expect(client.hasCsrfToken).toBe(true);
    loggedInNow = false;
    await client.getState();

    expect(client.hasCsrfToken).toBe(false);
  });

  it("ログアウトとアカウントの削除が成功したら、csrf_token を捨てる", async () => {
    const first = await loggedIn(() => emptyResponse(204));
    await first.client.logout();
    const second = await loggedIn(() => emptyResponse(204));
    await second.client.deleteAccount();

    expect(first.client.hasCsrfToken).toBe(false);
    expect(second.client.hasCsrfToken).toBe(false);
  });

  it("失敗したログアウトでは、csrf_token を捨てない（セッションは、まだ有効）", async () => {
    const { client } = await loggedIn(() => jsonResponse(503, { error: { code: "internal_error" } }));

    await errorOf(client.logout());

    expect(client.hasCsrfToken).toBe(true);
  });

  it("401（セッション切れ）を受け取ったら、csrf_token を捨てる", async () => {
    const { client } = await loggedIn(() => jsonResponse(401, { error: { code: "not_logged_in" } }));

    await errorOf(client.recheckYouTube());

    expect(client.hasCsrfToken).toBe(false);
  });

  it("csrf_token を、メモリにだけ持つ（オブジェクトの列挙・JSON 化に現れない）", async () => {
    const { client } = await loggedIn(() => emptyResponse(204));

    expect(JSON.stringify(client)).not.toContain(DUMMY_CSRF_TOKEN);
    expect(Object.values(client)).not.toContain(DUMMY_CSRF_TOKEN);
  });
});

describe("ApiClient: 各エンドポイント（契約 3 章）", () => {
  it("getState: ログイン済みの応答を、型どおりに返す", async () => {
    const { fetch } = createFakeFetch(() => jsonResponse(200, authenticatedState({ broadcast: { ...BROADCAST_VIEW } })));
    const client = new ApiClient({ fetch });

    const state = await client.getState({ withChannel: true });

    expect(state.authenticated).toBe(true);
    expect(state.authenticated && state.broadcast?.id).toBe(DUMMY_BROADCAST_ID);
  });

  it("startLogin: POST /api/auth/login/start に recaptcha_token を送り、認可 URL を返す", async () => {
    const { fetch, calls } = createFakeFetch(() => jsonResponse(200, { authorization_url: DUMMY_AUTHORIZATION_URL }));
    const client = new ApiClient({ fetch });

    const result = await client.startLogin(DUMMY_RECAPTCHA_TOKEN);

    expect(calls[0].url).toBe("/api/auth/login/start");
    expect(calls[0].init.method).toBe("POST");
    expect(JSON.parse(calls[0].init.body ?? "")).toEqual({ recaptcha_token: DUMMY_RECAPTCHA_TOKEN });
    expect(result).toEqual({ authorization_url: DUMMY_AUTHORIZATION_URL });
  });

  it("logout: POST /api/auth/logout（204）", async () => {
    const { client, calls } = await loggedIn(() => emptyResponse(204));

    await expect(client.logout()).resolves.toBeUndefined();

    expect(calls[0].url).toBe("/api/auth/logout");
    expect(calls[0].init.method).toBe("POST");
  });

  it("startYouTubeConnect: POST /api/youtube/connect/start に recaptcha_token を送り、認可 URL を返す", async () => {
    const { client, calls } = await loggedIn(() => jsonResponse(200, { authorization_url: DUMMY_AUTHORIZATION_URL }));

    const result = await client.startYouTubeConnect(DUMMY_RECAPTCHA_TOKEN);

    expect(calls[0].url).toBe("/api/youtube/connect/start");
    expect(JSON.parse(calls[0].init.body ?? "")).toEqual({ recaptcha_token: DUMMY_RECAPTCHA_TOKEN });
    expect(result.authorization_url).toBe(DUMMY_AUTHORIZATION_URL);
  });

  it("recheckYouTube: POST /api/youtube/recheck。youtube（接続状態・再確認できる時刻）を返す", async () => {
    const youtube = { ...YOUTUBE_VIEW, can_recheck_at: "2026-10-07T13:31:00+09:00" };
    const { client, calls } = await loggedIn(() => jsonResponse(200, { youtube }));

    await expect(client.recheckYouTube()).resolves.toEqual(youtube);

    expect(calls[0].url).toBe("/api/youtube/recheck");
    expect(calls[0].init.method).toBe("POST");
    expect(calls[0].init.body).toBeUndefined();
  });

  it("disconnectYouTube: POST /api/youtube/disconnect。未接続の youtube を返す", async () => {
    const youtube = { state: "not_connected", channel_title: null, can_recheck_at: null };
    const { client, calls } = await loggedIn(() => jsonResponse(200, { youtube }));

    await expect(client.disconnectYouTube()).resolves.toEqual(youtube);

    expect(calls[0].url).toBe("/api/youtube/disconnect");
  });

  it("deleteAccount: DELETE /api/account（204）", async () => {
    const { client, calls } = await loggedIn(() => emptyResponse(204));

    await expect(client.deleteAccount()).resolves.toBeUndefined();

    expect(calls[0].url).toBe("/api/account");
    expect(calls[0].init.method).toBe("DELETE");
  });

  it("requestStart: POST /api/broadcasts に 4 項目を送り、受理（201）を返す", async () => {
    const { client, calls } = await loggedIn(() => jsonResponse(201, START_ACCEPTED));
    const request = { title: "dummy title", privacy_status: "unlisted", made_for_kids: false, recaptcha_token: DUMMY_RECAPTCHA_TOKEN } as const;

    const accepted = await client.requestStart(request);

    expect(calls[0].url).toBe("/api/broadcasts");
    expect(JSON.parse(calls[0].init.body ?? "")).toEqual(request);
    expect(accepted.broadcast.state).toBe("reserved");
    expect(accepted.ticket).toBe(START_ACCEPTED.ticket);
    expect(accepted.limits.profiles["480p"].line_threshold_kbps).toBe(1200);
  });

  it("requestStart: ログインしていなくても、token 無しで要求を送る（サーバーが、拒否 not_logged_in を返す）", async () => {
    const { fetch, calls } = createFakeFetch(() =>
      jsonResponse(401, { rejected: { reason: "not_logged_in", resolution: "log_in", retry_at: null } }),
    );
    const client = new ApiClient({ fetch });

    const error = await errorOf(
      client.requestStart({ title: "t", privacy_status: "unlisted", made_for_kids: false, recaptcha_token: DUMMY_RECAPTCHA_TOKEN }),
    );

    expect(calls).toHaveLength(1);
    expect(headerOf(calls[0], "x-csrf-token")).toBeUndefined();
    expect(error).toBeInstanceOf(ApiRejected);
  });

  it("reissueTicket: POST /api/broadcasts/:id/ticket。ticket と relay_url を返す", async () => {
    const { client, calls } = await loggedIn(() => jsonResponse(200, { ticket: "dummy-ticket", relay_url: "ws://localhost:3002/ws" }));

    await expect(client.reissueTicket(DUMMY_BROADCAST_ID)).resolves.toEqual({ ticket: "dummy-ticket", relay_url: "ws://localhost:3002/ws" });

    expect(calls[0].url).toBe(`/api/broadcasts/${DUMMY_BROADCAST_ID}/ticket`);
    expect(calls[0].init.method).toBe("POST");
  });

  it("stopBroadcast: POST /api/broadcasts/:id/stop。broadcast を返す", async () => {
    const { client, calls } = await loggedIn(() => jsonResponse(200, { broadcast: { ...BROADCAST_VIEW, state: "ended", end_reason: "user_stop" } }));

    const broadcast = await client.stopBroadcast(DUMMY_BROADCAST_ID);

    expect(calls[0].url).toBe(`/api/broadcasts/${DUMMY_BROADCAST_ID}/stop`);
    expect(broadcast.end_reason).toBe("user_stop");
  });

  it.each(["user_cancel", "insufficient_bandwidth"] as const)("cancelBroadcast: POST /api/broadcasts/:id/cancel に reason=%s を送る", async (reason) => {
    const { client, calls } = await loggedIn(() => jsonResponse(200, { broadcast: { ...BROADCAST_VIEW, state: "ended", end_reason: reason } }));

    const broadcast = await client.cancelBroadcast(DUMMY_BROADCAST_ID, reason);

    expect(calls[0].url).toBe(`/api/broadcasts/${DUMMY_BROADCAST_ID}/cancel`);
    expect(JSON.parse(calls[0].init.body ?? "")).toEqual({ reason });
    expect(broadcast.end_reason).toBe(reason);
  });

  it("getBroadcast: GET /api/broadcasts/:id。broadcast を返す", async () => {
    const { client, calls } = await loggedIn(() => jsonResponse(200, { broadcast: { ...BROADCAST_VIEW } }));

    await expect(client.getBroadcast(DUMMY_BROADCAST_ID)).resolves.toEqual(BROADCAST_VIEW);

    expect(calls[0].url).toBe(`/api/broadcasts/${DUMMY_BROADCAST_ID}`);
    expect(calls[0].init.method).toBe("GET");
  });

  it("postUsageEvent: POST /api/usage-events に、イベントをそのまま送る（204）", async () => {
    const { client, calls } = await loggedIn(() => emptyResponse(204));
    const event = { event_type: "line_measured", value: 5200, browser_class: { family: "chromium", supported: true } } as const;

    await expect(client.postUsageEvent(event)).resolves.toBeUndefined();

    expect(calls[0].url).toBe("/api/usage-events");
    expect(JSON.parse(calls[0].init.body ?? "")).toEqual(event);
  });

  it("配信の識別子は、経路へ入れる前にエンコードする（区切り・.. を経路へ持ち込まない）", async () => {
    const { client, calls } = await loggedIn(() => jsonResponse(200, { broadcast: { ...BROADCAST_VIEW } }));

    await client.getBroadcast("../account");
    await client.getBroadcast("a/b?c#d");

    expect(calls[0].url).toBe("/api/broadcasts/..%2Faccount");
    expect(calls[1].url).toBe("/api/broadcasts/a%2Fb%3Fc%23d");
  });

  it("配信の識別子が空なら、要求を送らずに、RangeError", async () => {
    const { client, calls } = await loggedIn(() => jsonResponse(200, { broadcast: { ...BROADCAST_VIEW } }));

    await expect(client.getBroadcast("")).rejects.toBeInstanceOf(RangeError);
    await expect(client.stopBroadcast("")).rejects.toBeInstanceOf(RangeError);
    expect(calls).toHaveLength(0);
  });
});

describe("ApiClient: エラー（{error:{code}}）", () => {
  it("401 not_logged_in は NotLoggedInError（ApiError でもある）", async () => {
    const { client } = await loggedIn(() => jsonResponse(401, { error: { code: "not_logged_in" } }));

    const error = await errorOf(client.logout());

    expect(error).toBeInstanceOf(NotLoggedInError);
    expect(error).toBeInstanceOf(ApiError);
    expect((error as NotLoggedInError).status).toBe(401);
    expect((error as NotLoggedInError).code).toBe("not_logged_in");
  });

  it("403 csrf_invalid は CsrfInvalidError", async () => {
    const { client } = await loggedIn(() => jsonResponse(403, { error: { code: "csrf_invalid" } }));

    const error = await errorOf(client.recheckYouTube());

    expect(error).toBeInstanceOf(CsrfInvalidError);
    expect((error as CsrfInvalidError).status).toBe(403);
  });

  it("403 bot_check_failed は、CsrfInvalidError ではない通常の ApiError", async () => {
    const { fetch } = createFakeFetch(() => jsonResponse(403, { error: { code: "bot_check_failed" } }));
    const client = new ApiClient({ fetch });

    const error = await errorOf(client.startLogin(DUMMY_RECAPTCHA_TOKEN));

    expect(error).toBeInstanceOf(ApiError);
    expect(error).not.toBeInstanceOf(CsrfInvalidError);
    expect((error as ApiError).code).toBe("bot_check_failed");
  });

  it("429 rate_limited は、再試行の目安時刻（details.retry_at）を持つ", async () => {
    const { fetch } = createFakeFetch(() =>
      jsonResponse(429, { error: { code: "rate_limited", details: { retry_at: "2026-10-07T14:30:00+09:00" } } }),
    );
    const client = new ApiClient({ fetch });

    const error = (await errorOf(client.startLogin(DUMMY_RECAPTCHA_TOKEN))) as ApiError;

    expect(error.code).toBe("rate_limited");
    expect(error.status).toBe(429);
    expect(error.retryAt).toBe("2026-10-07T14:30:00+09:00");
  });

  it("details.retry_at が無い・文字列でないときの retryAt は null（時刻を、別の値で補わない）", async () => {
    const { fetch } = createFakeFetch(() => jsonResponse(429, { error: { code: "rate_limited", details: { retry_at: 5 } } }));
    const client = new ApiClient({ fetch });

    const error = (await errorOf(client.startLogin(DUMMY_RECAPTCHA_TOKEN))) as ApiError;

    expect(error.retryAt).toBeNull();
  });

  it("409 broadcast_ended は、終了理由（details.end_reason）を持つ", async () => {
    const { client } = await loggedIn(() => jsonResponse(409, { error: { code: "broadcast_ended", details: { end_reason: "time_limit" } } }));

    const error = (await errorOf(client.reissueTicket(DUMMY_BROADCAST_ID))) as ApiError;

    expect(error.code).toBe("broadcast_ended");
    expect(error.endReason).toBe("time_limit");
  });

  it("422 invalid_input は、不備のある項目名（details.fields）を持つ", async () => {
    const { client } = await loggedIn(() => jsonResponse(422, { error: { code: "invalid_input", details: { fields: ["recaptcha_token"] } } }));

    const error = (await errorOf(client.startYouTubeConnect(DUMMY_RECAPTCHA_TOKEN))) as ApiError;

    expect(error.fields).toEqual(["recaptcha_token"]);
  });

  it.each([
    ["409 broadcast_in_progress", 409, "broadcast_in_progress"],
    ["409 not_connected", 409, "not_connected"],
    ["503 unverifiable", 503, "unverifiable"],
    ["404 not_found", 404, "not_found"],
    ["500 internal_error", 500, "internal_error"],
    ["502 bad_gateway（BFF が返す）", 502, "bad_gateway"],
    ["403 forbidden", 403, "forbidden"],
  ] as const)("%s は ApiError（符号とステータスを持つ）", async (_title, status, code) => {
    const { client } = await loggedIn(() => jsonResponse(status, { error: { code } }));

    const error = (await errorOf(client.disconnectYouTube())) as ApiError;

    expect(error).toBeInstanceOf(ApiError);
    expect(error.status).toBe(status);
    expect(error.code).toBe(code);
  });

  it("未知のエラー符号は、UnexpectedResponse（成功にも、既知のエラーにもしない）", async () => {
    const { client } = await loggedIn(() => jsonResponse(500, { error: { code: "made_up_code" } }));

    const error = await errorOf(client.disconnectYouTube());

    expect(error).toBeInstanceOf(UnexpectedResponse);
    expect((error as UnexpectedResponse).status).toBe(500);
  });

  it("JSON でないエラーの応答（バックエンドの HTML の 404 など）は、UnexpectedResponse", async () => {
    const { fetch } = createFakeFetch(() => textResponse(404, "<!DOCTYPE html><html><body>Routing Error</body></html>", "text/html; charset=utf-8"));
    const client = new ApiClient({ fetch });

    const error = await errorOf(client.getState());

    expect(error).toBeInstanceOf(UnexpectedResponse);
    expect((error as UnexpectedResponse).status).toBe(404);
    expect((error as UnexpectedResponse).message).not.toContain("Routing Error");
  });

  it("本文が空のエラー（404 など）は、UnexpectedResponse", async () => {
    const { fetch } = createFakeFetch(() => emptyResponse(404));
    const client = new ApiClient({ fetch });

    await expect(client.getState()).rejects.toBeInstanceOf(UnexpectedResponse);
  });

  it("エラーの形でない JSON（{error} も {rejected} も無い）は、UnexpectedResponse", async () => {
    const { fetch } = createFakeFetch(() => jsonResponse(500, { message: "oops" }));
    const client = new ApiClient({ fetch });

    await expect(client.getState()).rejects.toBeInstanceOf(UnexpectedResponse);
  });
});

describe("ApiClient: 受付の拒否（{rejected}）と通常のエラー（{error}）の区別", () => {
  const request = { title: "t", privacy_status: "unlisted", made_for_kids: false, recaptcha_token: DUMMY_RECAPTCHA_TOKEN } as const;

  it("requestStart の 409 {rejected} は ApiRejected（理由・区分・再試行の目安時刻・HTTP ステータス）", async () => {
    const { client } = await loggedIn(() =>
      jsonResponse(409, { rejected: { reason: "allowance_consumed", resolution: "next_usage_day", retry_at: "2026-10-08T03:00:00+09:00" } }),
    );

    const error = await errorOf(client.requestStart(request));

    expect(error).toBeInstanceOf(ApiRejected);
    expect(error).not.toBeInstanceOf(ApiError);
    const rejected = error as ApiRejected;
    expect(rejected.status).toBe(409);
    expect(rejected.reason).toBe("allowance_consumed");
    expect(rejected.resolution).toBe("next_usage_day");
    expect(rejected.retryAt).toBe("2026-10-08T03:00:00+09:00");
    expect(rejected.fields).toBeNull();
  });

  it("422 invalid_input の {rejected} は、fields を持つ", async () => {
    const { client } = await loggedIn(() =>
      jsonResponse(422, { rejected: { reason: "invalid_input", resolution: "fix_input", retry_at: null, fields: ["title"] } }),
    );

    const rejected = (await errorOf(client.requestStart(request))) as ApiRejected;

    expect(rejected.fields).toEqual(["title"]);
    expect(rejected.retryAt).toBeNull();
  });

  it("requestStart でも、{error} の形（403 csrf_invalid など）は、ApiRejected にしない", async () => {
    const { client } = await loggedIn(() => jsonResponse(403, { error: { code: "csrf_invalid" } }));

    await expect(client.requestStart(request)).rejects.toBeInstanceOf(CsrfInvalidError);
  });

  it("requestStart 以外の API が {rejected} を返したら、UnexpectedResponse（契約に無い形）", async () => {
    const { client } = await loggedIn(() =>
      jsonResponse(409, { rejected: { reason: "capacity_full", resolution: "wait", retry_at: null } }),
    );

    await expect(client.recheckYouTube()).rejects.toBeInstanceOf(UnexpectedResponse);
  });

  it("未知の拒否理由は、UnexpectedResponse", async () => {
    const { client } = await loggedIn(() => jsonResponse(409, { rejected: { reason: "mystery", resolution: "wait", retry_at: null } }));

    await expect(client.requestStart(request)).rejects.toBeInstanceOf(UnexpectedResponse);
  });
});

describe("ApiClient: 不明な応答を、成功にしない（フォールバック禁止）", () => {
  it("200 の応答が JSON でない（HTML）なら、UnexpectedResponse", async () => {
    const { fetch } = createFakeFetch(() => textResponse(200, "<html></html>", "text/html"));
    const client = new ApiClient({ fetch });

    await expect(client.getState()).rejects.toBeInstanceOf(UnexpectedResponse);
  });

  it("Content-Type が無い応答は、UnexpectedResponse", async () => {
    const { fetch } = createFakeFetch(() => ({ status: 200, headers: { get: () => null }, text: async () => "{}" }));
    const client = new ApiClient({ fetch });

    await expect(client.getState()).rejects.toBeInstanceOf(UnexpectedResponse);
  });

  it("JSON として壊れた本文は、UnexpectedResponse", async () => {
    const { fetch } = createFakeFetch(() => textResponse(200, "{not json", "application/json"));
    const client = new ApiClient({ fetch });

    await expect(client.getState()).rejects.toBeInstanceOf(UnexpectedResponse);
  });

  it("契約の形に合わない JSON は、UnexpectedResponse（位置だけを持つ。値を含めない）", async () => {
    const { fetch } = createFakeFetch(() => jsonResponse(200, { authenticated: true, csrf_token: "dummy-secret-csrf", usage: "x" }));
    const client = new ApiClient({ fetch });

    const error = (await errorOf(client.getState())) as UnexpectedResponse;

    expect(error).toBeInstanceOf(UnexpectedResponse);
    expect(error.message).toContain("usage");
    expect(error.message).not.toContain("dummy-secret-csrf");
  });

  it("成功のステータスが、契約と違えば（getState が 201・logout が 200）、UnexpectedResponse", async () => {
    const wrongGet = createFakeFetch(() => jsonResponse(201, UNAUTHENTICATED_STATE));
    const wrongLogout = await loggedIn(() => jsonResponse(200, {}));

    await expect(new ApiClient({ fetch: wrongGet.fetch }).getState()).rejects.toBeInstanceOf(UnexpectedResponse);
    await expect(wrongLogout.client.logout()).rejects.toBeInstanceOf(UnexpectedResponse);
  });

  it("204 のはずの応答が本文を持っていても、成功とする（本文は、使わない）", async () => {
    const { client } = await loggedIn(() => textResponse(204, "ignored", "text/plain"));

    await expect(client.logout()).resolves.toBeUndefined();
  });

  it("ログイン済みの getState の失敗（不正な形）は、保持している csrf_token を変えない", async () => {
    const respond = jest.fn<ReturnType<Parameters<typeof createFakeFetch>[0]>, Parameters<Parameters<typeof createFakeFetch>[0]>>();
    respond.mockReturnValueOnce(jsonResponse(200, authenticatedState()));
    respond.mockReturnValueOnce(jsonResponse(200, { authenticated: "maybe" }));
    const { fetch } = createFakeFetch(respond);
    const client = new ApiClient({ fetch });

    await client.getState();
    await errorOf(client.getState());

    expect(client.hasCsrfToken).toBe(true);
  });
});

describe("ApiClient: 通信の失敗・時間切れ・中断", () => {
  it("fetch が失敗したら ApiNetworkError（原因を cause に持つ）", async () => {
    const cause = new TypeError("fetch failed");
    const { fetch } = createFakeFetch(() => Promise.reject(cause));
    const client = new ApiClient({ fetch });

    const error = await errorOf(client.getState());

    expect(error).toBeInstanceOf(ApiNetworkError);
    expect((error as ApiNetworkError).cause).toBe(cause);
  });

  it("応答が来なければ、設定の時間（timeoutMs）で ApiTimeoutError", async () => {
    const { fetch, calls } = createFakeFetch(
      (_url, init) =>
        new Promise((_resolve, reject) => {
          init.signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
        }),
    );
    const client = new ApiClient({ fetch, timeoutMs: 30 });

    await expect(client.getState()).rejects.toBeInstanceOf(ApiTimeoutError);
    expect(calls[0].init.signal.aborted).toBe(true);
  });

  it("既定の待ち時間は、中継（BFF）の 30 秒より長い（中継の 502 を受け取れる）", async () => {
    const { API_REQUEST_TIMEOUT_MS } = await import("./config");

    expect(API_REQUEST_TIMEOUT_MS).toBeGreaterThan(30_000);
  });

  it("呼び出し側の AbortSignal で中断したら ApiAbortedError（fetch の信号も中断する）", async () => {
    const controller = new AbortController();
    const { fetch, calls } = createFakeFetch(
      (_url, init) =>
        new Promise((_resolve, reject) => {
          init.signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
        }),
    );
    const client = new ApiClient({ fetch, timeoutMs: 5_000 });

    const pending = client.getState({ signal: controller.signal });
    controller.abort();

    await expect(pending).rejects.toBeInstanceOf(ApiAbortedError);
    expect(calls[0].init.signal.aborted).toBe(true);
  });

  it("すでに中断された信号を渡したら、要求を送らずに ApiAbortedError", async () => {
    const controller = new AbortController();
    controller.abort();
    const { fetch, calls } = createFakeFetch(() => jsonResponse(200, UNAUTHENTICATED_STATE));
    const client = new ApiClient({ fetch });

    await expect(client.getState({ signal: controller.signal })).rejects.toBeInstanceOf(ApiAbortedError);
    expect(calls).toHaveLength(0);
  });

  it("成功したあとは、時間切れの待ちを残さない（タイマーのリークが無い）", async () => {
    jest.useFakeTimers();
    try {
      const { fetch } = createFakeFetch(() => jsonResponse(200, UNAUTHENTICATED_STATE));
      const client = new ApiClient({ fetch, timeoutMs: 60_000 });

      await client.getState();

      expect(jest.getTimerCount()).toBe(0);
    } finally {
      jest.useRealTimers();
    }
  });

  it("失敗したあとも、時間切れの待ちを残さない", async () => {
    jest.useFakeTimers();
    try {
      const { fetch } = createFakeFetch(() => Promise.reject(new TypeError("fetch failed")));
      const client = new ApiClient({ fetch, timeoutMs: 60_000 });

      await errorOf(client.getState());

      expect(jest.getTimerCount()).toBe(0);
    } finally {
      jest.useRealTimers();
    }
  });
});

describe("ApiClient: 秘密の扱い", () => {
  it("エラーのメッセージに、CSRF トークン・bot 判定のトークン・応答の本文を含めない", async () => {
    const { client } = await loggedIn(() => jsonResponse(500, { error: { code: "made_up_code", details: { echoed: DUMMY_RECAPTCHA_TOKEN } } }));

    const error = (await errorOf(client.startYouTubeConnect(DUMMY_RECAPTCHA_TOKEN))) as Error;

    expect(error.message).not.toContain(DUMMY_CSRF_TOKEN);
    expect(error.message).not.toContain(DUMMY_RECAPTCHA_TOKEN);
    expect(error.message).not.toContain("echoed");
  });

  it("既定の fetch は、呼び出しのたびにグローバルの fetch を参照する（差し替え・パッチに追従する）", async () => {
    const spy = jest.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify(UNAUTHENTICATED_STATE), {
      status: 200,
      headers: { "content-type": "application/json" },
    }));
    try {
      const client = new ApiClient();

      await client.getState();

      expect(spy).toHaveBeenCalledTimes(1);
      expect(spy.mock.calls[0][0]).toBe("/api/state");
    } finally {
      spy.mockRestore();
    }
  });
});
