import {
  UnknownAppEnvironmentError,
  currentAppEnvironment,
  resolveAppEnvironment,
} from "./app-environment";

describe("resolveAppEnvironment", () => {
  it.each([
    ["development", "development"],
    ["test", "test"],
    ["production", "production"],
  ])("%s は %s になる", (nodeEnv, expected) => {
    expect(resolveAppEnvironment(nodeEnv)).toBe(expected);
  });

  it.each([
    ["未設定", undefined],
    ["空文字", ""],
    ["未知の値", "staging"],
    ["大文字", "Production"],
    ["前後の空白", " test"],
    ["短縮形", "prod"],
  ])("%s（%p）は、既定の環境へ倒さず、例外にする", (_label, nodeEnv) => {
    expect(() => resolveAppEnvironment(nodeEnv)).toThrow(UnknownAppEnvironmentError);
  });

  it("例外は、判定できなかった値を持つ", () => {
    try {
      resolveAppEnvironment("staging");
      throw new Error("例外が投げられませんでした");
    } catch (error) {
      expect(error).toBeInstanceOf(UnknownAppEnvironmentError);
      expect((error as UnknownAppEnvironmentError).value).toBe("staging");
    }
  });

  it("例外のメッセージで、値と、使える値を示す", () => {
    expect(() => resolveAppEnvironment("staging")).toThrow(
      'unknown NODE_ENV "staging" (expected one of: development, test, production)',
    );
  });

  it("未設定のメッセージは、未設定であることを示す", () => {
    expect(() => resolveAppEnvironment(undefined)).toThrow(
      "NODE_ENV is not set (expected one of: development, test, production)",
    );
  });
});

describe("currentAppEnvironment", () => {
  it("引数の環境変数の NODE_ENV で判定する", () => {
    expect(currentAppEnvironment({ NODE_ENV: "production" })).toBe("production");
  });

  it("NODE_ENV が無ければ例外にする", () => {
    expect(() => currentAppEnvironment({})).toThrow(UnknownAppEnvironmentError);
  });

  it("引数を省略すると process.env を使う。Jest は NODE_ENV=test で動く", () => {
    expect(currentAppEnvironment()).toBe("test");
  });
});
