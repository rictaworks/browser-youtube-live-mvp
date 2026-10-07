import { BFF_HEADERS, BFF_JSON_CONTENT_TYPE, BFF_NO_STORE, BFF_NOSNIFF, type BffErrorCode } from "./config";

/**
 * 中継が自分で返すエラーの応答。契約 1.6 の形（{"error":{"code":"<符号>","details":{...}}}。details は省略できる）。
 * 詳細・URL・内部の情報を載せない。キャッシュさせない。
 */
export function errorResponse(status: number, code: BffErrorCode, details?: Record<string, unknown>): Response {
  const body = details === undefined ? { error: { code } } : { error: { code, details } };
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      [BFF_HEADERS.contentType]: BFF_JSON_CONTENT_TYPE,
      [BFF_HEADERS.cacheControl]: BFF_NO_STORE,
      [BFF_HEADERS.contentTypeOptions]: BFF_NOSNIFF,
    },
  });
}
