/**
 * @jest-environment node
 */
import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import RootLayout, { dynamic } from "./layout";

// ルートのレイアウトが、bot 判定のサイトキー（RECAPTCHA_SITE_KEY。サーバー側の環境変数）を RecaptchaProvider へ渡すこと、
// 本番だけ Vercel Web Analytics を追加することの検査。共通のレイアウトの構成は、layout.test.tsx。

jest.mock("next/navigation", () => ({ usePathname: () => "/" }));
jest.mock("@/lib/recaptcha", () => {
  const actual = jest.requireActual("@/lib/recaptcha") as typeof import("@/lib/recaptcha");
  return {
    ...actual,
    // サイトキーが渡ったかを、マークアップで見えるようにする
    RecaptchaProvider: ({ siteKey, children }: { siteKey: string | null; children: ReactNode }) => (
      <div data-recaptcha-site-key={siteKey ?? "none"}>{children}</div>
    ),
  };
});
jest.mock("./web-analytics", () => ({ WebAnalytics: () => <div data-testid="web-analytics" /> }));

const env = process.env as Record<string, string | undefined>;
const saved = { NODE_ENV: env.NODE_ENV, RECAPTCHA_SITE_KEY: env.RECAPTCHA_SITE_KEY };

function setEnv(name: "NODE_ENV" | "RECAPTCHA_SITE_KEY", value: string | undefined): void {
  if (value === undefined) {
    delete env[name];
  } else {
    env[name] = value;
  }
}

afterEach(() => {
  setEnv("NODE_ENV", saved.NODE_ENV);
  setEnv("RECAPTCHA_SITE_KEY", saved.RECAPTCHA_SITE_KEY);
});

function renderLayout(): string {
  return renderToStaticMarkup(
    <RootLayout>
      <p>ページの内容</p>
    </RootLayout>,
  );
}

describe("RootLayout: bot 判定のサイトキー", () => {
  it("毎回評価する（force-dynamic）。サイトキーを、ビルド時に固定しない", () => {
    expect(dynamic).toBe("force-dynamic");
  });

  it("サーバー側の環境変数 RECAPTCHA_SITE_KEY を、RecaptchaProvider へ渡す", () => {
    setEnv("RECAPTCHA_SITE_KEY", "dummy-site-key");

    expect(renderLayout()).toContain('data-recaptcha-site-key="dummy-site-key"');
  });

  it("環境変数は、描画のたびに読む（変えると、次の描画から反映する）", () => {
    setEnv("RECAPTCHA_SITE_KEY", "dummy-first");
    const first = renderLayout();
    setEnv("RECAPTCHA_SITE_KEY", "dummy-second");
    const second = renderLayout();

    expect(first).toContain('data-recaptcha-site-key="dummy-first"');
    expect(second).toContain('data-recaptcha-site-key="dummy-second"');
  });

  it.each([[undefined], [""], ["   "]])("サイトキーが %j なら、null を渡す（キーが無い。開発は疑似のトークン、本番は設定エラーになる）", (value) => {
    setEnv("RECAPTCHA_SITE_KEY", value);

    expect(renderLayout()).toContain('data-recaptcha-site-key="none"');
  });

  it("ページの内容を、RecaptchaProvider の中（main の中）に置く", () => {
    setEnv("RECAPTCHA_SITE_KEY", "dummy-site-key");
    const html = renderLayout();

    const provider = html.indexOf("data-recaptcha-site-key");
    const content = html.indexOf("ページの内容");
    const mainEnd = html.indexOf("</main>");
    expect(provider).toBeGreaterThan(html.indexOf("<main"));
    expect(content).toBeGreaterThan(provider);
    expect(content).toBeLessThan(mainEnd);
  });

  it("サイトキーを、ブラウザへ渡すコードの変数名（NEXT_PUBLIC_）にしない", () => {
    setEnv("RECAPTCHA_SITE_KEY", "dummy-site-key");
    env.NEXT_PUBLIC_RECAPTCHA_SITE_KEY = "dummy-public-key";
    try {
      expect(renderLayout()).toContain('data-recaptcha-site-key="dummy-site-key"');
    } finally {
      delete env.NEXT_PUBLIC_RECAPTCHA_SITE_KEY;
    }
  });
});

describe("RootLayout: Vercel Web Analytics（ページの閲覧の測定。要件 18.2）", () => {
  it("本番では、追加する", () => {
    setEnv("NODE_ENV", "production");

    expect(renderLayout()).toContain('data-testid="web-analytics"');
  });

  it.each(["development", "test"])("%s では、何も追加しない（開発では、何もしない）", (nodeEnv) => {
    setEnv("NODE_ENV", nodeEnv);

    expect(renderLayout()).not.toContain("web-analytics");
  });
});
