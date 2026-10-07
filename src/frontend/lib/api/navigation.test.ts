/**
 * @jest-environment node
 */
import { assertSafeAuthorizationUrl, UnsafeAuthorizationUrlError } from "./navigation";

// 認可 URL へ遷移する前の検査。バックエンドの応答でも、遷移先を信じすぎない（javascript: などで、画面のスクリプトを動かさせない）。

const GOOGLE_URL = "https://accounts.google.com/o/oauth2/v2/auth?client_id=dummy&scope=openid&state=dummy-state";
const ORIGIN = "http://localhost:3000";

describe("assertSafeAuthorizationUrl: 本番", () => {
  it("Google の認可の URL（https の accounts.google.com）を、そのまま返す", () => {
    expect(assertSafeAuthorizationUrl(GOOGLE_URL, { environment: "production", currentOrigin: "https://app.example.test" })).toBe(GOOGLE_URL);
  });

  it.each([
    ["http（平文）", "http://accounts.google.com/o/oauth2/v2/auth"],
    ["別のホスト", "https://evil.example/o/oauth2/v2/auth"],
    ["似たホスト（接尾辞）", "https://accounts.google.com.evil.example/o/oauth2/v2/auth"],
    ["似たホスト（前置）", "https://evilaccounts.google.com/o/oauth2/v2/auth"],
    ["ユーザー情報で、別のホストを隠す", "https://accounts.google.com@evil.example/o/oauth2/v2/auth"],
    ["資格情報つき", "https://user:password@accounts.google.com/o/oauth2/v2/auth"],
    ["javascript:", "javascript:alert(1)"],
    ["data:", "data:text/html,<script>alert(1)</script>"],
    ["ポートの指定", "https://accounts.google.com:8443/o/oauth2/v2/auth"],
    ["空", ""],
    ["解釈できない", "https://"],
    ["相対のパス（本番に、疑似の経路は無い）", "/api/dev/google/authorize"],
    ["同じオリジンの別の経路", "https://app.example.test/studio"],
  ])("%s は、拒否する", (_title, url) => {
    expect(() => assertSafeAuthorizationUrl(url, { environment: "production", currentOrigin: "https://app.example.test" })).toThrow(
      UnsafeAuthorizationUrlError,
    );
  });
});

describe("assertSafeAuthorizationUrl: 開発・テスト（疑似の Google）", () => {
  it.each(["development", "test"] as const)("%s では、同じオリジンの /api/dev/ 配下（相対・絶対）を許す", (environment) => {
    expect(assertSafeAuthorizationUrl("/api/dev/google/authorize?state=x", { environment, currentOrigin: ORIGIN })).toBe(
      `${ORIGIN}/api/dev/google/authorize?state=x`,
    );
    expect(assertSafeAuthorizationUrl(`${ORIGIN}/api/dev/google/authorize?state=x`, { environment, currentOrigin: ORIGIN })).toBe(
      `${ORIGIN}/api/dev/google/authorize?state=x`,
    );
  });

  it("Google の認可の URL も許す", () => {
    expect(assertSafeAuthorizationUrl(GOOGLE_URL, { environment: "development", currentOrigin: ORIGIN })).toBe(GOOGLE_URL);
  });

  it.each([
    ["同じオリジンの、/api/dev/ 以外", "/studio"],
    ["同じオリジンの、/api/ の別の経路", "/api/auth/callback"],
    ["別のオリジンの /api/dev/", "http://evil.example:3000/api/dev/google/authorize"],
    ["javascript:", "javascript:alert(1)"],
  ])("%s は、拒否する", (_title, url) => {
    expect(() => assertSafeAuthorizationUrl(url, { environment: "development", currentOrigin: ORIGIN })).toThrow(UnsafeAuthorizationUrlError);
  });
});

describe("UnsafeAuthorizationUrlError", () => {
  it("メッセージに、URL（state・nonce・コードの検証子を含みうる）を含めない", () => {
    expect.assertions(2);
    try {
      assertSafeAuthorizationUrl("https://evil.example/?state=dummy-secret-state", { environment: "production", currentOrigin: ORIGIN });
    } catch (error) {
      expect((error as Error).message).toBe("authorization URL is not allowed");
      expect((error as Error).message).not.toContain("dummy-secret-state");
    }
  });
});
