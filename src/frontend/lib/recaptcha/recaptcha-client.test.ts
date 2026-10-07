/**
 * @jest-environment node
 */
import { RECAPTCHA_ACTIONS, RECAPTCHA_DEV_PASS_TOKEN } from "./config";
import { RecaptchaConfigurationError, RecaptchaExecuteError, RecaptchaLoadError } from "./errors";
import { RecaptchaClient } from "./recaptcha-client";
import type { GreCaptcha } from "./types";

// bot 判定（reCAPTCHA v3）のトークン取得。スクリプトの読み込みを注入して、本物の Google へ接続せずに検査する。
// 判定の検証は、アプリケーション（サーバー）が行う。ここは、トークンを取得して返すだけ。

const SITE_KEY = "dummy-site-key_0123456789";
const TOKEN = "dummy-recaptcha-token-value";

function fakeGrecaptcha(execute: GreCaptcha["execute"] = async () => TOKEN): GreCaptcha & { execute: jest.Mock } {
  const mockExecute = jest.fn(execute);
  return { ready: (callback: () => void) => callback(), execute: mockExecute };
}

function clientWith(options: { siteKey: string | null; environment: "development" | "test" | "production"; loadScript?: jest.Mock; timeoutMs?: number }) {
  const loadScript = options.loadScript ?? jest.fn(async () => fakeGrecaptcha());
  return {
    loadScript,
    client: new RecaptchaClient({
      siteKey: options.siteKey,
      environment: options.environment,
      loadScript,
      executeTimeoutMs: options.timeoutMs ?? 1_000,
    }),
  };
}

/** 失敗する呼び出しの、例外を取り出す（成功したら、テストの失敗） */
async function rejectionOf(promise: Promise<unknown>): Promise<Error> {
  try {
    await promise;
  } catch (error) {
    return error as Error;
  }
  throw new Error("an error was expected, but the call succeeded");
}

describe("RecaptchaClient: 行為名", () => {
  it("契約（http-api.md 1.8）の行為名: login・youtube_connect・broadcast_start", () => {
    expect(RECAPTCHA_ACTIONS).toEqual({ login: "login", youtubeConnect: "youtube_connect", broadcastStart: "broadcast_start" });
  });
});

describe("RecaptchaClient: 開発・テストで、サイトキーが空のとき（疑似のトークン）", () => {
  it.each(["development", "test"] as const)("%s では、疑似のトークン dev-pass を返し、スクリプトを読み込まない", async (environment) => {
    const { client, loadScript } = clientWith({ siteKey: null, environment });

    for (const action of Object.values(RECAPTCHA_ACTIONS)) {
      await expect(client.getToken(action)).resolves.toBe(RECAPTCHA_DEV_PASS_TOKEN);
    }
    expect(RECAPTCHA_DEV_PASS_TOKEN).toBe("dev-pass");
    expect(loadScript).not.toHaveBeenCalled();
  });

  it("空文字のサイトキーも、キーが無いものとして扱う", async () => {
    const { client } = clientWith({ siteKey: "", environment: "development" });

    await expect(client.getToken("login")).resolves.toBe("dev-pass");
  });

  it("開発でも、サイトキーがあるときは、疑似のトークンを返さず、本物の取得を行う", async () => {
    const grecaptcha = fakeGrecaptcha();
    const { client, loadScript } = clientWith({ siteKey: SITE_KEY, environment: "development", loadScript: jest.fn(async () => grecaptcha) });

    await expect(client.getToken("login")).resolves.toBe(TOKEN);

    expect(loadScript).toHaveBeenCalledWith(SITE_KEY);
  });
});

describe("RecaptchaClient: 本番で、サイトキーが無いとき（設定エラー。黙って続行しない）", () => {
  it.each([[null], [""]])("サイトキーが %j なら RecaptchaConfigurationError。疑似のトークンを返さず、スクリプトも読み込まない", async (siteKey) => {
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    const { client, loadScript } = clientWith({ siteKey, environment: "production" });

    await expect(client.getToken("login")).rejects.toBeInstanceOf(RecaptchaConfigurationError);

    expect(loadScript).not.toHaveBeenCalled();
    expect(consoleError).toHaveBeenCalledTimes(1);
    consoleError.mockRestore();
  });

  it("エラーは、設定の名前（RECAPTCHA_SITE_KEY）だけを示す", async () => {
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    const { client } = clientWith({ siteKey: null, environment: "production" });

    const error = await rejectionOf(client.getToken("login"));

    expect(error.message).toBe("reCAPTCHA site key is not configured (RECAPTCHA_SITE_KEY)");
    consoleError.mockRestore();
  });
});

describe("RecaptchaClient: サイトキーの形", () => {
  it.each([
    ["引用符を含む", 'abc"def'],
    ["空白を含む", "abc def"],
    ["山括弧を含む", "abc<script>"],
    ["クエリ区切りを含む", "abc&render=evil"],
  ])("不正なサイトキー（%s）は、環境によらず RecaptchaConfigurationError（疑似のトークンへ倒さない）", async (_title, siteKey) => {
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    const { client, loadScript } = clientWith({ siteKey, environment: "development" });

    await expect(client.getToken("login")).rejects.toBeInstanceOf(RecaptchaConfigurationError);

    expect(loadScript).not.toHaveBeenCalled();
    consoleError.mockRestore();
  });
});

describe("RecaptchaClient: トークンの取得（サイトキーがあるとき）", () => {
  it("読み込んだ grecaptcha で、サイトキーと行為名を指定して execute し、トークンを返す", async () => {
    const grecaptcha = fakeGrecaptcha();
    const { client } = clientWith({ siteKey: SITE_KEY, environment: "production", loadScript: jest.fn(async () => grecaptcha) });

    await expect(client.getToken("youtube_connect")).resolves.toBe(TOKEN);

    expect(grecaptcha.execute).toHaveBeenCalledWith(SITE_KEY, { action: "youtube_connect" });
  });

  it("スクリプトは、最初の getToken（操作の直前）で読み込む。作っただけでは読み込まない", async () => {
    const { client, loadScript } = clientWith({ siteKey: SITE_KEY, environment: "production" });

    expect(loadScript).not.toHaveBeenCalled();
    await client.getToken("login");

    expect(loadScript).toHaveBeenCalledTimes(1);
  });

  it("読み込みに成功したら、使い回す（2 回目以降は、読み込まない）。同時の呼び出しも、1 回の読み込みを共有する", async () => {
    const { client, loadScript } = clientWith({ siteKey: SITE_KEY, environment: "production" });

    await Promise.all([client.getToken("login"), client.getToken("login")]);
    await client.getToken("broadcast_start");

    expect(loadScript).toHaveBeenCalledTimes(1);
  });

  it("読み込みに失敗したら RecaptchaLoadError。次の getToken で、読み込みをやり直す", async () => {
    const grecaptcha = fakeGrecaptcha();
    const loadScript = jest.fn<Promise<GreCaptcha>, [string]>();
    loadScript.mockRejectedValueOnce(new RecaptchaLoadError("script_error"));
    loadScript.mockResolvedValueOnce(grecaptcha);
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    const { client } = clientWith({ siteKey: SITE_KEY, environment: "production", loadScript });

    await expect(client.getToken("login")).rejects.toBeInstanceOf(RecaptchaLoadError);
    await expect(client.getToken("login")).resolves.toBe(TOKEN);

    expect(loadScript).toHaveBeenCalledTimes(2);
    consoleError.mockRestore();
  });

  it("execute が失敗したら、RecaptchaExecuteError（原因を保持する）", async () => {
    const cause = new Error("execute failed");
    const grecaptcha = fakeGrecaptcha(async () => {
      throw cause;
    });
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    const { client } = clientWith({ siteKey: SITE_KEY, environment: "production", loadScript: jest.fn(async () => grecaptcha) });

    const error = (await rejectionOf(client.getToken("login"))) as RecaptchaExecuteError;

    expect(error).toBeInstanceOf(RecaptchaExecuteError);
    expect(error.cause).toBe(cause);
    consoleError.mockRestore();
  });

  it.each([[""], [undefined], [null], [123]])("execute が、トークンでない値（%j）を返したら、RecaptchaExecuteError", async (value) => {
    const grecaptcha = fakeGrecaptcha(async () => value as unknown as string);
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    const { client } = clientWith({ siteKey: SITE_KEY, environment: "production", loadScript: jest.fn(async () => grecaptcha) });

    await expect(client.getToken("login")).rejects.toBeInstanceOf(RecaptchaExecuteError);
    consoleError.mockRestore();
  });

  it("execute が返らないとき、設定の時間で RecaptchaExecuteError（時間切れ）", async () => {
    const grecaptcha = fakeGrecaptcha(() => new Promise<string>(() => undefined));
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    const { client } = clientWith({ siteKey: SITE_KEY, environment: "production", loadScript: jest.fn(async () => grecaptcha), timeoutMs: 30 });

    const error = (await rejectionOf(client.getToken("login"))) as RecaptchaExecuteError;

    expect(error).toBeInstanceOf(RecaptchaExecuteError);
    expect(error.message).toBe("reCAPTCHA execute timed out");
    consoleError.mockRestore();
  });
});

describe("RecaptchaClient: トークン・サイトキーの扱い", () => {
  it("取得したトークンを、ログへ出さない（成功のときも、失敗のときも）", async () => {
    const consoleLog = jest.spyOn(console, "log").mockImplementation(() => undefined);
    const consoleWarn = jest.spyOn(console, "warn").mockImplementation(() => undefined);
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    const ok = clientWith({ siteKey: SITE_KEY, environment: "production" });
    const failing = clientWith({
      siteKey: SITE_KEY,
      environment: "production",
      loadScript: jest.fn(async () => fakeGrecaptcha(async () => {
        throw new Error(`failure including ${TOKEN}`);
      })),
    });

    await ok.client.getToken("login");
    await failing.client.getToken("login").catch(() => undefined);

    const logged = JSON.stringify([...consoleLog.mock.calls, ...consoleWarn.mock.calls, ...consoleError.mock.calls].map((args) => args.map(String)));
    expect(logged).not.toContain(TOKEN);
    consoleLog.mockRestore();
    consoleWarn.mockRestore();
    consoleError.mockRestore();
  });

  it("エラーのメッセージに、トークンを含めない", async () => {
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
    const grecaptcha = fakeGrecaptcha(async () => {
      throw new Error(`failure including ${TOKEN}`);
    });
    const { client } = clientWith({ siteKey: SITE_KEY, environment: "production", loadScript: jest.fn(async () => grecaptcha) });

    const error = await rejectionOf(client.getToken("login"));

    expect(error.message).not.toContain(TOKEN);
    consoleError.mockRestore();
  });
});
