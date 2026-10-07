import {
  API_CLIENT_HEADER_VALUE,
  API_ENDPOINTS,
  API_HEADER_NAMES,
  API_ID_PLACEHOLDER,
  API_JSON_CONTENT_TYPE,
  API_JSON_MEDIA_TYPE,
  API_REQUEST_TIMEOUT_MS,
  API_WITH_CHANNEL_QUERY,
  type EndpointDefinition,
  type HttpMethod,
} from "./config";
import {
  ApiAbortedError,
  ApiNetworkError,
  ApiRejected,
  ApiTimeoutError,
  createApiError,
  MissingCsrfTokenError,
  UnexpectedResponse,
} from "./errors";
import {
  parseAuthorizationStart,
  parseBroadcastEnvelope,
  parseErrorEnvelope,
  parseRejectedEnvelope,
  parseStartAccepted,
  parseStateResponse,
  parseTicketIssued,
  parseYoutubeEnvelope,
} from "./parsers";
import type {
  AuthorizationStart,
  BroadcastView,
  CancelReason,
  StartAccepted,
  StartRequest,
  StateResponse,
  TicketIssued,
  UsageEventRequest,
  YoutubeView,
} from "./types";
import { ShapeError } from "./validate";

/** fetch へ渡す引数（Request の初期化。テストで検査しやすいよう、使う項目だけを持つ） */
export interface ApiRequestInit {
  readonly method: HttpMethod;
  readonly headers: Readonly<Record<string, string>>;
  readonly body?: string;
  readonly credentials: "same-origin";
  readonly cache: "no-store";
  readonly signal: AbortSignal;
}

/** fetch の応答のうち、使う項目だけ（本物の Response は、これを満たす） */
export interface ApiResponseLike {
  readonly status: number;
  readonly headers: { get(name: string): string | null };
  text(): Promise<string>;
}

/** 注入できる fetch（テストで差し替える） */
export type ApiFetch = (input: string, init: ApiRequestInit) => Promise<ApiResponseLike>;

export interface ApiClientOptions {
  /** 既定は、呼び出しのたびに、グローバルの fetch を使う */
  readonly fetch?: ApiFetch;
  /** 待ち時間の上限（ミリ秒）。既定は API_REQUEST_TIMEOUT_MS */
  readonly timeoutMs?: number;
}

export interface RequestOptions {
  /** 呼び出し側から中断する（画面を離れたときなど）。中断すると ApiAbortedError */
  readonly signal?: AbortSignal;
}

export interface GetStateOptions extends RequestOptions {
  /** チャンネル名も取得する（アカウント画面。YouTube を呼ぶことがある） */
  readonly withChannel?: boolean;
}

/** CSRF トークンの要否。required: ログインが要る操作（無ければ、要求を送らずに MissingCsrfTokenError）。optional: あれば付ける */
type CsrfPolicy = "required" | "optional";

interface CallSpec<T> {
  readonly operation: string;
  readonly endpoint: EndpointDefinition;
  readonly path: string;
  readonly body?: unknown;
  readonly csrf: CsrfPolicy;
  readonly successStatus: number;
  readonly parse: (json: unknown) => T;
  /** 受付の拒否（{"rejected":...}）を、ApiRejected として受ける（POST /api/broadcasts だけ） */
  readonly acceptsRejection?: boolean;
}

interface RawResponse {
  readonly status: number;
  readonly contentType: string | null;
  readonly text: string;
}

const NO_CONTENT = 204;

const defaultFetch: ApiFetch = (input, init) => globalThis.fetch(input, init);

function isJsonContentType(contentType: string | null): boolean {
  return contentType !== null && contentType.toLowerCase().startsWith(API_JSON_MEDIA_TYPE);
}

function parseJson(text: string): { ok: true; value: unknown } | { ok: false } {
  try {
    return { ok: true, value: JSON.parse(text) as unknown };
  } catch {
    return { ok: false };
  }
}

function encodeId(id: string): string {
  if (id === "") {
    throw new RangeError("broadcast id must not be empty");
  }
  return encodeURIComponent(id);
}

function withId(endpoint: EndpointDefinition, id: string): string {
  return endpoint.path.replace(API_ID_PLACEHOLDER, encodeId(id));
}

/**
 * 同一オリジンの /api/*（契約 src/contracts/http-api.md）を呼ぶ、型付きのクライアント。
 *   - 状態を変える要求（POST・DELETE）に X-BL-Client: web を付ける。ログイン済みなら、X-CSRF-Token（getState の csrf_token）を付ける。
 *     トークンは、このオブジェクトのメモリにだけ持つ（localStorage・Cookie へ置かない）
 *   - 受付の拒否（ApiRejected）と、通常のエラー（ApiError。401・403 csrf_invalid は NotLoggedInError・CsrfInvalidError）を、型で区別する
 *   - 契約に無い応答（JSON でない・形が違う・未知の符号）は、UnexpectedResponse。成功にしない（フォールバック禁止）
 *   - 通信の失敗・時間切れ・中断は、ApiNetworkError・ApiTimeoutError・ApiAbortedError
 */
export class ApiClient {
  readonly #fetch: ApiFetch;
  readonly #timeoutMs: number;
  #csrfToken: string | null = null;

  constructor(options: ApiClientOptions = {}) {
    this.#fetch = options.fetch ?? defaultFetch;
    this.#timeoutMs = options.timeoutMs ?? API_REQUEST_TIMEOUT_MS;
  }

  /** CSRF トークンを持っているか（トークンそのものは、取り出せない） */
  get hasCsrfToken(): boolean {
    return this.#csrfToken !== null;
  }

  /** 画面の初期化・状態の取得。ログイン済みなら、CSRF トークンを保持する（未ログインなら、捨てる） */
  async getState(options: GetStateOptions = {}): Promise<StateResponse> {
    const endpoint = API_ENDPOINTS.getState;
    const path = options.withChannel === true ? `${endpoint.path}?${API_WITH_CHANNEL_QUERY}` : endpoint.path;
    const state = await this.#call(
      { operation: "getState", endpoint, path, csrf: "optional", successStatus: 200, parse: parseStateResponse },
      options,
    );
    this.#csrfToken = state.authenticated ? state.csrf_token : null;
    return state;
  }

  /** ログインの開始。Google の認可 URL を返す（遷移は、呼び出し側が、検査してから行う） */
  startLogin(recaptchaToken: string, options: RequestOptions = {}): Promise<AuthorizationStart> {
    return this.#call(
      {
        operation: "startLogin",
        endpoint: API_ENDPOINTS.startLogin,
        path: API_ENDPOINTS.startLogin.path,
        body: { recaptcha_token: recaptchaToken },
        csrf: "optional",
        successStatus: 200,
        parse: parseAuthorizationStart,
      },
      options,
    );
  }

  async logout(options: RequestOptions = {}): Promise<void> {
    await this.#call(
      {
        operation: "logout",
        endpoint: API_ENDPOINTS.logout,
        path: API_ENDPOINTS.logout.path,
        csrf: "required",
        successStatus: NO_CONTENT,
        parse: () => undefined,
      },
      options,
    );
    this.#csrfToken = null;
  }

  /** YouTube 接続の開始。YouTube の権限の認可 URL を返す */
  startYouTubeConnect(recaptchaToken: string, options: RequestOptions = {}): Promise<AuthorizationStart> {
    return this.#call(
      {
        operation: "startYouTubeConnect",
        endpoint: API_ENDPOINTS.startYouTubeConnect,
        path: API_ENDPOINTS.startYouTubeConnect.path,
        body: { recaptcha_token: recaptchaToken },
        csrf: "required",
        successStatus: 200,
        parse: parseAuthorizationStart,
      },
      options,
    );
  }

  /** ライブ配信が有効かの再確認。更新後の YouTube の接続（次に再確認できる時刻を含む）を返す */
  recheckYouTube(options: RequestOptions = {}): Promise<YoutubeView> {
    return this.#call(
      {
        operation: "recheckYouTube",
        endpoint: API_ENDPOINTS.recheckYouTube,
        path: API_ENDPOINTS.recheckYouTube.path,
        csrf: "required",
        successStatus: 200,
        parse: parseYoutubeEnvelope,
      },
      options,
    );
  }

  /** YouTube 接続の解除。解除後の YouTube の接続（未接続）を返す */
  disconnectYouTube(options: RequestOptions = {}): Promise<YoutubeView> {
    return this.#call(
      {
        operation: "disconnectYouTube",
        endpoint: API_ENDPOINTS.disconnectYouTube,
        path: API_ENDPOINTS.disconnectYouTube.path,
        csrf: "required",
        successStatus: 200,
        parse: parseYoutubeEnvelope,
      },
      options,
    );
  }

  async deleteAccount(options: RequestOptions = {}): Promise<void> {
    await this.#call(
      {
        operation: "deleteAccount",
        endpoint: API_ENDPOINTS.deleteAccount,
        path: API_ENDPOINTS.deleteAccount.path,
        csrf: "required",
        successStatus: NO_CONTENT,
        parse: () => undefined,
      },
      options,
    );
    this.#csrfToken = null;
  }

  /** 配信の開始の受付。受理（201）を返す。拒否は ApiRejected（通常のエラーは ApiError） */
  requestStart(request: StartRequest, options: RequestOptions = {}): Promise<StartAccepted> {
    return this.#call(
      {
        operation: "requestStart",
        endpoint: API_ENDPOINTS.requestStart,
        path: API_ENDPOINTS.requestStart.path,
        body: request,
        // 未ログインなら、サーバーが、拒否 not_logged_in（401）で答える。トークンの有無で、要求を止めない
        csrf: "optional",
        successStatus: 201,
        parse: parseStartAccepted,
        acceptsRejection: true,
      },
      options,
    );
  }

  /** 復帰（再接続）のための、新しい接続チケット */
  async reissueTicket(broadcastId: string, options: RequestOptions = {}): Promise<TicketIssued> {
    return this.#call(
      {
        operation: "reissueTicket",
        endpoint: API_ENDPOINTS.reissueTicket,
        path: withId(API_ENDPOINTS.reissueTicket, broadcastId),
        csrf: "required",
        successStatus: 200,
        parse: parseTicketIssued,
      },
      options,
    );
  }

  /** 配信の停止。必ず成功として完了する（冪等）。終了した配信を返す */
  async stopBroadcast(broadcastId: string, options: RequestOptions = {}): Promise<BroadcastView> {
    return this.#call(
      {
        operation: "stopBroadcast",
        endpoint: API_ENDPOINTS.stopBroadcast,
        path: withId(API_ENDPOINTS.stopBroadcast, broadcastId),
        csrf: "required",
        successStatus: 200,
        parse: parseBroadcastEnvelope,
      },
      options,
    );
  }

  /** ライブ確定前の取り消し（回線不足を含む）。利用枠を消費しない */
  async cancelBroadcast(broadcastId: string, reason: CancelReason, options: RequestOptions = {}): Promise<BroadcastView> {
    return this.#call(
      {
        operation: "cancelBroadcast",
        endpoint: API_ENDPOINTS.cancelBroadcast,
        path: withId(API_ENDPOINTS.cancelBroadcast, broadcastId),
        body: { reason },
        csrf: "required",
        successStatus: 200,
        parse: parseBroadcastEnvelope,
      },
      options,
    );
  }

  /** 配信の表示用の情報の取得（終了した配信も取得できる） */
  async getBroadcast(broadcastId: string, options: RequestOptions = {}): Promise<BroadcastView> {
    return this.#call(
      {
        operation: "getBroadcast",
        endpoint: API_ENDPOINTS.getBroadcast,
        path: withId(API_ENDPOINTS.getBroadcast, broadcastId),
        csrf: "optional",
        successStatus: 200,
        parse: parseBroadcastEnvelope,
      },
      options,
    );
  }

  /** ブラウザ側の測定イベントの記録（ベストエフォート。失敗しても、配信を妨げない使い方をする） */
  postUsageEvent(event: UsageEventRequest, options: RequestOptions = {}): Promise<void> {
    return this.#call(
      {
        operation: "postUsageEvent",
        endpoint: API_ENDPOINTS.postUsageEvent,
        path: API_ENDPOINTS.postUsageEvent.path,
        body: event,
        csrf: "required",
        successStatus: NO_CONTENT,
        parse: () => undefined,
      },
      options,
    );
  }

  async #call<T>(spec: CallSpec<T>, options: RequestOptions): Promise<T> {
    const { method } = spec.endpoint;
    const mutating = method !== "GET";
    const headers: Record<string, string> = { [API_HEADER_NAMES.accept]: API_JSON_MEDIA_TYPE };
    if (mutating) {
      headers[API_HEADER_NAMES.client] = API_CLIENT_HEADER_VALUE;
      if (this.#csrfToken !== null) {
        headers[API_HEADER_NAMES.csrf] = this.#csrfToken;
      } else if (spec.csrf === "required") {
        throw new MissingCsrfTokenError(spec.operation);
      }
    }
    let body: string | undefined;
    if (spec.body !== undefined) {
      headers[API_HEADER_NAMES.contentType] = API_JSON_CONTENT_TYPE;
      body = JSON.stringify(spec.body);
    }

    const raw = await this.#send(spec.path, method, headers, body, options.signal);
    if (raw.status === 401) {
      // セッションが切れている。保持しているトークンは、もう使えない
      this.#csrfToken = null;
    }
    if (raw.status === spec.successStatus) {
      return this.#parseSuccess(raw, spec);
    }
    throw this.#toError(raw, spec);
  }

  async #send(
    path: string,
    method: HttpMethod,
    headers: Record<string, string>,
    body: string | undefined,
    userSignal: AbortSignal | undefined,
  ): Promise<RawResponse> {
    // 呼び出し側の信号が、中断済みか（待っている間に変わるため、毎回、読み直す）
    const callerAborted = (): boolean => userSignal?.aborted === true;
    if (callerAborted()) {
      throw new ApiAbortedError();
    }
    const controller = new AbortController();
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, this.#timeoutMs);
    const abortFromCaller = (): void => controller.abort();
    userSignal?.addEventListener("abort", abortFromCaller, { once: true });
    try {
      const response = await this.#fetch(path, {
        method,
        headers,
        ...(body === undefined ? {} : { body }),
        credentials: "same-origin",
        cache: "no-store",
        signal: controller.signal,
      });
      const text = await response.text();
      return { status: response.status, contentType: response.headers.get("content-type"), text };
    } catch (error) {
      if (timedOut) {
        throw new ApiTimeoutError(this.#timeoutMs);
      }
      if (callerAborted()) {
        throw new ApiAbortedError();
      }
      throw new ApiNetworkError(error);
    } finally {
      clearTimeout(timer);
      userSignal?.removeEventListener("abort", abortFromCaller);
    }
  }

  #parseSuccess<T>(raw: RawResponse, spec: CallSpec<T>): T {
    if (raw.status === NO_CONTENT) {
      return spec.parse(undefined);
    }
    if (!isJsonContentType(raw.contentType)) {
      throw new UnexpectedResponse(raw.status, "response is not JSON");
    }
    const json = parseJson(raw.text);
    if (!json.ok) {
      throw new UnexpectedResponse(raw.status, "response body is not valid JSON");
    }
    try {
      return spec.parse(json.value);
    } catch (error) {
      if (error instanceof ShapeError) {
        throw new UnexpectedResponse(raw.status, `response shape mismatch at ${error.path}`);
      }
      throw error;
    }
  }

  #toError(raw: RawResponse, spec: CallSpec<unknown>): Error {
    if (!isJsonContentType(raw.contentType)) {
      return new UnexpectedResponse(raw.status, "error response is not JSON");
    }
    const json = parseJson(raw.text);
    if (!json.ok) {
      return new UnexpectedResponse(raw.status, "error response body is not valid JSON");
    }
    try {
      if (spec.acceptsRejection === true && typeof json.value === "object" && json.value !== null && "rejected" in json.value) {
        const rejected = parseRejectedEnvelope(json.value);
        return new ApiRejected({
          status: raw.status,
          reason: rejected.reason,
          resolution: rejected.resolution,
          retryAt: rejected.retry_at,
          fields: rejected.fields,
        });
      }
      const envelope = parseErrorEnvelope(json.value);
      return createApiError(raw.status, envelope.code, envelope.details);
    } catch (error) {
      if (error instanceof ShapeError) {
        return new UnexpectedResponse(raw.status, `error response shape mismatch at ${error.path}`);
      }
      throw error;
    }
  }
}
