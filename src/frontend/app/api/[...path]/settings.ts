import { resolveAppEnvironment, UnknownAppEnvironmentError, type AppEnvironment } from "@/lib/app-environment";
import { BFF_ENV_NAMES } from "./config";

export interface BffSettings {
  /** バックエンドの origin（スキームとホスト。末尾のスラッシュ・経路を含まない） */
  readonly backendOrigin: string;
  /** フロントエンドとアプリケーションの共有の秘密値（X-BFF-Secret の値）。ログ・応答へ出さない */
  readonly sharedSecret: string;
  readonly environment: AppEnvironment;
}

/** 設定の不備。欠けている・不正な環境変数の「名前だけ」を持つ（値を、メッセージ・応答・ログへ出さない） */
export class BffConfigError extends Error {
  readonly missing: readonly string[];
  readonly invalid: readonly string[];

  constructor(missing: readonly string[], invalid: readonly string[]) {
    super(`BFF configuration error: missing [${missing.join(", ")}]; invalid [${invalid.join(", ")}]`);
    this.name = "BffConfigError";
    this.missing = missing;
    this.invalid = invalid;
  }
}

type EnvironmentVariables = Readonly<Record<string, string | undefined>>;

// 平文の http を、本番でも許す宛先（同じ計算機の内側。URL のホスト名の表記: IPv6 は角括弧つき）
const LOOPBACK_HOSTNAMES: readonly string[] = ["localhost", "127.0.0.1", "[::1]"];

// 印字できる ASCII（空白を含む）で、前後に空白が無い。ヘッダの値として、そのまま送れる形に限る
// （制御文字を含む値は、ヘッダの組み立てで失敗し、その例外の文面に値が現れうるため、設定の段階で弾く）
const SECRET_PATTERN = /^[\x21-\x7E](?:[\x20-\x7E]*[\x21-\x7E])?$/;

function isBlank(value: string | undefined): boolean {
  return value === undefined || value.trim() === "";
}

/** スキームとホストだけの URL を、origin にそろえる。不正なら null */
function normalizeBackendOrigin(value: string, environment: AppEnvironment | null): string | null {
  let url: URL;
  try {
    url = new URL(value.trim());
  } catch {
    return null;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return null;
  }
  if (url.username !== "" || url.password !== "") {
    return null;
  }
  if (url.pathname !== "/" || url.search !== "" || url.hash !== "") {
    return null;
  }
  // 要件 6.1: フロントエンドからアプリケーションへは HTTPS。平文の http は、開発・テストの環境と、
  // 同じ計算機の内側（ループバック。通信が外へ出ない）の宛先だけ
  if (environment === "production" && url.protocol !== "https:" && !LOOPBACK_HOSTNAMES.includes(url.hostname)) {
    return null;
  }
  return url.origin;
}

function detectEnvironment(env: EnvironmentVariables): AppEnvironment | null {
  try {
    return resolveAppEnvironment(env[BFF_ENV_NAMES.nodeEnv]);
  } catch (error) {
    if (error instanceof UnknownAppEnvironmentError) {
      return null;
    }
    throw error;
  }
}

/**
 * 環境変数から、中継の設定を読む。要求のたびに呼ぶ（ビルド時・モジュールの読み込み時に固定しない）。
 * 欠けている・不正な変数があれば、既定の値で続行せず、BffConfigError（名前だけ）にする。開発でも、本番でも、同じ。
 */
export function loadBffSettings(env: EnvironmentVariables): BffSettings {
  const missing: string[] = [];
  const invalid: string[] = [];

  const environment = detectEnvironment(env);
  if (environment === null) {
    invalid.push(BFF_ENV_NAMES.nodeEnv);
  }

  const rawOrigin = env[BFF_ENV_NAMES.backendOrigin];
  let backendOrigin: string | null = null;
  if (isBlank(rawOrigin)) {
    missing.push(BFF_ENV_NAMES.backendOrigin);
  } else {
    backendOrigin = normalizeBackendOrigin(rawOrigin ?? "", environment);
    if (backendOrigin === null) {
      invalid.push(BFF_ENV_NAMES.backendOrigin);
    }
  }

  const rawSecret = env[BFF_ENV_NAMES.sharedSecret];
  let sharedSecret: string | null = null;
  if (isBlank(rawSecret)) {
    missing.push(BFF_ENV_NAMES.sharedSecret);
  } else if (!SECRET_PATTERN.test(rawSecret ?? "")) {
    invalid.push(BFF_ENV_NAMES.sharedSecret);
  } else {
    sharedSecret = rawSecret ?? "";
  }

  if (missing.length > 0 || invalid.length > 0 || environment === null || backendOrigin === null || sharedSecret === null) {
    throw new BffConfigError(missing, invalid);
  }
  return { backendOrigin, sharedSecret, environment };
}
