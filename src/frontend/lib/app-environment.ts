// 環境の判定（development・test・production）。NODE_ENV で行う。
// 未設定・未知の値は、既定の環境へ倒さず、例外にする。

export const APP_ENVIRONMENTS = ["development", "test", "production"] as const;

export type AppEnvironment = (typeof APP_ENVIRONMENTS)[number];

export class UnknownAppEnvironmentError extends Error {
  readonly value: string | undefined;

  constructor(value: string | undefined) {
    const expected = `(expected one of: ${APP_ENVIRONMENTS.join(", ")})`;
    super(
      value === undefined
        ? `NODE_ENV is not set ${expected}`
        : `unknown NODE_ENV ${JSON.stringify(value)} ${expected}`,
    );
    this.name = "UnknownAppEnvironmentError";
    this.value = value;
  }
}

function isAppEnvironment(value: string): value is AppEnvironment {
  return (APP_ENVIRONMENTS as readonly string[]).includes(value);
}

/** NODE_ENV の値を環境へ対応づける。未設定・未知の値は UnknownAppEnvironmentError。 */
export function resolveAppEnvironment(nodeEnv: string | undefined): AppEnvironment {
  if (nodeEnv !== undefined && isAppEnvironment(nodeEnv)) {
    return nodeEnv;
  }
  throw new UnknownAppEnvironmentError(nodeEnv);
}

/** 環境変数（既定は process.env）の NODE_ENV から、現在の環境を返す。 */
export function currentAppEnvironment(
  env: Readonly<Record<string, string | undefined>> = process.env,
): AppEnvironment {
  return resolveAppEnvironment(env.NODE_ENV);
}
