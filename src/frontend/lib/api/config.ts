// API クライアントの設定値。経路・ヘッダ名・待ち時間は、ここへ集める（実装へ直書きしない）。
// 出どころ: src/contracts/http-api.md（1 章: 経路・ヘッダ、3 章: エンドポイント）。

export type HttpMethod = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";

export interface EndpointDefinition {
  readonly method: HttpMethod;
  /** 経路。:id は、配信の識別子の位置 */
  readonly path: string;
  /** ブラウザの遷移（Google からの戻り先）。クライアントの関数を持たない */
  readonly navigation?: true;
}

/** 契約 3 章のすべてのエンドポイント（contract-conformance.test.ts が、契約の見出しと、両方向に一致を保証する） */
export const API_ENDPOINTS = {
  getState: { method: "GET", path: "/api/state" },
  startLogin: { method: "POST", path: "/api/auth/login/start" },
  authCallback: { method: "GET", path: "/api/auth/callback", navigation: true },
  logout: { method: "POST", path: "/api/auth/logout" },
  startYouTubeConnect: { method: "POST", path: "/api/youtube/connect/start" },
  youtubeConnectCallback: { method: "GET", path: "/api/youtube/connect/callback", navigation: true },
  recheckYouTube: { method: "POST", path: "/api/youtube/recheck" },
  disconnectYouTube: { method: "POST", path: "/api/youtube/disconnect" },
  deleteAccount: { method: "DELETE", path: "/api/account" },
  requestStart: { method: "POST", path: "/api/broadcasts" },
  reissueTicket: { method: "POST", path: "/api/broadcasts/:id/ticket" },
  stopBroadcast: { method: "POST", path: "/api/broadcasts/:id/stop" },
  cancelBroadcast: { method: "POST", path: "/api/broadcasts/:id/cancel" },
  getBroadcast: { method: "GET", path: "/api/broadcasts/:id" },
  postUsageEvent: { method: "POST", path: "/api/usage-events" },
} as const satisfies Record<string, EndpointDefinition>;

/** 配信の識別子（経路の :id）の位置を示す目印 */
export const API_ID_PLACEHOLDER = ":id";

/** getState で、チャンネル名も取得するときのクエリ（契約 3 章: with_channel=1） */
export const API_WITH_CHANNEL_QUERY = "with_channel=1";

/**
 * 待ち時間の上限（ミリ秒）。同一オリジン中継（BFF）がバックエンドを待つ上限（30 秒）より長くする。
 * 短いと、中継が返す 502（bad_gateway）を受け取る前に、ブラウザが先に諦める。
 */
export const API_REQUEST_TIMEOUT_MS = 35_000;

export const API_HEADER_NAMES = {
  accept: "Accept",
  contentType: "Content-Type",
  client: "X-BL-Client",
  csrf: "X-CSRF-Token",
} as const;

/** X-BL-Client の値（契約 1.2: web）。状態を変える要求に付ける */
export const API_CLIENT_HEADER_VALUE = "web";

export const API_JSON_MEDIA_TYPE = "application/json";
export const API_JSON_CONTENT_TYPE = "application/json; charset=utf-8";

/** Google の認可の画面のホスト。認可 URL への遷移は、本番では、ここだけを許す */
export const GOOGLE_AUTHORIZATION_HOSTS: readonly string[] = ["accounts.google.com"];

/** 開発・テストにだけある疑似の認可の経路（契約 1.1: /api/dev/ 配下）。同じオリジンの、この配下だけを許す */
export const DEV_AUTHORIZATION_PATH_PREFIX = "/api/dev/";
