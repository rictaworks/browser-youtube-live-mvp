/**
 * @jest-environment node
 */
import { buildClientHeaders, UpstreamLocationError } from "./response-headers";

const BACKEND_ORIGIN = "https://backend.internal.example";

function names(headers: Headers): string[] {
  return Array.from(headers.keys()).sort();
}

describe("buildClientHeaders: ブラウザへ返すヘッダ", () => {
  it("通すヘッダ（Content-Type・Cache-Control・Location・Retry-After）を返す", () => {
    const upstream = new Headers({
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      location: "https://app.example.test/studio",
      "retry-after": "30",
    });

    const client = buildClientHeaders(upstream, BACKEND_ORIGIN);

    expect(client.get("content-type")).toBe("application/json; charset=utf-8");
    expect(client.get("cache-control")).toBe("no-store");
    expect(client.get("location")).toBe("https://app.example.test/studio");
    expect(client.get("retry-after")).toBe("30");
  });

  it("複数の Set-Cookie を、欠落なく、順序を保って返す（第一者 Cookie として保存される）", () => {
    const upstream = new Headers();
    upstream.append("set-cookie", "bl_session=dummy-session; Path=/; HttpOnly; SameSite=Lax; Secure");
    upstream.append("set-cookie", "bl_oauth=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax");
    upstream.append("set-cookie", "third=3; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT");

    const client = buildClientHeaders(upstream, BACKEND_ORIGIN);

    expect(client.getSetCookie()).toEqual([
      "bl_session=dummy-session; Path=/; HttpOnly; SameSite=Lax; Secure",
      "bl_oauth=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax",
      "third=3; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT",
    ]);
  });

  it("バックエンドの内部情報（Server・X-Powered-By・X-Runtime・X-Request-Id・Server-Timing・Via ほか）を返さない", () => {
    const upstream = new Headers({
      "content-type": "application/json",
      server: "Puma 7.0",
      "x-powered-by": "Phusion Passenger",
      "x-runtime": "0.144396",
      "x-request-id": "70c921f8-1d49-42ce-9f7f-4a8b4bf0bc77",
      "server-timing": "render_template.action_view;dur=63.33",
      via: "1.1 railway-edge",
      "alt-svc": 'h3=":443"',
      "x-railway-request-id": "dummy-railway-id",
      "access-control-allow-origin": "*",
      "access-control-allow-credentials": "true",
      "strict-transport-security": "max-age=31536000",
      "x-frame-options": "SAMEORIGIN",
    });

    const client = buildClientHeaders(upstream, BACKEND_ORIGIN);

    expect(names(client)).toEqual(["content-type", "x-content-type-options"]);
  });

  it("本文の長さ・符号化のヘッダ（Content-Length・Content-Encoding・Transfer-Encoding）と、ホップ間ヘッダを返さない（本文は、復号済みで届くため）", () => {
    const upstream = new Headers({
      "content-type": "application/json",
      "content-length": "123",
      "content-encoding": "gzip",
      "transfer-encoding": "chunked",
      connection: "keep-alive",
      "keep-alive": "timeout=5",
    });

    const client = buildClientHeaders(upstream, BACKEND_ORIGIN);

    expect(client.has("content-length")).toBe(false);
    expect(client.has("content-encoding")).toBe(false);
    expect(client.has("transfer-encoding")).toBe(false);
    expect(client.has("connection")).toBe(false);
    expect(client.has("keep-alive")).toBe(false);
  });

  it("MIME の推測を止める X-Content-Type-Options: nosniff を付ける（バックエンドの保護の代わり）", () => {
    expect(buildClientHeaders(new Headers(), BACKEND_ORIGIN).get("x-content-type-options")).toBe("nosniff");
  });
});

describe("buildClientHeaders: Location（リダイレクトを追わず、そのまま返す）", () => {
  it.each([
    ["公開オリジンの絶対 URL", "https://app.example.test/?login_error=oauth_failed"],
    ["相対のパス", "/account?connect=connected"],
    ["Google の認可 URL", "https://accounts.google.com/o/oauth2/v2/auth?client_id=dummy"],
  ])("%s は、そのまま返す", (_title, location) => {
    expect(buildClientHeaders(new Headers({ location }), BACKEND_ORIGIN).get("location")).toBe(location);
  });

  it.each([
    ["バックエンドのホストの絶対 URL", "https://backend.internal.example/studio"],
    ["ポートが違う同じホスト", "https://backend.internal.example:8443/studio"],
    ["スキームが違う同じホスト", "http://backend.internal.example/studio"],
    ["大文字小文字の違い", "HTTPS://BACKEND.INTERNAL.EXAMPLE/studio"],
    ["ユーザー情報つき", "https://user@backend.internal.example/studio"],
  ])("内部の URL を返さない: %s は、例外にする", (_title, location) => {
    expect(() => buildClientHeaders(new Headers({ location }), BACKEND_ORIGIN)).toThrow(UpstreamLocationError);
  });

  it("例外のメッセージに、Location の値（内部の URL）を含めない", () => {
    expect.assertions(2);
    try {
      buildClientHeaders(new Headers({ location: "https://backend.internal.example/secret-path" }), BACKEND_ORIGIN);
    } catch (error) {
      expect((error as Error).message).not.toContain("secret-path");
      expect((error as Error).message).not.toContain("backend.internal.example");
    }
  });

  it("解釈できない Location は、そのまま返さず、例外にする（不明な値を成功として通さない）", () => {
    expect(() => buildClientHeaders(new Headers({ location: "http://[::1" }), BACKEND_ORIGIN)).toThrow(UpstreamLocationError);
  });
});
