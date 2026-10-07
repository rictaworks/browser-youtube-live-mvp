/**
 * @jest-environment node
 */
import { createBffHandler } from "./forward";
import {
  contextFor,
  createLogger,
  createRecordingFetch,
  DUMMY_BACKEND_ORIGIN,
  DUMMY_SECRET,
  headerOf,
  loggedText,
  makeDeps,
  PRODUCTION_ENV,
  TEST_ENV,
} from "./test-support";

// 同一オリジン中継（BFF）の本体。fetch・環境変数・ログを注入して、本物のバックエンドを呼ばずに検査する
// （本物のネットワークを使った検査は、forward.integration.test.ts）。

const PUBLIC_URL = "https://app.example.test";

function browserRequest(path: string, init: RequestInit & { duplex?: "half" } = {}): Request {
  return new Request(`${PUBLIC_URL}${path}`, init);
}

function jsonResponse(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}

describe("BFF: 転送先とメソッド", () => {
  it.each(["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])(
    "%s を、BACKEND_ORIGIN の同じ経路・同じクエリへ、同じメソッドで転送する",
    async (method) => {
      const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
      const handler = createBffHandler(makeDeps({ fetch, env: () => TEST_ENV }));

      await handler(browserRequest("/api/state?with_channel=1", { method }), contextFor("state"));

      expect(calls).toHaveLength(1);
      expect(calls[0].url).toBe("http://backend:3001/api/state?with_channel=1");
      expect(calls[0].init.method).toBe(method);
    },
  );

  it("経路の区間が複数あっても、/api/ 配下の同じ経路へ転送する", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
    const handler = createBffHandler(makeDeps({ fetch }));

    await handler(
      browserRequest("/api/broadcasts/2f6c1d0e-7b5a-4f0e-9a43-5c8f1e2d3a4b/ticket", { method: "POST" }),
      contextFor("broadcasts", "2f6c1d0e-7b5a-4f0e-9a43-5c8f1e2d3a4b", "ticket"),
    );

    expect(calls[0].url).toBe("http://backend:3001/api/broadcasts/2f6c1d0e-7b5a-4f0e-9a43-5c8f1e2d3a4b/ticket");
  });

  it("認可コードのコールバックのクエリ（code・state）を、そのまま転送する", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 302, headers: { location: `${PUBLIC_URL}/studio` } }));
    const handler = createBffHandler(makeDeps({ fetch }));

    await handler(browserRequest("/api/auth/callback?code=dummy-code&state=dummy-state"), contextFor("auth", "callback"));

    expect(calls[0].url).toBe("http://backend:3001/api/auth/callback?code=dummy-code&state=dummy-state");
  });

  it("リダイレクトを追わず（manual）、キャッシュさせず（no-store）、タイムアウトの信号を付けて呼ぶ", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
    const handler = createBffHandler(makeDeps({ fetch }));

    await handler(browserRequest("/api/state"), contextFor("state"));

    expect(calls[0].init.redirect).toBe("manual");
    expect(calls[0].init.cache).toBe("no-store");
    expect(calls[0].init.signal).toBeInstanceOf(AbortSignal);
    expect(calls[0].init.signal?.aborted).toBe(false);
  });
});

describe("BFF: 要求のヘッダ", () => {
  it("共有の秘密値を付け、転送ヘッダを作り直す。ブラウザから来た秘密値・転送ヘッダ・Host は使わない", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
    const handler = createBffHandler(makeDeps({ fetch, env: () => PRODUCTION_ENV }));

    await handler(
      browserRequest("/api/state", {
        headers: {
          cookie: "bl_session=dummy-session",
          "x-csrf-token": "dummy-csrf",
          "x-bl-client": "web",
          accept: "application/json",
          "x-bff-secret": "attacker-secret",
          "x-relay-secret": "attacker-relay",
          "x-forwarded-for": "203.0.113.9, 10.0.0.1",
          "x-forwarded-host": "evil.example",
          "x-forwarded-proto": "http",
          host: "app.example.test",
        },
      }),
      contextFor("state"),
    );

    const [call] = calls;
    expect(headerOf(call, "x-bff-secret")).toBe(DUMMY_SECRET);
    expect(headerOf(call, "x-relay-secret")).toBeNull();
    expect(headerOf(call, "x-forwarded-for")).toBe("203.0.113.9");
    expect(headerOf(call, "x-forwarded-host")).toBe("app.example.test");
    expect(headerOf(call, "x-forwarded-proto")).toBe("https");
    // Host ヘッダそのものは、渡さない（バックエンド自身のホストで、fetch が組み立てる）。公開ホストは、X-Forwarded-Host で渡す
    expect(headerOf(call, "host")).toBeNull();
    expect(headerOf(call, "cookie")).toBe("bl_session=dummy-session");
    expect(headerOf(call, "x-csrf-token")).toBe("dummy-csrf");
    expect(headerOf(call, "x-bl-client")).toBe("web");
    expect(headerOf(call, "accept")).toBe("application/json");
  });

  it("開発の公開オリジン（http・ポート付き）を、X-Forwarded-Host・Proto へ作り直す", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
    const handler = createBffHandler(makeDeps({ fetch }));

    await handler(new Request("http://localhost:3000/api/state", { headers: { host: "localhost:3000" } }), contextFor("state"));

    expect(headerOf(calls[0], "x-forwarded-host")).toBe("localhost:3000");
    expect(headerOf(calls[0], "x-forwarded-proto")).toBe("http");
  });

  it("公開ホストは、Host ヘッダから取る（Next.js が組み立てた要求の URL のホストが、サーバー自身の名前でも）。プロトコルは、環境から（偽れる X-Forwarded-Proto・URL のスキームを使わない）", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
    const handler = createBffHandler(makeDeps({ fetch, env: () => PRODUCTION_ENV }));

    await handler(
      new Request("http://localhost:3201/api/state", { headers: { host: "app.example.test", "x-forwarded-proto": "http", "x-forwarded-host": "evil.example" } }),
      contextFor("state"),
    );

    expect(headerOf(calls[0], "x-forwarded-host")).toBe("app.example.test");
    expect(headerOf(calls[0], "x-forwarded-proto")).toBe("https");
  });

  it("不正な Host ヘッダは、400 {\"error\":{\"code\":\"invalid_input\"}} で拒否し、バックエンドを呼ばない。ログへ Host の値を出さない", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
    const logger = createLogger();
    const handler = createBffHandler(makeDeps({ fetch, logger }));

    const response = await handler(new Request("http://localhost:3000/api/state", { headers: { host: "evil.example/<x>" } }), contextFor("state"));

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({ error: { code: "invalid_input" } });
    expect(calls).toHaveLength(0);
    expect(loggedText(logger)).not.toContain("evil.example");
  });

  it("接続元の IP が無い・不正なら、X-Forwarded-For を付けない", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
    const handler = createBffHandler(makeDeps({ fetch }));

    await handler(browserRequest("/api/state", { headers: { "x-forwarded-for": "not-an-ip" } }), contextFor("state"));
    await handler(browserRequest("/api/state"), contextFor("state"));

    expect(headerOf(calls[0], "x-forwarded-for")).toBeNull();
    expect(headerOf(calls[1], "x-forwarded-for")).toBeNull();
  });
});

describe("BFF: 要求の本文", () => {
  it("本文（JSON）を、そのままバイト列で転送し、Content-Type を通す", async () => {
    const { fetch, calls } = createRecordingFetch(() => jsonResponse(200, { authorization_url: "https://accounts.google.com/o/oauth2/v2/auth" }));
    const handler = createBffHandler(makeDeps({ fetch }));
    const payload = JSON.stringify({ recaptcha_token: "dummy-recaptcha-token" });

    await handler(
      browserRequest("/api/auth/login/start", {
        method: "POST",
        body: payload,
        headers: { "content-type": "application/json; charset=utf-8", "x-bl-client": "web" },
      }),
      contextFor("auth", "login", "start"),
    );

    const body = calls[0].init.body as Uint8Array;
    expect(new TextDecoder().decode(body)).toBe(payload);
    expect(headerOf(calls[0], "content-type")).toBe("application/json; charset=utf-8");
  });

  it("GET・HEAD には、本文を付けない", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
    const handler = createBffHandler(makeDeps({ fetch }));

    await handler(browserRequest("/api/state"), contextFor("state"));
    await handler(browserRequest("/api/state", { method: "HEAD" }), contextFor("state"));

    expect(calls[0].init.body).toBeUndefined();
    expect(calls[1].init.body).toBeUndefined();
  });

  it("本文が無い POST（ログアウト）は、本文を付けずに転送する", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 204 }));
    const handler = createBffHandler(makeDeps({ fetch }));

    await handler(browserRequest("/api/auth/logout", { method: "POST", headers: { "x-bl-client": "web" } }), contextFor("auth", "logout"));

    expect(calls[0].init.body).toBeUndefined();
  });

  it("上限（64 KB）を超える本文は、Content-Length の事前検査で拒否し、バックエンドを呼ばない（413）", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
    const handler = createBffHandler(makeDeps({ fetch, maxBodyBytes: 16 }));

    const response = await handler(
      browserRequest("/api/broadcasts", { method: "POST", body: "x".repeat(17), headers: { "content-type": "application/json" } }),
      contextFor("broadcasts"),
    );

    expect(response.status).toBe(413);
    await expect(response.json()).resolves.toEqual({ error: { code: "invalid_input" } });
    expect(calls).toHaveLength(0);
  });

  it("上限を超える本文は、チャンク転送（Content-Length なし）でも、読み込み中に打ち切って拒否する（413）", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
    const handler = createBffHandler(makeDeps({ fetch, maxBodyBytes: 16 }));
    const encoder = new TextEncoder();
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        controller.enqueue(encoder.encode("0123456789"));
      },
    });

    const response = await handler(
      browserRequest("/api/broadcasts", { method: "POST", body: stream, duplex: "half" }),
      contextFor("broadcasts"),
    );

    expect(response.status).toBe(413);
    expect(calls).toHaveLength(0);
  });

  it("上限ちょうどの本文は、転送する", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 204 }));
    const handler = createBffHandler(makeDeps({ fetch, maxBodyBytes: 16 }));

    const response = await handler(
      browserRequest("/api/usage-events", { method: "POST", body: "x".repeat(16) }),
      contextFor("usage-events"),
    );

    expect(response.status).toBe(204);
    expect(calls).toHaveLength(1);
  });

  it("既定の上限は 64 KB（65,536 バイト）", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 204 }));
    const { maxBodyBytes } = makeDeps();
    const handler = createBffHandler(makeDeps({ fetch, maxBodyBytes }));

    expect(maxBodyBytes).toBe(65536);
    const tooLarge = await handler(
      browserRequest("/api/usage-events", { method: "POST", body: "x".repeat(65537) }),
      contextFor("usage-events"),
    );
    const exact = await handler(
      browserRequest("/api/usage-events", { method: "POST", body: "x".repeat(65536) }),
      contextFor("usage-events"),
    );

    expect(tooLarge.status).toBe(413);
    expect(exact.status).toBe(204);
    expect(calls).toHaveLength(1);
  });
});

describe("BFF: 応答", () => {
  it.each([200, 201, 400, 401, 403, 404, 409, 422, 429, 500, 503])("ステータス %i と JSON の本文を、そのまま返す", async (status) => {
    const body = { error: { code: "rate_limited", details: { retry_at: "2026-10-07T13:31:00+09:00" } } };
    const { fetch } = createRecordingFetch(() => jsonResponse(status, body));
    const handler = createBffHandler(makeDeps({ fetch }));

    const response = await handler(browserRequest("/api/youtube/recheck", { method: "POST" }), contextFor("youtube", "recheck"));

    expect(response.status).toBe(status);
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(response.headers.get("cache-control")).toBe("no-store");
    await expect(response.json()).resolves.toEqual(body);
  });

  it("204（本文なし）を、本文なしで返す", async () => {
    const { fetch } = createRecordingFetch(() => new Response(null, { status: 204 }));
    const handler = createBffHandler(makeDeps({ fetch }));

    const response = await handler(browserRequest("/api/auth/logout", { method: "POST" }), contextFor("auth", "logout"));

    expect(response.status).toBe(204);
    expect(response.body).toBeNull();
  });

  it("302 は、追わずに、Location ごと返す（認可コードのコールバック）。複数の Set-Cookie を欠落なく返す", async () => {
    const upstreamHeaders = new Headers({ location: `${PUBLIC_URL}/studio` });
    upstreamHeaders.append("set-cookie", "bl_session=dummy-session; Path=/; HttpOnly; SameSite=Lax; Secure");
    upstreamHeaders.append("set-cookie", "bl_oauth=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax; Secure");
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 302, headers: upstreamHeaders }));
    const handler = createBffHandler(makeDeps({ fetch }));

    const response = await handler(
      browserRequest("/api/auth/callback?code=dummy-code&state=dummy-state", { headers: { cookie: "bl_oauth=dummy-oauth" } }),
      contextFor("auth", "callback"),
    );

    expect(calls).toHaveLength(1);
    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(`${PUBLIC_URL}/studio`);
    expect(response.headers.getSetCookie()).toEqual([
      "bl_session=dummy-session; Path=/; HttpOnly; SameSite=Lax; Secure",
      "bl_oauth=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax; Secure",
    ]);
  });

  it("バックエンドの内部情報のヘッダ（Server・X-Powered-By・X-Runtime・Server-Timing など）を返さない", async () => {
    const { fetch } = createRecordingFetch(() =>
      jsonResponse(200, { authenticated: false, csrf_token: null }, {
        server: "Puma 7.0",
        "x-powered-by": "Phusion Passenger",
        "x-runtime": "0.1",
        "x-request-id": "dummy-request-id",
        "server-timing": "render;dur=1",
        via: "1.1 railway-edge",
      }),
    );
    const handler = createBffHandler(makeDeps({ fetch }));

    const response = await handler(browserRequest("/api/state"), contextFor("state"));

    for (const name of ["server", "x-powered-by", "x-runtime", "x-request-id", "server-timing", "via"]) {
      expect(response.headers.has(name)).toBe(false);
    }
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
  });

  it("本文を全部読み込まずに、ストリームのまま返す（先頭のチャンクを、残りの到着より前に読める）", async () => {
    let controller!: ReadableStreamDefaultController<Uint8Array>;
    const stream = new ReadableStream<Uint8Array>({
      start(c) {
        controller = c;
      },
    });
    const { fetch } = createRecordingFetch(() => new Response(stream, { status: 200, headers: { "content-type": "text/plain" } }));
    const handler = createBffHandler(makeDeps({ fetch }));

    // 本文が閉じる前に、応答が返る（全読み込みを待たない）
    const response = await handler(browserRequest("/api/state"), contextFor("state"));
    const reader = response.body?.getReader();
    controller.enqueue(new TextEncoder().encode("first"));
    const first = await reader?.read();
    controller.enqueue(new TextEncoder().encode("second"));
    controller.close();
    const second = await reader?.read();
    const done = await reader?.read();

    expect(new TextDecoder().decode(first?.value)).toBe("first");
    expect(new TextDecoder().decode(second?.value)).toBe("second");
    expect(done?.done).toBe(true);
  });

  it("内部の URL（バックエンドのホスト）への Location は返さず、502 にする。受け取った本文は破棄する", async () => {
    let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({
      cancel() {
        cancelled = true;
      },
    });
    const { fetch } = createRecordingFetch(
      () => new Response(stream, { status: 302, headers: { location: `${DUMMY_BACKEND_ORIGIN}/studio` } }),
    );
    const logger = createLogger();
    const handler = createBffHandler(makeDeps({ fetch, logger, env: () => PRODUCTION_ENV }));

    const response = await handler(browserRequest("/api/auth/callback?code=dummy-code&state=dummy-state"), contextFor("auth", "callback"));

    expect(response.status).toBe(502);
    expect(response.headers.has("location")).toBe(false);
    await expect(response.json()).resolves.toEqual({ error: { code: "bad_gateway" } });
    expect(cancelled).toBe(true);
    expect(logger.error).toHaveBeenCalledTimes(1);
    expect(loggedText(logger)).not.toContain("backend.internal.example");
    expect(loggedText(logger)).not.toContain("dummy-code");
  });
});

describe("BFF: バックエンドへ到達できない・時間切れ（502）", () => {
  it("接続できないとき、502 と {\"error\":{\"code\":\"bad_gateway\"}} だけを返す（詳細・URL を出さない）", async () => {
    const cause = Object.assign(new Error("connect ECONNREFUSED 10.0.0.5:3001"), { code: "ECONNREFUSED" });
    const { fetch } = createRecordingFetch(() => Promise.reject(new TypeError("fetch failed", { cause })));
    const logger = createLogger();
    const handler = createBffHandler(makeDeps({ fetch, logger, env: () => PRODUCTION_ENV }));

    const response = await handler(
      browserRequest("/api/state?with_channel=1", { headers: { cookie: "bl_session=dummy-session" } }),
      contextFor("state"),
    );
    const text = await response.text();

    expect(response.status).toBe(502);
    expect(JSON.parse(text)).toEqual({ error: { code: "bad_gateway" } });
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(response.headers.get("cache-control")).toBe("no-store");
    for (const leaked of ["ECONNREFUSED", "10.0.0.5", "backend.internal.example", DUMMY_SECRET, "bl_session"]) {
      expect(text).not.toContain(leaked);
      expect(JSON.stringify(Array.from(response.headers.entries()))).not.toContain(leaked);
    }
  });

  it("ログへは、何が（メソッド・経路）・なぜ（原因の符号）失敗したかを出す。秘密値・Cookie・クエリ・転送先は出さない", async () => {
    const cause = Object.assign(new Error("connect ECONNREFUSED 10.0.0.5:3001"), { code: "ECONNREFUSED" });
    const { fetch } = createRecordingFetch(() => Promise.reject(new TypeError("fetch failed", { cause })));
    const logger = createLogger();
    const handler = createBffHandler(makeDeps({ fetch, logger, env: () => PRODUCTION_ENV }));

    await handler(
      browserRequest("/api/auth/callback?code=dummy-code&state=dummy-state", { headers: { cookie: "bl_oauth=dummy-oauth" } }),
      contextFor("auth", "callback"),
    );

    const text = loggedText(logger);
    expect(logger.error).toHaveBeenCalledTimes(1);
    expect(text).toContain("GET");
    expect(text).toContain("/api/auth/callback");
    expect(text).toContain("ECONNREFUSED");
    for (const leaked of [DUMMY_SECRET, "dummy-oauth", "dummy-code", "dummy-state", "backend.internal.example", "10.0.0.5"]) {
      expect(text).not.toContain(leaked);
    }
  });

  it("時間切れ（タイムアウト）のとき、502 を返し、ログへ時間切れと出す", async () => {
    const { fetch } = createRecordingFetch(
      (_url, init) =>
        new Promise<Response>((_resolve, reject) => {
          init.signal?.addEventListener("abort", () => reject(init.signal?.reason));
        }),
    );
    const logger = createLogger();
    const handler = createBffHandler(makeDeps({ fetch, logger, timeoutMs: 30 }));

    const response = await handler(browserRequest("/api/state"), contextFor("state"));

    expect(response.status).toBe(502);
    await expect(response.json()).resolves.toEqual({ error: { code: "bad_gateway" } });
    expect(loggedText(logger)).toContain("timeout");
  });

  it("既定の時間切れは 30 秒", () => {
    expect(makeDeps().timeoutMs).toBe(30_000);
  });

  it("fetch が、Error でない値を投げても、502 として扱う", async () => {
    const { fetch } = createRecordingFetch(() => Promise.reject("boom"));
    const handler = createBffHandler(makeDeps({ fetch }));

    const response = await handler(browserRequest("/api/state"), contextFor("state"));

    expect(response.status).toBe(502);
  });
});

describe("BFF: 転送してよい経路の制限", () => {
  it.each([
    ["上の階層へ戻る", ["..", "admin"]],
    ["途中の ..", ["auth", "..", "..", "admin"]],
    ["エンコードされた区切り", ["auth/login"]],
    ["二重のエンコード", ["%2e%2e", "admin"]],
    ["内部通信の経路", ["internal", "verify"]],
    ["管理画面の経路", ["admin"]],
    ["区間が無い", []],
  ])("%s は、404 {\"error\":{\"code\":\"not_found\"}} で拒否し、バックエンドを呼ばない", async (_title, segments) => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
    const logger = createLogger();
    const handler = createBffHandler(makeDeps({ fetch, logger }));

    const response = await handler(browserRequest("/api/x"), contextFor(...segments));

    expect(response.status).toBe(404);
    await expect(response.json()).resolves.toEqual({ error: { code: "not_found" } });
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(calls).toHaveLength(0);
    expect(logger.warn).toHaveBeenCalledTimes(1);
  });

  it("params が無い（path が undefined）ときも、404 で拒否する", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
    const handler = createBffHandler(makeDeps({ fetch }));

    const response = await handler(browserRequest("/api"), { params: Promise.resolve({}) });

    expect(response.status).toBe(404);
    expect(calls).toHaveLength(0);
  });

  it("本番では /api/dev/ 配下（疑似の Google など）を転送しない。開発・テストでは転送する", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
    const production = createBffHandler(makeDeps({ fetch, env: () => PRODUCTION_ENV }));
    const development = createBffHandler(makeDeps({ fetch, env: () => ({ ...TEST_ENV, NODE_ENV: "development" }) }));

    const denied = await production(browserRequest("/api/dev/google/authorize"), contextFor("dev", "google", "authorize"));
    const allowed = await development(browserRequest("/api/dev/google/authorize"), contextFor("dev", "google", "authorize"));

    expect(denied.status).toBe(404);
    expect(allowed.status).toBe(200);
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("http://backend:3001/api/dev/google/authorize");
  });

  it("拒否した経路の値を、ログへ生のまま出さない（改行などの注入を防ぐ）", async () => {
    const logger = createLogger();
    const handler = createBffHandler(makeDeps({ logger }));

    await handler(browserRequest("/api/x"), contextFor("state\r\nX-Evil: 1"));

    expect(logger.warn).toHaveBeenCalledTimes(1);
    const [message] = logger.warn.mock.calls[0] as [string];
    expect(message).not.toMatch(/[\r\n]/);
  });
});

describe("BFF: 設定エラー（500。欠けている変数の名前だけを返す）", () => {
  it("BACKEND_ORIGIN が欠けていれば、500 と欠けている変数の名前だけを返し、バックエンドを呼ばない", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
    const logger = createLogger();
    const handler = createBffHandler(
      makeDeps({ fetch, logger, env: () => ({ NODE_ENV: "production", BFF_SHARED_SECRET: DUMMY_SECRET }) }),
    );

    const response = await handler(browserRequest("/api/state"), contextFor("state"));
    const text = await response.text();

    expect(response.status).toBe(500);
    expect(JSON.parse(text)).toEqual({ error: { code: "internal_error", details: { missing: ["BACKEND_ORIGIN"], invalid: [] } } });
    expect(calls).toHaveLength(0);
    expect(text).not.toContain(DUMMY_SECRET);
    expect(loggedText(logger)).toContain("BACKEND_ORIGIN");
    expect(loggedText(logger)).not.toContain(DUMMY_SECRET);
  });

  it("BFF_SHARED_SECRET が欠けていれば、その名前だけを返す（BACKEND_ORIGIN の値を含めない）", async () => {
    const handler = createBffHandler(makeDeps({ env: () => ({ NODE_ENV: "production", BACKEND_ORIGIN: DUMMY_BACKEND_ORIGIN }) }));

    const response = await handler(browserRequest("/api/state"), contextFor("state"));
    const text = await response.text();

    expect(response.status).toBe(500);
    expect(JSON.parse(text).error.details.missing).toEqual(["BFF_SHARED_SECRET"]);
    expect(text).not.toContain("backend.internal.example");
  });

  it("不正な BACKEND_ORIGIN（資格情報つき）は、名前だけを返し、値を応答にもログにも出さない", async () => {
    const logger = createLogger();
    const handler = createBffHandler(
      makeDeps({
        logger,
        env: () => ({ NODE_ENV: "production", BACKEND_ORIGIN: "https://user:topsecret@backend.internal.example", BFF_SHARED_SECRET: DUMMY_SECRET }),
      }),
    );

    const response = await handler(browserRequest("/api/state"), contextFor("state"));
    const text = await response.text();

    expect(response.status).toBe(500);
    expect(JSON.parse(text).error.details.invalid).toEqual(["BACKEND_ORIGIN"]);
    for (const leaked of ["topsecret", "backend.internal.example", DUMMY_SECRET]) {
      expect(text).not.toContain(leaked);
      expect(loggedText(logger)).not.toContain(leaked);
    }
  });

  it("環境変数は、要求のたびに読む（モジュールの読み込み時に固定しない）", async () => {
    const { fetch, calls } = createRecordingFetch(() => new Response(null, { status: 200 }));
    let env: Record<string, string | undefined> = { NODE_ENV: "test" };
    const handler = createBffHandler(makeDeps({ fetch, env: () => env }));

    const before = await handler(browserRequest("/api/state"), contextFor("state"));
    env = { ...TEST_ENV };
    const after = await handler(browserRequest("/api/state"), contextFor("state"));

    expect(before.status).toBe(500);
    expect(after.status).toBe(200);
    expect(calls).toHaveLength(1);
  });
});

describe("BFF: 想定外の例外", () => {
  it("想定外の例外は、500 {\"error\":{\"code\":\"internal_error\"}} だけを返し、ログへ原因を出す", async () => {
    const logger = createLogger();
    const handler = createBffHandler(
      makeDeps({
        logger,
        env: () => {
          throw new Error("unexpected failure while reading env");
        },
      }),
    );

    const response = await handler(browserRequest("/api/state"), contextFor("state"));

    expect(response.status).toBe(500);
    await expect(response.json()).resolves.toEqual({ error: { code: "internal_error" } });
    expect(loggedText(logger)).toContain("unexpected failure while reading env");
  });
});

describe("BFF: 秘密値の扱い", () => {
  it.each([
    ["成功", () => jsonResponse(200, { authenticated: false, csrf_token: null })],
    ["バックエンドの 500", () => jsonResponse(500, { error: { code: "internal_error" } })],
    ["不達", () => Promise.reject(new TypeError("fetch failed"))],
  ])("%s のどの場合も、共有の秘密値を応答（本文・ヘッダ）にもログにも出さない", async (_title, respond) => {
    const { fetch } = createRecordingFetch(respond);
    const logger = createLogger();
    const handler = createBffHandler(makeDeps({ fetch, logger, env: () => PRODUCTION_ENV }));

    const response = await handler(browserRequest("/api/state", { headers: { "x-bff-secret": DUMMY_SECRET } }), contextFor("state"));
    const text = await response.text();

    expect(text).not.toContain(DUMMY_SECRET);
    expect(JSON.stringify(Array.from(response.headers.entries()))).not.toContain(DUMMY_SECRET);
    expect(loggedText(logger)).not.toContain(DUMMY_SECRET);
  });
});
