/**
 * @jest-environment node
 */
import { readRecaptchaSiteKey } from "./site-key";

// サイトキーは、サーバー側の環境変数 RECAPTCHA_SITE_KEY から読む（NEXT_PUBLIC_ ではない。ビルド時に固定せず、要求のたびに読む）。

describe("readRecaptchaSiteKey", () => {
  it("RECAPTCHA_SITE_KEY の値を返す（前後の空白は除く）", () => {
    expect(readRecaptchaSiteKey({ RECAPTCHA_SITE_KEY: "dummy-site-key" })).toBe("dummy-site-key");
    expect(readRecaptchaSiteKey({ RECAPTCHA_SITE_KEY: "  dummy-site-key\n" })).toBe("dummy-site-key");
  });

  it.each([
    ["未設定", {}],
    ["空文字", { RECAPTCHA_SITE_KEY: "" }],
    ["空白だけ", { RECAPTCHA_SITE_KEY: "   " }],
  ])("%s なら null（キーが無い）", (_title, env) => {
    expect(readRecaptchaSiteKey(env)).toBeNull();
  });

  it("NEXT_PUBLIC_ の付いた変数は、読まない（ビルド時に、ブラウザのコードへ埋め込まれる値にしない）", () => {
    expect(readRecaptchaSiteKey({ NEXT_PUBLIC_RECAPTCHA_SITE_KEY: "dummy-public-key" })).toBeNull();
  });

  it("引数を省略すると、process.env を読む（呼び出しのたびに）", () => {
    const env = process.env as Record<string, string | undefined>;
    const saved = env.RECAPTCHA_SITE_KEY;
    try {
      env.RECAPTCHA_SITE_KEY = "dummy-from-process-env";
      expect(readRecaptchaSiteKey()).toBe("dummy-from-process-env");
      env.RECAPTCHA_SITE_KEY = "dummy-changed";
      expect(readRecaptchaSiteKey()).toBe("dummy-changed");
    } finally {
      if (saved === undefined) {
        delete env.RECAPTCHA_SITE_KEY;
      } else {
        env.RECAPTCHA_SITE_KEY = saved;
      }
    }
  });
});
