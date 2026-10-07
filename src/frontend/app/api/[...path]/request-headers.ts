import { isIP } from "node:net";
import type { AppEnvironment } from "@/lib/app-environment";
import { BFF_FORWARDED_REQUEST_HEADERS, BFF_HEADERS } from "./config";

/** 利用者がアクセスした、公開オリジンのホスト（非既定のポートを含む）とスキーム */
export interface PublicOrigin {
  readonly host: string;
  readonly proto: "http" | "https";
}

export interface UpstreamForwarding {
  readonly sharedSecret: string;
  /** 利用者の IP。分からなければ null（別の値で補わない） */
  readonly clientIp: string | null;
  readonly publicOrigin: PublicOrigin;
}

/**
 * 利用者の IP（頻度制限の計数にだけ使われる）。Vercel が付ける X-Forwarded-For は、実際の接続元を 1 つだけ持つ
 * （外から来た値を、Vercel が上書きする）。複数あれば先頭を使い、IP として解釈できなければ null（転送しない）。
 */
export function extractClientIp(headers: Headers): string | null {
  const value = headers.get(BFF_HEADERS.forwardedFor);
  if (value === null) {
    return null;
  }
  const first = value.split(",", 1)[0].trim();
  return isIP(first) === 0 ? null : first;
}

/** Host ヘッダが、ホスト名（またはアドレス）とポートの形でない。メッセージに、Host の値を含めない */
export class BadHostError extends Error {
  constructor() {
    super("request Host header is not valid");
    this.name = "BadHostError";
  }
}

// ホスト名（英数字・ピリオド・ハイフン）または角括弧つきの IPv6 アドレスと、任意のポート
const HOST_PATTERN = /^(?:[A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(?::(\d{1,5}))?$/;
const MAX_PORT = 65535;

/**
 * 公開オリジン（リダイレクト先の組み立てに、アプリケーションが使う）を、要求から作り直す。
 *   - ホスト: 要求の Host ヘッダ（利用者がアクセスしたドメイン。Vercel は、これと同じ値を X-Forwarded-Host にも入れる）。
 *     Host ヘッダが無い呼び出し（HTTP サーバーを通らない）は、要求の URL のホスト。Next.js が組み立てる URL のホストは、
 *     サーバー自身の名前（localhost など）になりうるため、優先しない
 *   - プロトコル: 環境で決める（本番は https。Vercel は https だけ。開発・テストは http）。要求の URL のスキームと、
 *     ブラウザから来た X-Forwarded-Proto は、使わない（偽れるため）
 * ホストの形が不正なら BadHostError。ブラウザから来た X-Forwarded-Host・X-Forwarded-Proto は、読まない。
 */
export function resolvePublicOrigin(hostHeader: string | null, requestUrl: string, environment: AppEnvironment): PublicOrigin {
  const host = hostHeader ?? new URL(requestUrl).host;
  const match = HOST_PATTERN.exec(host);
  if (match === null || (match[1] !== undefined && Number(match[1]) > MAX_PORT)) {
    throw new BadHostError();
  }
  return { host, proto: environment === "production" ? "https" : "http" };
}

/**
 * バックエンドへ渡すヘッダを、組み立てる。ブラウザのヘッダのうち、通すと決めたものだけを写し
 * （ホップ間ヘッダ・Host・X-BFF-Secret・X-Relay-Secret・X-Forwarded-* などは、写さない）、
 * 共有の秘密値と、転送ヘッダ（X-Forwarded-For・Host・Proto）を、フロントエンドが作り直して付ける。
 */
export function buildUpstreamHeaders(incoming: Headers, forwarding: UpstreamForwarding): Headers {
  const upstream = new Headers();
  for (const name of BFF_FORWARDED_REQUEST_HEADERS) {
    const value = incoming.get(name);
    if (value !== null) {
      upstream.set(name, value);
    }
  }
  upstream.set(BFF_HEADERS.secret, forwarding.sharedSecret);
  if (forwarding.clientIp !== null) {
    upstream.set(BFF_HEADERS.forwardedFor, forwarding.clientIp);
  }
  upstream.set(BFF_HEADERS.forwardedHost, forwarding.publicOrigin.host);
  upstream.set(BFF_HEADERS.forwardedProto, forwarding.publicOrigin.proto);
  return upstream;
}
