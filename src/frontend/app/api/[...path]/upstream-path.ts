import type { AppEnvironment } from "@/lib/app-environment";
import {
  BFF_API_PREFIX,
  BFF_BLOCKED_FIRST_SEGMENTS,
  BFF_DEV_ONLY_FIRST_SEGMENT,
  BFF_DOT_ONLY_SEGMENT_PATTERN,
  BFF_SEGMENT_PATTERN,
} from "./config";

export type RejectedPathReason = "empty" | "dot_segment" | "invalid_segment" | "blocked_segment" | "dev_route_in_production";

/** 転送してはならない経路。理由の符号だけを持つ（拒否した値そのものを、メッセージへ含めない） */
export class RejectedPathError extends Error {
  readonly reason: RejectedPathReason;

  constructor(reason: RejectedPathReason) {
    super(`rejected path: ${reason}`);
    this.name = "RejectedPathError";
    this.reason = reason;
  }
}

/**
 * ブラウザの経路（/api/ 配下）の区間から、バックエンドの経路（/api/...）を作る。
 * 区間は、フレームワークが復号したあとの値で検査する: %2e%2e は .. に、%2f は / になって届くため、
 * ドット区間・区切り・二重のエンコード（% が残る）を、すべて弾ける。バックエンドの経路は、検査した区間から組み立て直す。
 *   - 区間が無い・空・許す文字以外を含む・ドットだけ → 拒否
 *   - 先頭が internal・admin → 拒否（BFF を通らない経路。大文字小文字を区別しない）
 *   - 本番で、先頭が dev → 拒否（開発・テストにだけある疑似の経路）
 */
export function resolveUpstreamPath(segments: readonly string[] | undefined, environment: AppEnvironment): string {
  if (segments === undefined || segments.length === 0) {
    throw new RejectedPathError("empty");
  }
  for (const segment of segments) {
    if (BFF_DOT_ONLY_SEGMENT_PATTERN.test(segment)) {
      throw new RejectedPathError("dot_segment");
    }
    if (!BFF_SEGMENT_PATTERN.test(segment)) {
      throw new RejectedPathError("invalid_segment");
    }
  }
  const first = segments[0].toLowerCase();
  if (BFF_BLOCKED_FIRST_SEGMENTS.includes(first)) {
    throw new RejectedPathError("blocked_segment");
  }
  if (environment === "production" && first === BFF_DEV_ONLY_FIRST_SEGMENT) {
    throw new RejectedPathError("dev_route_in_production");
  }
  return `${BFF_API_PREFIX}/${segments.map(encodeURIComponent).join("/")}`;
}
