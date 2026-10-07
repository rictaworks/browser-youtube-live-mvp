import { render, screen } from "@testing-library/react";
import { useEffect, useState } from "react";
import { RecaptchaProvider, useRecaptcha } from "./RecaptchaProvider";
import type { RecaptchaTokenSource } from "./recaptcha-client";

// jsdom（NODE_ENV=test）では、サイトキーが空のとき、疑似のトークン dev-pass を返す。

function TokenProbe({ action }: { action: "login" | "youtube_connect" | "broadcast_start" }) {
  const recaptcha = useRecaptcha();
  const [token, setToken] = useState("pending");
  useEffect(() => {
    let active = true;
    recaptcha.getToken(action).then(
      (value) => active && setToken(value),
      (error: unknown) => active && setToken(`error:${error instanceof Error ? error.name : "unknown"}`),
    );
    return () => {
      active = false;
    };
  }, [recaptcha, action]);
  return <p data-testid="token">{token}</p>;
}

describe("RecaptchaProvider", () => {
  it("サイトキーが空の開発・テストの環境では、useRecaptcha().getToken が疑似のトークンを返す", async () => {
    render(
      <RecaptchaProvider siteKey={null}>
        <TokenProbe action="login" />
      </RecaptchaProvider>,
    );

    expect(await screen.findByText("dev-pass")).toBeInTheDocument();
  });

  it("client を渡すと、それを使う（画面のテストで、トークンの取得を差し替える）", async () => {
    const client: RecaptchaTokenSource = { getToken: jest.fn(async (action) => `dummy-token-for-${action}`) };

    render(
      <RecaptchaProvider siteKey={null} client={client}>
        <TokenProbe action="youtube_connect" />
      </RecaptchaProvider>,
    );

    expect(await screen.findByText("dummy-token-for-youtube_connect")).toBeInTheDocument();
    expect(client.getToken).toHaveBeenCalledWith("youtube_connect");
  });

  it("Provider の外で useRecaptcha を呼ぶと、例外にする（既定のクライアントで、続行しない）", () => {
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);

    expect(() => render(<TokenProbe action="login" />)).toThrow("useRecaptcha must be used within RecaptchaProvider");

    consoleError.mockRestore();
  });

  it("不正なサイトキーでは、getToken が設定エラー（RecaptchaConfigurationError）になる", async () => {
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);

    render(
      <RecaptchaProvider siteKey={'bad"key'}>
        <TokenProbe action="login" />
      </RecaptchaProvider>,
    );

    expect(await screen.findByText("error:RecaptchaConfigurationError")).toBeInTheDocument();
    consoleError.mockRestore();
  });
});
