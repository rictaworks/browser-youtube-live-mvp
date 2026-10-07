import { RecaptchaLoadError } from "./errors";
import { createScriptLoader } from "./script-loader";
import type { GreCaptcha } from "./types";

// reCAPTCHA v3 のスクリプトの読み込み（api.js?render=<サイトキー>）。jsdom は、script を取得しないため、load・error のイベントを、手で発火させる。

const SITE_KEY = "dummy-site-key_0123456789";
const SCRIPT_BASE = "https://www.google.com/recaptcha/api.js";

type WindowWithRecaptcha = Window & { grecaptcha?: GreCaptcha };

function scripts(): HTMLScriptElement[] {
  return Array.from(document.querySelectorAll<HTMLScriptElement>("script[src]"));
}

function readyRecaptcha(): GreCaptcha {
  return { ready: (callback) => callback(), execute: async () => "dummy-token" };
}

function loader(timeoutMs = 1_000) {
  return createScriptLoader({ timeoutMs });
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

afterEach(() => {
  for (const script of scripts()) {
    script.remove();
  }
  delete (window as WindowWithRecaptcha).grecaptcha;
});

describe("createScriptLoader", () => {
  it("script 要素を、api.js?render=<サイトキー> で追加し、load のあと、grecaptcha を返す", async () => {
    const pending = loader()(SITE_KEY);

    expect(scripts()).toHaveLength(1);
    const [script] = scripts();
    expect(script.src).toBe(`${SCRIPT_BASE}?render=${SITE_KEY}`);
    expect(script.async).toBe(true);

    const grecaptcha = readyRecaptcha();
    (window as WindowWithRecaptcha).grecaptcha = grecaptcha;
    script.dispatchEvent(new Event("load"));

    await expect(pending).resolves.toBe(grecaptcha);
  });

  it("grecaptcha.ready のコールバックが呼ばれるまで、返さない", async () => {
    const callbacks: Array<() => void> = [];
    const grecaptcha: GreCaptcha = { ready: (callback) => callbacks.push(callback), execute: async () => "dummy-token" };
    const pending = loader()(SITE_KEY);
    let resolved = false;
    pending.then(() => {
      resolved = true;
    });

    (window as WindowWithRecaptcha).grecaptcha = grecaptcha;
    scripts()[0].dispatchEvent(new Event("load"));
    await Promise.resolve();
    await Promise.resolve();
    expect(resolved).toBe(false);

    callbacks[0]();
    await expect(pending).resolves.toBe(grecaptcha);
  });

  it("サイトキーは、URL へ入れる前にエンコードする（クエリを壊さない）", () => {
    void loader()("abc&render=evil").catch(() => undefined);

    expect(scripts()[0].src).toBe(`${SCRIPT_BASE}?render=abc%26render%3Devil`);
  });

  it("読み込みに失敗したら（error）、RecaptchaLoadError。失敗した script 要素を残さず、次の呼び出しで、読み込みをやり直せる", async () => {
    const first = loader()(SITE_KEY);
    scripts()[0].dispatchEvent(new Event("error"));

    await expect(first).rejects.toBeInstanceOf(RecaptchaLoadError);
    expect(scripts()).toHaveLength(0);

    const second = loader()(SITE_KEY);
    expect(scripts()).toHaveLength(1);
    const grecaptcha = readyRecaptcha();
    (window as WindowWithRecaptcha).grecaptcha = grecaptcha;
    scripts()[0].dispatchEvent(new Event("load"));
    await expect(second).resolves.toBe(grecaptcha);
  });

  it("load のあとも grecaptcha が無ければ、RecaptchaLoadError", async () => {
    const pending = loader()(SITE_KEY);

    scripts()[0].dispatchEvent(new Event("load"));

    await expect(pending).rejects.toBeInstanceOf(RecaptchaLoadError);
    expect(scripts()).toHaveLength(0);
  });

  it("設定の時間（timeoutMs）で読み込めなければ、RecaptchaLoadError（時間切れ）。script 要素を残さない", async () => {
    const pending = loader(30)(SITE_KEY);

    await expect(pending).rejects.toThrow("reCAPTCHA script load failed: timeout");
    expect(scripts()).toHaveLength(0);
  });

  it("すでに grecaptcha が読み込まれていれば、script を追加せず、そのまま返す", async () => {
    const grecaptcha = readyRecaptcha();
    (window as WindowWithRecaptcha).grecaptcha = grecaptcha;

    await expect(loader()(SITE_KEY)).resolves.toBe(grecaptcha);

    expect(scripts()).toHaveLength(0);
  });

  it("RecaptchaLoadError のメッセージは、原因の符号だけを持つ（URL・サイトキーを含めない）", async () => {
    const pending = loader()(SITE_KEY);
    scripts()[0].dispatchEvent(new Event("error"));

    const error = await rejectionOf(pending);

    expect(error.message).toBe("reCAPTCHA script load failed: script_error");
    expect(error.message).not.toContain(SITE_KEY);
  });
});
