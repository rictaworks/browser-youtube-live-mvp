import type { AppEnvironment } from "@/lib/app-environment";
import { RECAPTCHA_DEV_PASS_TOKEN, RECAPTCHA_EXECUTE_TIMEOUT_MS, RECAPTCHA_SITE_KEY_PATTERN, type RecaptchaAction } from "./config";
import { RecaptchaConfigurationError, RecaptchaExecuteError } from "./errors";
import type { GreCaptcha, ScriptLoader } from "./types";

/** bot 判定のトークンを取得するもの。画面は、これだけに依存する（テストで差し替える） */
export interface RecaptchaTokenSource {
  getToken(action: RecaptchaAction): Promise<string>;
}

export interface RecaptchaClientOptions {
  /** サイトキー（公開鍵）。無ければ null・空文字 */
  readonly siteKey: string | null;
  readonly environment: AppEnvironment;
  readonly loadScript: ScriptLoader;
  /** トークンの取得を待つ上限（ミリ秒）。既定は RECAPTCHA_EXECUTE_TIMEOUT_MS */
  readonly executeTimeoutMs?: number;
}

function hasSiteKey(siteKey: string | null): siteKey is string {
  return siteKey !== null && siteKey !== "";
}

/**
 * bot 判定（reCAPTCHA v3）のトークンを取得する（要件 28.1。判定の検証は、アプリケーションがサーバー側で行う）。
 *   - サイトキーがあれば、操作の直前（最初の getToken）にスクリプトを読み込み、行為名を指定して execute する
 *   - 開発・テストで、サイトキーが空のときだけ、疑似のトークン dev-pass を返す
 *   - 本番でサイトキーが無ければ、RecaptchaConfigurationError（黙って続行しない）。形の不正なキーは、環境によらず設定エラー
 * トークンを、ログ・エラーのメッセージへ出さない。
 */
export class RecaptchaClient implements RecaptchaTokenSource {
  readonly #siteKey: string | null;
  readonly #environment: AppEnvironment;
  readonly #loadScript: ScriptLoader;
  readonly #executeTimeoutMs: number;
  #loading: Promise<GreCaptcha> | null = null;

  constructor(options: RecaptchaClientOptions) {
    this.#siteKey = options.siteKey;
    this.#environment = options.environment;
    this.#loadScript = options.loadScript;
    this.#executeTimeoutMs = options.executeTimeoutMs ?? RECAPTCHA_EXECUTE_TIMEOUT_MS;
  }

  async getToken(action: RecaptchaAction): Promise<string> {
    const siteKey = this.#siteKey;
    if (!hasSiteKey(siteKey)) {
      if (this.#environment === "production") {
        throw this.#configurationError("missing");
      }
      return RECAPTCHA_DEV_PASS_TOKEN;
    }
    if (!RECAPTCHA_SITE_KEY_PATTERN.test(siteKey)) {
      throw this.#configurationError("invalid");
    }

    const grecaptcha = await this.#grecaptcha(siteKey);
    return this.#execute(grecaptcha, siteKey, action);
  }

  #configurationError(reason: "missing" | "invalid"): RecaptchaConfigurationError {
    const error = new RecaptchaConfigurationError(reason);
    // 設定の誤りは、利用者の操作では直せない。運用者が、ブラウザのコンソールからも気づけるようにする（値は出さない）
    console.error(`recaptcha: ${error.message}`);
    return error;
  }

  /** スクリプトの読み込みは、成功したら使い回し（同時の呼び出しも、1 回を共有）、失敗したら、次の呼び出しでやり直す */
  #grecaptcha(siteKey: string): Promise<GreCaptcha> {
    if (this.#loading === null) {
      this.#loading = this.#loadScript(siteKey).catch((error: unknown) => {
        this.#loading = null;
        console.error(`recaptcha: script load failed (${error instanceof Error ? error.name : "unknown"})`);
        throw error;
      });
    }
    return this.#loading;
  }

  async #execute(grecaptcha: GreCaptcha, siteKey: string, action: RecaptchaAction): Promise<string> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => reject(new RecaptchaExecuteError("reCAPTCHA execute timed out")), this.#executeTimeoutMs);
    });
    try {
      const token: unknown = await Promise.race([grecaptcha.execute(siteKey, { action }), timeout]);
      if (typeof token !== "string" || token === "") {
        throw new RecaptchaExecuteError("reCAPTCHA returned no token");
      }
      return token;
    } catch (error) {
      if (error instanceof RecaptchaExecuteError) {
        console.error(`recaptcha: ${error.message} (${action})`);
        throw error;
      }
      // 原因は cause に持つ。メッセージ・ログへは、原因の文面（トークンを含みうる）を出さない
      console.error(`recaptcha: execute failed (${action})`);
      throw new RecaptchaExecuteError("reCAPTCHA execute failed", { cause: error });
    } finally {
      clearTimeout(timer);
    }
  }
}
