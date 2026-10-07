// 同一オリジン中継（BFF）の設定値。数値・ヘッダ名・符号・許可の一覧は、ここへ集める（実装へ直書きしない）。
// 出どころ: src/contracts/http-api.md の 1 章（経路・ヘッダ・エラー）、requirements.md の 6.1・28.1・29.4。

/** 転送してよい経路の先頭の区間。ブラウザが呼ぶ API は、すべて /api/ 配下（契約 1.1） */
export const BFF_API_SEGMENT = "api";
export const BFF_API_PREFIX = `/${BFF_API_SEGMENT}`;

/** 環境変数の名前（要件 29.4）。ログ・応答へは、値ではなく、名前だけを出す */
export const BFF_ENV_NAMES = {
  backendOrigin: "BACKEND_ORIGIN",
  sharedSecret: "BFF_SHARED_SECRET",
  nodeEnv: "NODE_ENV",
} as const;

/** 要求の本文の上限（64 KB）。Content-Length の事前検査と、読み込み中の打ち切りの両方で守る */
export const BFF_MAX_BODY_BYTES = 64 * 1024;

/** バックエンドの応答を待つ時間の上限（30 秒）。超えたら 502。route.ts の maxDuration は、これより長くする */
export const BFF_UPSTREAM_TIMEOUT_MS = 30_000;

/**
 * 経路の 1 区間に許す文字。フレームワークが復号したあとの値で検査する。
 * 英数字と . _ ~ - だけ（区切り・%・空白・制御文字・日本語を許さない）。契約の経路（state・auth・broadcasts と UUID など）は、すべて収まる。
 */
export const BFF_SEGMENT_PATTERN = /^[A-Za-z0-9._~-]+$/;

/** 点だけの区間（. と .. と ...）は、階層をたどる指定になりうるため、すべて拒否する */
export const BFF_DOT_ONLY_SEGMENT_PATTERN = /^\.+$/;

/** /api/ 配下でも転送しない先頭の区間（内部通信・管理画面は、BFF を通らない。契約 1.1） */
export const BFF_BLOCKED_FIRST_SEGMENTS: readonly string[] = ["internal", "admin"];

/** 開発・テストの環境にだけある疑似の経路（/api/dev/ 配下）の先頭の区間。本番では転送しない（契約 1.1） */
export const BFF_DEV_ONLY_FIRST_SEGMENT = "dev";

/** 本文を持たない要求のメソッド（本文を読まず、付けない） */
export const BFF_BODYLESS_METHODS: readonly string[] = ["GET", "HEAD"];

/** 本文を持たない応答のステータス（Response に、本文を渡せない） */
export const BFF_NULL_BODY_STATUSES: readonly number[] = [101, 204, 205, 304];

/** 生成・検査するヘッダの名前（小文字） */
export const BFF_HEADERS = {
  secret: "x-bff-secret",
  forwardedFor: "x-forwarded-for",
  forwardedHost: "x-forwarded-host",
  forwardedProto: "x-forwarded-proto",
  setCookie: "set-cookie",
  location: "location",
  contentType: "content-type",
  contentLength: "content-length",
  cacheControl: "cache-control",
  contentTypeOptions: "x-content-type-options",
} as const;

/**
 * ブラウザからバックエンドへ通すヘッダ（契約 1.1・1.4）。これ以外（X-BFF-Secret・X-Relay-Secret・X-Forwarded-*・Forwarded・Host・
 * ホップ間ヘッダ・Authorization など）は、通さない。Origin は、アプリケーションが公開オリジンとの一致を検査する（契約 1.4 の 3）。
 */
export const BFF_FORWARDED_REQUEST_HEADERS: readonly string[] = [
  "cookie",
  "x-csrf-token",
  "x-bl-client",
  "content-type",
  "accept",
  "origin",
];

/**
 * バックエンドからブラウザへ返すヘッダ（Set-Cookie は、複数を保つため、別に扱う）。これ以外（Server・X-Powered-By・X-Runtime・
 * X-Request-Id・Server-Timing・Via・Content-Length・Content-Encoding など）は、返さない。
 */
export const BFF_RETURNED_RESPONSE_HEADERS: readonly string[] = ["content-type", "cache-control", "location", "retry-after"];

export const BFF_JSON_CONTENT_TYPE = "application/json; charset=utf-8";
export const BFF_NO_STORE = "no-store";
export const BFF_NOSNIFF = "nosniff";

/** 中継が自分で返すエラーの符号（契約 1.6。bad_gateway は BFF が返す符号、ほかは汎用の符号） */
export const BFF_ERROR_CODES = {
  badGateway: "bad_gateway",
  notFound: "not_found",
  invalidInput: "invalid_input",
  internalError: "internal_error",
} as const;

export type BffErrorCode = (typeof BFF_ERROR_CODES)[keyof typeof BFF_ERROR_CODES];

/** 中継が自分で返すエラーの HTTP ステータス */
export const BFF_ERROR_STATUS = {
  badGateway: 502,
  badRequest: 400,
  notFound: 404,
  payloadTooLarge: 413,
  internalError: 500,
} as const;

/** ログの 1 行の、経路の表示の長さの上限（拒否した経路は、攻撃者が選べる値のため、切り詰める） */
export const BFF_LOG_PATH_MAX_LENGTH = 200;
