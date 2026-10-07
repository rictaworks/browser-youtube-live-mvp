/**
 * @jest-environment node
 */
import { BadHostError, buildUpstreamHeaders, extractClientIp, resolvePublicOrigin } from "./request-headers";

const SECRET = "dummy-bff-secret-0123456789abcdef";

function names(headers: Headers): string[] {
  return Array.from(headers.keys()).sort();
}

describe("extractClientIp: X-Forwarded-For の先頭（実際の接続元）", () => {
  it.each([
    ["203.0.113.9", "203.0.113.9"],
    ["203.0.113.9, 10.0.0.1", "203.0.113.9"],
    [" 203.0.113.9 ,10.0.0.1", "203.0.113.9"],
    ["2001:db8::1", "2001:db8::1"],
    ["2001:db8::1, 203.0.113.9", "2001:db8::1"],
  ])("%j は %s", (value, expected) => {
    expect(extractClientIp(new Headers({ "x-forwarded-for": value }))).toBe(expected);
  });

  it.each([
    ["ヘッダが無い", null],
    ["空", ""],
    ["unknown", "unknown"],
    ["ポート付き", "203.0.113.9:8080"],
    ["範囲外の値", "999.1.1.1"],
    ["IP ではない文字列", "<script>alert(1)</script>"],
    ["先頭が空で、2 番目が IP", ", 203.0.113.9"],
  ])("IP として扱えない値（%s）は、転送しない（null）", (_title, value) => {
    const headers = new Headers();
    if (value !== null) {
      headers.set("x-forwarded-for", value);
    }

    expect(extractClientIp(headers)).toBeNull();
  });
});

describe("resolvePublicOrigin: 公開オリジン（Host ヘッダと環境から作る）", () => {
  it.each([
    ["localhost:3000", "http://localhost:3000/api/state", "development", { host: "localhost:3000", proto: "http" }],
    ["app.example.test", "https://app.example.test/api/state?with_channel=1", "production", { host: "app.example.test", proto: "https" }],
    ["app.example.test:8443", "https://app.example.test:8443/api/state", "production", { host: "app.example.test:8443", proto: "https" }],
    ["[::1]:3000", "http://[::1]:3000/api/state", "test", { host: "[::1]:3000", proto: "http" }],
    ["127.0.0.1:3000", "http://127.0.0.1:3000/api/state", "development", { host: "127.0.0.1:3000", proto: "http" }],
  ] as const)("Host: %s は、%s の環境（%s）で %j", (hostHeader, requestUrl, environment, expected) => {
    expect(resolvePublicOrigin(hostHeader, requestUrl, environment)).toEqual(expected);
  });

  it("ホストは、要求の Host ヘッダ（利用者がアクセスしたドメイン）から取る。Next.js が組み立てた URL のホスト（サーバー自身の名前）を使わない", () => {
    expect(resolvePublicOrigin("app.example.test", "http://localhost:3201/api/state", "production")).toEqual({
      host: "app.example.test",
      proto: "https",
    });
  });

  it("Host ヘッダが無い呼び出し（HTTP サーバーを通らない）では、要求の URL のホストを使う", () => {
    expect(resolvePublicOrigin(null, "https://app.example.test/api/state", "production")).toEqual({ host: "app.example.test", proto: "https" });
    expect(resolvePublicOrigin(null, "http://localhost:3000/api/state", "development")).toEqual({ host: "localhost:3000", proto: "http" });
  });

  it("プロトコルは、環境で決める: 本番は https（Vercel は https だけ）、開発・テストは http。要求の URL のスキームは使わない（X-Forwarded-Proto で、偽れるため）", () => {
    expect(resolvePublicOrigin("app.example.test", "http://app.example.test/api/state", "production").proto).toBe("https");
    expect(resolvePublicOrigin("localhost:3000", "https://localhost:3000/api/state", "development").proto).toBe("http");
    expect(resolvePublicOrigin("localhost:3000", "https://localhost:3000/api/state", "test").proto).toBe("http");
  });

  it.each([
    ["経路を含む", "app.example.test/path"],
    ["空白を含む", "app example.test"],
    ["ユーザー情報を含む", "user@app.example.test"],
    ["空", ""],
    ["ポートが数字でない", "app.example.test:abc"],
    ["ポートが範囲外", "app.example.test:99999"],
    ["引用符を含む", 'app.example.test"'],
    ["山括弧を含む", "app.example.test<script>"],
    ["コンマで複数のホスト", "app.example.test, evil.example"],
  ])("不正な Host ヘッダ（%s）は、BadHostError", (_title, hostHeader) => {
    expect(() => resolvePublicOrigin(hostHeader, "https://app.example.test/api/state", "production")).toThrow(BadHostError);
  });

  it("BadHostError のメッセージに、Host の値を含めない", () => {
    expect.assertions(2);
    try {
      resolvePublicOrigin("evil.example/<script>", "https://app.example.test/api/state", "production");
    } catch (error) {
      expect((error as Error).message).toBe("request Host header is not valid");
      expect((error as Error).message).not.toContain("evil.example");
    }
  });
});

describe("buildUpstreamHeaders: バックエンドへ渡すヘッダ", () => {
  const forwarding = {
    sharedSecret: SECRET,
    clientIp: "203.0.113.9",
    publicOrigin: { host: "app.example.test", proto: "https" },
  } as const;

  const browserHeaders = {
    cookie: "bl_session=dummy-session; theme=dark",
    "x-csrf-token": "dummy-csrf-token",
    "x-bl-client": "web",
    "content-type": "application/json; charset=utf-8",
    accept: "application/json",
    origin: "https://app.example.test",
  };

  it("通すヘッダ（Cookie・X-CSRF-Token・X-BL-Client・Content-Type・Accept・Origin）は、そのまま渡す", () => {
    const upstream = buildUpstreamHeaders(new Headers(browserHeaders), forwarding);

    for (const [name, value] of Object.entries(browserHeaders)) {
      expect(upstream.get(name)).toBe(value);
    }
  });

  it("共有の秘密値（X-BFF-Secret）と、作り直した転送ヘッダ（X-Forwarded-For・Host・Proto）を付ける", () => {
    const upstream = buildUpstreamHeaders(new Headers(browserHeaders), forwarding);

    expect(upstream.get("x-bff-secret")).toBe(SECRET);
    expect(upstream.get("x-forwarded-for")).toBe("203.0.113.9");
    expect(upstream.get("x-forwarded-host")).toBe("app.example.test");
    expect(upstream.get("x-forwarded-proto")).toBe("https");
  });

  it("ブラウザから来た秘密値・転送ヘッダ・Host は信用せず、捨てて、作り直した値にする", () => {
    const upstream = buildUpstreamHeaders(
      new Headers({
        ...browserHeaders,
        "x-bff-secret": "attacker-secret",
        "x-relay-secret": "attacker-relay-secret",
        "x-forwarded-for": "198.51.100.7",
        "x-forwarded-host": "evil.example",
        "x-forwarded-proto": "http",
        "x-forwarded-port": "8080",
        "x-forwarded-prefix": "/evil",
        forwarded: "for=198.51.100.7;host=evil.example;proto=http",
        host: "evil.example",
        "x-real-ip": "198.51.100.7",
        "true-client-ip": "198.51.100.7",
        "cf-connecting-ip": "198.51.100.7",
      }),
      forwarding,
    );

    expect(upstream.get("x-bff-secret")).toBe(SECRET);
    expect(upstream.get("x-forwarded-for")).toBe("203.0.113.9");
    expect(upstream.get("x-forwarded-host")).toBe("app.example.test");
    expect(upstream.get("x-forwarded-proto")).toBe("https");
    expect(upstream.has("x-relay-secret")).toBe(false);
    expect(upstream.has("x-forwarded-port")).toBe(false);
    expect(upstream.has("x-forwarded-prefix")).toBe(false);
    expect(upstream.has("forwarded")).toBe(false);
    expect(upstream.has("host")).toBe(false);
    expect(upstream.has("x-real-ip")).toBe(false);
    expect(upstream.has("true-client-ip")).toBe(false);
    expect(upstream.has("cf-connecting-ip")).toBe(false);
  });

  it("ホップ間ヘッダと、通すと決めたもの以外（Authorization・User-Agent・Referer・Accept-Language など）は渡さない", () => {
    const upstream = buildUpstreamHeaders(
      new Headers({
        ...browserHeaders,
        connection: "keep-alive, x-custom-hop",
        "x-custom-hop": "1",
        "keep-alive": "timeout=5",
        te: "trailers",
        trailer: "x-foo",
        upgrade: "websocket",
        "transfer-encoding": "chunked",
        "proxy-authorization": "Basic dummy",
        "proxy-connection": "keep-alive",
        authorization: "Bearer dummy",
        "user-agent": "dummy-agent",
        referer: "https://app.example.test/",
        "accept-language": "ja",
        "accept-encoding": "gzip",
        "content-length": "999",
        "x-http-method-override": "DELETE",
        "x-custom": "1",
      }),
      forwarding,
    );

    expect(names(upstream)).toEqual(
      [
        "accept",
        "content-type",
        "cookie",
        "origin",
        "x-bff-secret",
        "x-bl-client",
        "x-csrf-token",
        "x-forwarded-for",
        "x-forwarded-host",
        "x-forwarded-proto",
      ].sort(),
    );
  });

  it("接続元の IP が分からないときは、X-Forwarded-For を付けない（別の値で補わない）", () => {
    const upstream = buildUpstreamHeaders(new Headers(browserHeaders), { ...forwarding, clientIp: null });

    expect(upstream.has("x-forwarded-for")).toBe(false);
    expect(upstream.get("x-forwarded-host")).toBe("app.example.test");
    expect(upstream.get("x-bff-secret")).toBe(SECRET);
  });

  it("ブラウザが送らなかった通すヘッダは、付けない", () => {
    const upstream = buildUpstreamHeaders(new Headers({ accept: "application/json" }), forwarding);

    expect(names(upstream)).toEqual(
      ["accept", "x-bff-secret", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto"].sort(),
    );
  });
});
