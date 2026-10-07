import { RECAPTCHA_SCRIPT_LOAD_TIMEOUT_MS, RECAPTCHA_SCRIPT_URL } from "./config";
import { RecaptchaLoadError } from "./errors";
import type { GreCaptcha, ScriptLoader } from "./types";

type WindowWithRecaptcha = Window & { grecaptcha?: GreCaptcha };

export interface ScriptLoaderOptions {
  /** 読み込みを待つ上限（ミリ秒）。既定は RECAPTCHA_SCRIPT_LOAD_TIMEOUT_MS */
  readonly timeoutMs?: number;
}

function isReady(candidate: unknown): candidate is GreCaptcha {
  return typeof candidate === "object" && candidate !== null && typeof (candidate as GreCaptcha).ready === "function";
}

function whenReady(grecaptcha: GreCaptcha): Promise<GreCaptcha> {
  return new Promise((resolve) => grecaptcha.ready(() => resolve(grecaptcha)));
}

/**
 * ブラウザで、reCAPTCHA v3 のスクリプト（api.js?render=<サイトキー>）を読み込む関数を作る。
 * 読み込むのは、呼ばれたとき（操作の直前）。すでに grecaptcha があれば、スクリプトを足さずに返す。
 * 失敗（通信の失敗・時間切れ・grecaptcha が現れない）は RecaptchaLoadError にし、失敗した script 要素を残さない（次の呼び出しで、やり直せる）。
 * window・document は、呼ばれたときに参照する（サーバーでの描画の間は、参照しない）。
 */
export function createScriptLoader(options: ScriptLoaderOptions = {}): ScriptLoader {
  const timeoutMs = options.timeoutMs ?? RECAPTCHA_SCRIPT_LOAD_TIMEOUT_MS;

  return (siteKey) => {
    const existing = (window as WindowWithRecaptcha).grecaptcha;
    if (isReady(existing)) {
      return whenReady(existing);
    }
    return new Promise<GreCaptcha>((resolve, reject) => {
      const script = document.createElement("script");
      script.src = `${RECAPTCHA_SCRIPT_URL}?render=${encodeURIComponent(siteKey)}`;
      script.async = true;
      script.defer = true;

      // fail は、タイマーが動いたあと（または、読み込みのイベントの後）に呼ばれるため、timer は、そのとき初期化済み
      const fail = (reason: string): void => {
        clearTimeout(timer);
        script.remove();
        reject(new RecaptchaLoadError(reason));
      };
      const timer = setTimeout(() => fail("timeout"), timeoutMs);

      script.addEventListener("error", () => fail("script_error"));
      script.addEventListener("load", () => {
        const loaded = (window as WindowWithRecaptcha).grecaptcha;
        if (!isReady(loaded)) {
          fail("grecaptcha_missing");
          return;
        }
        clearTimeout(timer);
        resolve(whenReady(loaded));
      });
      document.head.appendChild(script);
    });
  };
}
