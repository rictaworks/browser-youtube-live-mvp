/**
 * @jest-environment node
 */
import { RejectedPathError, resolveUpstreamPath } from "./upstream-path";

// 転送してよい経路は、/api/ 配下だけ。区間（セグメント）は、フレームワークが復号したあとの値で検査する
// （%2e%2e は .. に、%2f は / になって届くため、復号後の値で、区切り・ドット区間・二重のエンコードを弾く）。

describe("resolveUpstreamPath: 転送してよい経路", () => {
  it.each([
    [["state"], "/api/state"],
    [["auth", "login", "start"], "/api/auth/login/start"],
    [["auth", "callback"], "/api/auth/callback"],
    [["youtube", "connect", "start"], "/api/youtube/connect/start"],
    [["account"], "/api/account"],
    [["broadcasts"], "/api/broadcasts"],
    [["broadcasts", "2f6c1d0e-7b5a-4f0e-9a43-5c8f1e2d3a4b"], "/api/broadcasts/2f6c1d0e-7b5a-4f0e-9a43-5c8f1e2d3a4b"],
    [["broadcasts", "2f6c1d0e-7b5a-4f0e-9a43-5c8f1e2d3a4b", "ticket"], "/api/broadcasts/2f6c1d0e-7b5a-4f0e-9a43-5c8f1e2d3a4b/ticket"],
    [["usage-events"], "/api/usage-events"],
    [["state.json"], "/api/state.json"],
  ] as const)("%j は %s", (segments, expected) => {
    expect(resolveUpstreamPath(segments, "production")).toBe(expected);
  });
});

describe("resolveUpstreamPath: 拒否する経路", () => {
  it.each([
    ["区間が無い（/api だけ）", [], "empty"],
    ["区間が undefined", undefined, "empty"],
    ["空の区間（//）", ["state", ""], "invalid_segment"],
    ["先頭が空の区間", ["", "state"], "invalid_segment"],
    ["上の階層へ戻る（..）", ["..", "admin"], "dot_segment"],
    ["途中の ..", ["auth", "..", "..", "admin"], "dot_segment"],
    ["現在の階層（.）", [".", "state"], "dot_segment"],
    ["点だけの区間（...）", ["...", "state"], "dot_segment"],
    ["エンコードされた区切り（%2f を復号した /）", ["auth/login"], "invalid_segment"],
    ["エンコードされた区切り（%5c を復号した \\）", ["auth\\login"], "invalid_segment"],
    ["二重のエンコード（%252e%252e を 1 回復号した %2e%2e）", ["%2e%2e", "admin"], "invalid_segment"],
    ["二重のエンコード（%252f を 1 回復号した %2f）", ["auth%2flogin"], "invalid_segment"],
    ["空白", ["state "], "invalid_segment"],
    ["改行（ヘッダ・ログへの注入）", ["state\r\nX-Evil: 1"], "invalid_segment"],
    ["NUL", ["state" + String.fromCodePoint(0)], "invalid_segment"],
    ["日本語", ["状態"], "invalid_segment"],
    ["クエリ区切り（?）", ["state?x=1"], "invalid_segment"],
    ["フラグメント区切り（#）", ["state#x"], "invalid_segment"],
    ["内部通信の経路（internal）", ["internal", "verify"], "blocked_segment"],
    ["管理画面の経路（admin）", ["admin"], "blocked_segment"],
    ["内部通信の経路（大文字）", ["INTERNAL", "verify"], "blocked_segment"],
  ] as const)("%s", (_title, segments, reason) => {
    expect.assertions(2);
    try {
      resolveUpstreamPath(segments as readonly string[] | undefined, "development");
    } catch (error) {
      expect(error).toBeInstanceOf(RejectedPathError);
      expect((error as RejectedPathError).reason).toBe(reason);
    }
  });
});

describe("resolveUpstreamPath: 開発・テストにだけある経路（/api/dev/）", () => {
  it.each(["development", "test"] as const)("%s では、転送する", (environment) => {
    expect(resolveUpstreamPath(["dev", "google", "authorize"], environment)).toBe("/api/dev/google/authorize");
  });

  it.each([
    [["dev", "google", "authorize"]],
    [["dev"]],
    [["DEV", "google"]],
    [["Dev", "google"]],
  ] as const)("production では、%j を拒否する", (segments) => {
    expect.assertions(2);
    try {
      resolveUpstreamPath(segments, "production");
    } catch (error) {
      expect(error).toBeInstanceOf(RejectedPathError);
      expect((error as RejectedPathError).reason).toBe("dev_route_in_production");
    }
  });

  it("dev で始まらない経路（device）は、production でも転送する", () => {
    expect(resolveUpstreamPath(["device"], "production")).toBe("/api/device");
  });

  it("dev が 2 区間目以降にあるだけの経路は、production でも転送する", () => {
    expect(resolveUpstreamPath(["auth", "dev"], "production")).toBe("/api/auth/dev");
  });
});

describe("RejectedPathError", () => {
  it("拒否した値そのものを、メッセージへ含めない（ログへの注入・内部情報を避ける）", () => {
    const error = new RejectedPathError("invalid_segment");

    expect(error.message).toBe("rejected path: invalid_segment");
    expect(error.name).toBe("RejectedPathError");
  });
});
