import { BFF_HEADERS, BFF_NOSNIFF, BFF_RETURNED_RESPONSE_HEADERS } from "./config";

// 相対の Location を解決するための、実在しない基準（.invalid は、予約された、解決されない名前）。
// 相対の Location が、バックエンドのホストと誤って一致しないようにする
const RELATIVE_BASE = "http://relative.invalid";

/** ブラウザへ返せない Location（内部の URL・解釈できない値）。理由の符号だけを持つ（値を、メッセージへ含めない） */
export class UpstreamLocationError extends Error {
  readonly reason: "unparsable" | "backend_host";

  constructor(reason: "unparsable" | "backend_host") {
    super(`upstream Location cannot be returned: ${reason}`);
    this.name = "UpstreamLocationError";
    this.reason = reason;
  }
}

function assertReturnableLocation(location: string, backendOrigin: string): void {
  let resolved: URL;
  try {
    resolved = new URL(location, RELATIVE_BASE);
  } catch {
    throw new UpstreamLocationError("unparsable");
  }
  const backendHost = new URL(backendOrigin).hostname.toLowerCase();
  if (resolved.hostname.toLowerCase() === backendHost) {
    // 契約: Location は、公開オリジンの絶対 URL（バックエンドのホストを含めない）。内部の URL を、ブラウザへ返さない
    throw new UpstreamLocationError("backend_host");
  }
}

/**
 * ブラウザへ返すヘッダを、組み立てる。通すと決めたヘッダだけを返し（Server・X-Powered-By・X-Runtime などの内部情報や、
 * 復号済みの本文と食い違う Content-Length・Content-Encoding は、返さない）、複数の Set-Cookie を、欠落なく、順序を保って返す。
 * X-Content-Type-Options: nosniff は、バックエンドの有無によらず付ける。
 * Location が、バックエンドのホストを指す・解釈できないときは、UpstreamLocationError。
 */
export function buildClientHeaders(upstream: Headers, backendOrigin: string): Headers {
  const client = new Headers();
  for (const name of BFF_RETURNED_RESPONSE_HEADERS) {
    const value = upstream.get(name);
    if (value !== null) {
      client.set(name, value);
    }
  }
  for (const cookie of upstream.getSetCookie()) {
    client.append(BFF_HEADERS.setCookie, cookie);
  }
  client.set(BFF_HEADERS.contentTypeOptions, BFF_NOSNIFF);

  const location = client.get(BFF_HEADERS.location);
  if (location !== null) {
    assertReturnableLocation(location, backendOrigin);
  }
  return client;
}
