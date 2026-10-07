/**
 * @jest-environment node
 */
import * as route from "./route";
import { BFF_UPSTREAM_TIMEOUT_MS } from "./config";
import { contextFor, DUMMY_SECRET } from "./test-support";

// route.ts は、Next.js が読む特別なファイル。公開してよい名前（メソッドのハンドラと、ルートの設定）だけを書き出す。
// 実際の中継の動作は、forward.test.ts と forward.integration.test.ts。ここは、配線（環境変数・fetch・書き出し）を確かめる。

const ALLOWED_EXPORTS = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT", "dynamic", "maxDuration", "runtime"];
const METHODS = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"] as const;

describe("route.ts: 書き出し", () => {
  it("すべてのメソッド（GET・HEAD・POST・PUT・PATCH・DELETE・OPTIONS）のハンドラを書き出す", () => {
    for (const method of METHODS) {
      expect(typeof route[method]).toBe("function");
    }
  });

  it("書き出す名前は、Next.js が許すものだけ（許されない名前があると、ビルドが失敗する）", () => {
    expect(Object.keys(route).sort()).toEqual(ALLOWED_EXPORTS);
  });

  it("毎回評価し（force-dynamic）、Node.js のランタイムで動かす", () => {
    expect(route.dynamic).toBe("force-dynamic");
    expect(route.runtime).toBe("nodejs");
  });

  it("関数の実行時間の上限（maxDuration）は、バックエンドを待つ上限（30 秒）より長い（JSON の 502 を、先に返せる）", () => {
    expect(BFF_UPSTREAM_TIMEOUT_MS).toBe(30_000);
    expect(route.maxDuration * 1000).toBeGreaterThan(BFF_UPSTREAM_TIMEOUT_MS);
  });
});

describe("route.ts: 配線（process.env とグローバルの fetch を、要求のたびに使う）", () => {
  const savedEnv = { ...process.env };
  const mutableEnv = process.env as Record<string, string | undefined>;
  let fetchSpy: jest.SpyInstance;

  // process.env へ undefined を代入すると、文字列の "undefined" になる。変数が無い状態は、プロパティごと外して作る
  function unsetEnv(name: string): void {
    delete mutableEnv[name];
  }

  beforeEach(() => {
    mutableEnv.BACKEND_ORIGIN = "http://backend:3001";
    mutableEnv.BFF_SHARED_SECRET = DUMMY_SECRET;
    fetchSpy = jest.spyOn(globalThis, "fetch").mockImplementation(async () => new Response(JSON.stringify({ authenticated: false, csrf_token: null }), {
      status: 200,
      headers: { "content-type": "application/json; charset=utf-8" },
    }));
  });

  afterEach(() => {
    fetchSpy.mockRestore();
    for (const key of Object.keys(process.env)) {
      if (!(key in savedEnv)) {
        unsetEnv(key);
      }
    }
    Object.assign(process.env, savedEnv);
  });

  it("BACKEND_ORIGIN の同じ経路へ、共有の秘密値（BFF_SHARED_SECRET）を付けて転送する", async () => {
    const response = await route.GET(new Request("http://localhost:3000/api/state?with_channel=1"), contextFor("state"));

    expect(response.status).toBe(200);
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("http://backend:3001/api/state?with_channel=1");
    expect(new Headers(init.headers).get("x-bff-secret")).toBe(DUMMY_SECRET);
    expect(init.method).toBe("GET");
  });

  it.each(METHODS)("%s のハンドラは、そのメソッドで転送する", async (method) => {
    await route[method](new Request("http://localhost:3000/api/state", { method }), contextFor("state"));

    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
    expect(init.method).toBe(method);
  });

  it("環境変数を、要求のたびに読む（変えると、次の要求から反映する）", async () => {
    mutableEnv.BACKEND_ORIGIN = "http://other-backend:4000";

    await route.GET(new Request("http://localhost:3000/api/state"), contextFor("state"));

    expect((fetchSpy.mock.calls[0] as [string])[0]).toBe("http://other-backend:4000/api/state");
  });

  it("環境変数が欠けていれば、設定エラー（500）で、バックエンドを呼ばない", async () => {
    unsetEnv("BFF_SHARED_SECRET");
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);

    const response = await route.GET(new Request("http://localhost:3000/api/state"), contextFor("state"));

    expect(response.status).toBe(500);
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(consoleError).toHaveBeenCalledTimes(1);
    consoleError.mockRestore();
  });
});
