/**
 * @jest-environment node
 */
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { gzipSync } from "node:zlib";
import { createBffHandler } from "./forward";
import { contextFor, createLogger, DUMMY_SECRET, loggedText, makeDeps } from "./test-support";

// 本物のネットワーク（127.0.0.1 の使い捨てのテスト用サーバー）を相手に、Node の fetch の挙動を含めて検査する。
// 外部のサービスは呼ばない。テスト用サーバーは、ephemeral port で起動し、終了時に止める。

interface Seen {
  method: string;
  url: string;
  headers: IncomingMessage["headers"];
  body: string;
}

let server: Server;
let origin = "";
const seen: Seen[] = [];
let releaseSecondChunk: (() => void) | null = null;

function readBody(request: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk: Buffer) => chunks.push(chunk));
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

async function handleBackend(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const body = await readBody(request);
  const path = (request.url ?? "").split("?")[0];
  seen.push({ method: request.method ?? "", url: request.url ?? "", headers: request.headers, body });

  if (path === "/api/echo") {
    response.writeHead(200, { "content-type": "application/json; charset=utf-8", server: "Puma", "x-powered-by": "Dummy", "x-runtime": "0.01" });
    response.end(JSON.stringify({ method: request.method, url: request.url, headers: request.headers, body }));
  } else if (path === "/api/redirect") {
    response.setHeader("set-cookie", ["bl_session=dummy-session; Path=/; HttpOnly", "bl_oauth=; Path=/; Max-Age=0"]);
    response.writeHead(302, { location: "/api/echo" });
    response.end("redirecting");
  } else if (path === "/api/leak-location") {
    response.writeHead(302, { location: `${origin}/studio` });
    response.end();
  } else if (path === "/api/gzip") {
    const payload = gzipSync(JSON.stringify({ compressed: true }));
    response.writeHead(200, { "content-type": "application/json", "content-encoding": "gzip", "content-length": payload.length });
    response.end(payload);
  } else if (path === "/api/stream") {
    response.writeHead(200, { "content-type": "text/plain" });
    response.write("first");
    releaseSecondChunk = () => response.end("second");
  } else if (path === "/api/slow") {
    // 応答しない（時間切れの検査）
  } else if (path === "/api/no-content") {
    response.writeHead(204);
    response.end();
  } else if (path === "/api/head") {
    response.writeHead(200, { "content-type": "application/json", "content-length": 11 });
    response.end();
  } else {
    response.writeHead(404, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: { code: "not_found" } }));
  }
}

beforeAll(async () => {
  server = createServer((request, response) => {
    handleBackend(request, response).catch(() => {
      response.writeHead(500).end();
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

afterAll(async () => {
  server.closeAllConnections();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

beforeEach(() => {
  seen.length = 0;
  releaseSecondChunk = null;
});

function handler(overrides: Parameters<typeof makeDeps>[0] = {}) {
  return createBffHandler(
    makeDeps({
      // 本番の構成（プロトコルは https）。同じ計算機の内側（127.0.0.1）の宛先は、本番でも http を許す
      env: () => ({ NODE_ENV: "production", BACKEND_ORIGIN: origin, BFF_SHARED_SECRET: DUMMY_SECRET }),
      fetch: (input, init) => fetch(input, init),
      ...overrides,
    }),
  );
}

const PUBLIC_URL = "https://app.example.test";

/** 使い捨てのサーバーを立てて止め、閉じているポートの番号を得る（fetch は、1 などの予約済みのポートへ接続しない） */
async function findClosedPort(): Promise<number> {
  const probe = createServer();
  await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
  const { port } = probe.address() as AddressInfo;
  await new Promise<void>((resolve) => probe.close(() => resolve()));
  return port;
}

describe("BFF（本物の fetch・テスト用サーバー）: 転送", () => {
  it("バックエンドが受け取るヘッダ: 共有の秘密値と作り直した転送ヘッダを持ち、ブラウザの偽の値・Host を持たない", async () => {
    const response = await handler()(
      new Request(`${PUBLIC_URL}/api/echo?with_channel=1`, {
        method: "POST",
        body: JSON.stringify({ recaptcha_token: "dummy" }),
        headers: {
          "content-type": "application/json; charset=utf-8",
          cookie: "bl_session=dummy-session",
          "x-csrf-token": "dummy-csrf",
          "x-bl-client": "web",
          origin: PUBLIC_URL,
          "x-bff-secret": "attacker-secret",
          "x-relay-secret": "attacker-relay",
          "x-forwarded-for": "203.0.113.9",
          "x-forwarded-host": "evil.example",
          "x-forwarded-proto": "http",
          host: "app.example.test",
          authorization: "Bearer dummy",
        },
      }),
      contextFor("echo"),
    );

    const echoed = (await response.json()) as { method: string; url: string; headers: Record<string, string>; body: string };
    expect(response.status).toBe(200);
    expect(echoed.method).toBe("POST");
    expect(echoed.url).toBe("/api/echo?with_channel=1");
    expect(echoed.body).toBe(JSON.stringify({ recaptcha_token: "dummy" }));
    expect(echoed.headers["x-bff-secret"]).toBe(DUMMY_SECRET);
    expect(echoed.headers["x-forwarded-for"]).toBe("203.0.113.9");
    expect(echoed.headers["x-forwarded-host"]).toBe("app.example.test");
    expect(echoed.headers["x-forwarded-proto"]).toBe("https");
    expect(echoed.headers["x-relay-secret"]).toBeUndefined();
    expect(echoed.headers.authorization).toBeUndefined();
    expect(echoed.headers.host).toBe(new URL(origin).host);
    expect(echoed.headers.cookie).toBe("bl_session=dummy-session");
    expect(echoed.headers["x-csrf-token"]).toBe("dummy-csrf");
    expect(echoed.headers["x-bl-client"]).toBe("web");
    expect(echoed.headers.origin).toBe(PUBLIC_URL);
    expect(echoed.headers["content-type"]).toBe("application/json; charset=utf-8");
  });

  it("ブラウザへ返すヘッダ: 内部情報（Server・X-Powered-By・X-Runtime）を返さない", async () => {
    const response = await handler()(new Request(`${PUBLIC_URL}/api/echo`), contextFor("echo"));

    expect(response.headers.has("server")).toBe(false);
    expect(response.headers.has("x-powered-by")).toBe(false);
    expect(response.headers.has("x-runtime")).toBe(false);
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
  });

  it("302 を追わず（リダイレクト先を取りに行かない）、複数の Set-Cookie と一緒にそのまま返す", async () => {
    const response = await handler()(new Request(`${PUBLIC_URL}/api/redirect`), contextFor("redirect"));

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe("/api/echo");
    expect(response.headers.getSetCookie()).toEqual(["bl_session=dummy-session; Path=/; HttpOnly", "bl_oauth=; Path=/; Max-Age=0"]);
    expect(seen.map((call) => call.url)).toEqual(["/api/redirect"]);
  });

  it("バックエンドのホストを指す Location は返さず、502 にする", async () => {
    const logger = createLogger();

    const response = await handler({ logger })(new Request(`${PUBLIC_URL}/api/leak-location`), contextFor("leak-location"));

    expect(response.status).toBe(502);
    expect(response.headers.has("location")).toBe(false);
    expect(loggedText(logger)).not.toContain(origin);
  });

  it("圧縮された応答は、復号して返し、Content-Encoding・Content-Length を返さない（二重に復号されない）", async () => {
    const response = await handler()(new Request(`${PUBLIC_URL}/api/gzip`), contextFor("gzip"));

    expect(response.status).toBe(200);
    expect(response.headers.has("content-encoding")).toBe(false);
    expect(response.headers.has("content-length")).toBe(false);
    await expect(response.json()).resolves.toEqual({ compressed: true });
  });

  it("204 は、本文なしで返す", async () => {
    const response = await handler()(new Request(`${PUBLIC_URL}/api/no-content`, { method: "POST" }), contextFor("no-content"));

    expect(response.status).toBe(204);
    expect(response.body).toBeNull();
  });

  it("HEAD は、HEAD のまま転送し、本文なしで返す", async () => {
    const response = await handler()(new Request(`${PUBLIC_URL}/api/head`, { method: "HEAD" }), contextFor("head"));

    expect(response.status).toBe(200);
    expect(seen[0].method).toBe("HEAD");
    await expect(response.text()).resolves.toBe("");
  });

  it("本文を全部読み込まずに、ストリームのまま返す（先頭のチャンクは、残りの到着より前に読める）", async () => {
    const response = await handler()(new Request(`${PUBLIC_URL}/api/stream`), contextFor("stream"));
    const reader = response.body?.getReader();

    const first = await reader?.read();
    expect(new TextDecoder().decode(first?.value)).toBe("first");
    expect(releaseSecondChunk).not.toBeNull();
    releaseSecondChunk?.();
    const second = await reader?.read();

    expect(new TextDecoder().decode(second?.value)).toBe("second");
  });
});

describe("BFF（本物の fetch・テスト用サーバー）: 制限と障害", () => {
  it("上限（64 KB）を超える本文は、413 で拒否し、バックエンドへ届けない", async () => {
    const response = await handler()(
      new Request(`${PUBLIC_URL}/api/echo`, { method: "POST", body: "x".repeat(65537), headers: { "content-type": "text/plain" } }),
      contextFor("echo"),
    );

    expect(response.status).toBe(413);
    expect(seen).toHaveLength(0);
  });

  it("上限ちょうど（65,536 バイト）の本文は、そのまま届ける", async () => {
    const response = await handler()(
      new Request(`${PUBLIC_URL}/api/echo`, { method: "POST", body: "y".repeat(65536), headers: { "content-type": "text/plain" } }),
      contextFor("echo"),
    );

    expect(response.status).toBe(200);
    expect(seen[0].body).toHaveLength(65536);
  });

  it("バックエンドが応答しないとき、時間切れ（タイムアウト）で 502 を返す", async () => {
    const logger = createLogger();

    const response = await handler({ logger, timeoutMs: 150 })(new Request(`${PUBLIC_URL}/api/slow`), contextFor("slow"));

    expect(response.status).toBe(502);
    await expect(response.json()).resolves.toEqual({ error: { code: "bad_gateway" } });
    expect(loggedText(logger)).toContain("timeout");
  });

  it("バックエンドへ接続できないとき（ポートが閉じている）、502 を返し、ログへ接続拒否の符号を出す。応答にアドレスを出さない", async () => {
    const logger = createLogger();
    const closedPort = await findClosedPort();
    const unreachable = createBffHandler(
      makeDeps({
        env: () => ({ NODE_ENV: "test", BACKEND_ORIGIN: `http://127.0.0.1:${closedPort}`, BFF_SHARED_SECRET: DUMMY_SECRET }),
        fetch: (input, init) => fetch(input, init),
        logger,
      }),
    );

    const response = await unreachable(new Request(`${PUBLIC_URL}/api/state`), contextFor("state"));
    const text = await response.text();

    expect(response.status).toBe(502);
    expect(JSON.parse(text)).toEqual({ error: { code: "bad_gateway" } });
    expect(text).not.toContain("127.0.0.1");
    expect(loggedText(logger)).toContain("ECONNREFUSED");
    expect(loggedText(logger)).not.toContain(DUMMY_SECRET);
  });

  it("バックエンドの 404 は、そのまま返す（符号・本文を変えない）", async () => {
    const response = await handler()(new Request(`${PUBLIC_URL}/api/nothing`), contextFor("nothing"));

    expect(response.status).toBe(404);
    await expect(response.json()).resolves.toEqual({ error: { code: "not_found" } });
  });
});
