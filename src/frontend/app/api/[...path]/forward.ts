import {
  BFF_BODYLESS_METHODS,
  BFF_ERROR_CODES,
  BFF_ERROR_STATUS,
  BFF_LOG_PATH_MAX_LENGTH,
  BFF_NULL_BODY_STATUSES,
} from "./config";
import { errorResponse } from "./error-responses";
import { BodyTooLargeError, readLimitedBody } from "./limited-body";
import { BadHostError, buildUpstreamHeaders, extractClientIp, resolvePublicOrigin } from "./request-headers";
import { buildClientHeaders, UpstreamLocationError } from "./response-headers";
import { BffConfigError, loadBffSettings, type BffSettings } from "./settings";
import { RejectedPathError, resolveUpstreamPath } from "./upstream-path";

/** 中継が使う外部の資源。テストで差し替える（本物のバックエンド・環境変数・ログへ依存しない） */
export interface BffDependencies {
  /** 環境変数。要求のたびに読む（モジュールの読み込み時・ビルド時に固定しない） */
  readonly env: () => Readonly<Record<string, string | undefined>>;
  readonly fetch: (input: string, init: RequestInit) => Promise<Response>;
  readonly logger: Pick<Console, "warn" | "error">;
  /** バックエンドの応答を待つ上限（ミリ秒）。超えたら 502 */
  readonly timeoutMs: number;
  /** 要求の本文の上限（バイト）。超えたら 413 */
  readonly maxBodyBytes: number;
}

/** Next.js のルートハンドラの第 2 引数（/api/[...path] の path） */
export interface BffRouteContext {
  readonly params: Promise<{ path?: string[] }>;
}

export type BffHandler = (request: Request, context: BffRouteContext) => Promise<Response>;

/** バックエンドへ到達できない・時間切れ。原因の符号だけを持つ（バックエンドの URL・例外の文面を含めない） */
class UpstreamUnavailableError extends Error {
  readonly kind: string;

  constructor(kind: string) {
    super(`upstream request failed: ${kind}`);
    this.name = "UpstreamUnavailableError";
    this.kind = kind;
  }
}

/** 要求の本文を読めなかった（上限の超過ではない。接続の中断など） */
class RequestBodyUnreadableError extends Error {
  constructor() {
    super("request body could not be read");
    this.name = "RequestBodyUnreadableError";
  }
}

/** 失敗のログ用の、何の要求だったか（メソッドと、検査したあとの経路。クエリは、認可コードを含みうるため、持たない） */
interface AttemptContext {
  readonly method: string;
  path: string | null;
  segments: readonly string[] | undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

/** fetch の失敗の、原因の符号。時間切れは timeout、それ以外は、原因の連鎖にある符号（ECONNREFUSED など）か、例外の名前 */
function describeFetchFailure(error: unknown): string {
  let current: unknown = error;
  for (let depth = 0; depth < 4 && isRecord(current); depth += 1) {
    if (current.name === "TimeoutError") {
      return "timeout";
    }
    if (typeof current.code === "string" && /^[A-Z0-9_]{1,40}$/.test(current.code)) {
      return current.code;
    }
    current = current.cause;
  }
  return isRecord(error) && typeof error.name === "string" ? error.name : typeof error;
}

function describeUnexpected(error: unknown): string {
  if (isRecord(error) && typeof error.name === "string" && typeof error.message === "string") {
    return `${error.name}: ${error.message}`.slice(0, 300);
  }
  return typeof error;
}

/** 拒否した経路を、1 行のログへ載せる形にする（JSON の文字列にして、改行などの制御文字を、そのまま出さない） */
function describeSegments(segments: readonly string[] | undefined): string {
  return JSON.stringify(segments ?? null).slice(0, BFF_LOG_PATH_MAX_LENGTH);
}

async function callUpstream(deps: BffDependencies, url: string, init: RequestInit): Promise<Response> {
  try {
    return await deps.fetch(url, init);
  } catch (error) {
    throw new UpstreamUnavailableError(describeFetchFailure(error));
  }
}

async function readBody(deps: BffDependencies, request: Request): Promise<Uint8Array<ArrayBuffer> | null> {
  if (BFF_BODYLESS_METHODS.includes(request.method)) {
    return null;
  }
  try {
    return await readLimitedBody(request, deps.maxBodyBytes);
  } catch (error) {
    if (error instanceof BodyTooLargeError) {
      throw error;
    }
    throw new RequestBodyUnreadableError();
  }
}

/** バックエンドの応答を、ブラウザへの応答にする。本文は、全部を読み込まず、ストリームのまま渡す */
async function toClientResponse(upstream: Response, method: string, settings: BffSettings): Promise<Response> {
  let headers: Headers;
  try {
    headers = buildClientHeaders(upstream.headers, settings.backendOrigin);
  } catch (error) {
    await upstream.body?.cancel().catch(() => undefined);
    throw error;
  }
  const hasBody = method !== "HEAD" && !BFF_NULL_BODY_STATUSES.includes(upstream.status);
  if (!hasBody) {
    await upstream.body?.cancel().catch(() => undefined);
  }
  return new Response(hasBody ? upstream.body : null, { status: upstream.status, headers });
}

async function forward(
  deps: BffDependencies,
  request: Request,
  context: BffRouteContext,
  attempt: AttemptContext,
): Promise<Response> {
  const settings = loadBffSettings(deps.env());

  attempt.segments = (await context.params).path;
  attempt.path = resolveUpstreamPath(attempt.segments, settings.environment);

  const upstreamUrl = `${settings.backendOrigin}${attempt.path}${new URL(request.url).search}`;
  const headers = buildUpstreamHeaders(request.headers, {
    sharedSecret: settings.sharedSecret,
    clientIp: extractClientIp(request.headers),
    publicOrigin: resolvePublicOrigin(request.headers.get("host"), request.url, settings.environment),
  });
  const body = await readBody(deps, request);

  const upstream = await callUpstream(deps, upstreamUrl, {
    method: request.method,
    headers,
    // 認可コードのコールバックの 302 を、追わずに、ブラウザへ返す
    redirect: "manual",
    // バックエンドの応答を、中継のキャッシュへ残さない
    cache: "no-store",
    signal: AbortSignal.timeout(deps.timeoutMs),
    ...(body === null ? {} : { body }),
  });
  return toClientResponse(upstream, request.method, settings);
}

/** 失敗を、ブラウザへ返す応答と、ログの 1 行にする。応答には、符号だけを載せ、詳細・URL・秘密値を出さない */
function respondToFailure(logger: BffDependencies["logger"], attempt: AttemptContext, error: unknown): Response {
  const where = attempt.path === null ? attempt.method : `${attempt.method} ${attempt.path}`;

  if (error instanceof BffConfigError) {
    // 変数の名前だけ（値は、持っていない）
    logger.error(`bff: ${error.message} (${attempt.method})`);
    return errorResponse(BFF_ERROR_STATUS.internalError, BFF_ERROR_CODES.internalError, {
      missing: [...error.missing],
      invalid: [...error.invalid],
    });
  }
  if (error instanceof RejectedPathError) {
    logger.warn(`bff: rejected path (${attempt.method}): ${error.reason} ${describeSegments(attempt.segments)}`);
    return errorResponse(BFF_ERROR_STATUS.notFound, BFF_ERROR_CODES.notFound);
  }
  if (error instanceof BodyTooLargeError) {
    logger.warn(`bff: request body too large (${where}): limit ${error.limitBytes} bytes`);
    return errorResponse(BFF_ERROR_STATUS.payloadTooLarge, BFF_ERROR_CODES.invalidInput);
  }
  if (error instanceof BadHostError) {
    // Host の値は、攻撃者が選べる文字列のため、ログへ出さない
    logger.warn(`bff: request Host header is not valid (${where})`);
    return errorResponse(BFF_ERROR_STATUS.badRequest, BFF_ERROR_CODES.invalidInput);
  }
  if (error instanceof RequestBodyUnreadableError) {
    logger.warn(`bff: request body unreadable (${where})`);
    return errorResponse(BFF_ERROR_STATUS.badRequest, BFF_ERROR_CODES.invalidInput);
  }
  if (error instanceof UpstreamUnavailableError) {
    logger.error(`bff: upstream request failed (${where}): ${error.kind}`);
    return errorResponse(BFF_ERROR_STATUS.badGateway, BFF_ERROR_CODES.badGateway);
  }
  if (error instanceof UpstreamLocationError) {
    logger.error(`bff: upstream Location cannot be returned (${where}): ${error.reason}`);
    return errorResponse(BFF_ERROR_STATUS.badGateway, BFF_ERROR_CODES.badGateway);
  }
  logger.error(`bff: unexpected error (${where}): ${describeUnexpected(error)}`);
  return errorResponse(BFF_ERROR_STATUS.internalError, BFF_ERROR_CODES.internalError);
}

/**
 * 同一オリジン中継（BFF）のハンドラ。ブラウザの /api/* を、BACKEND_ORIGIN の /api/* へ中継する（requirements.md 6.1・契約 1.1）。
 *   - 共有の秘密値（X-BFF-Secret）を付け、転送ヘッダ（X-Forwarded-For・Host・Proto）を作り直す。ブラウザから来た同名のヘッダは、信用しない
 *   - リダイレクトを追わず、複数の Set-Cookie を欠落なく返す。バックエンドの内部情報のヘッダを返さない
 *   - /api/ 配下の、検査した経路だけを転送する。本文は 64 KB、待ち時間は 30 秒まで
 *   - 到達できない・時間切れは 502 {"error":{"code":"bad_gateway"}}。設定の不備は 500（欠けている変数の名前だけ）
 */
export function createBffHandler(deps: BffDependencies): BffHandler {
  return async (request, context) => {
    const attempt: AttemptContext = { method: request.method, path: null, segments: undefined };
    try {
      return await forward(deps, request, context, attempt);
    } catch (error) {
      return respondToFailure(deps.logger, attempt, error);
    }
  };
}
