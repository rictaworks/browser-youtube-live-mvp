// 受付の拒否理由 14 種ごとの、HTTP ステータスと区分（src/contracts/http-rejections.json の複製）。
// 実行時に src/contracts を読まない。JSON との一致は contract.test.ts が、両方向に保証する。

import { deepFreeze } from "./deep-freeze";
import type { RejectionReason, Resolution } from "./enums";

/** 応答の retry_at（再試行の目安時刻）の決め方。none は null。 */
export const RETRY_AT_RULES = Object.freeze([
  "none",
  "rate_limit_window",
  "next_usage_day_start",
  "next_month_start",
  "next_quota_day_start",
] as const);
export type RetryAtRule = (typeof RETRY_AT_RULES)[number];

export interface HttpRejection {
  /** 9.2 の判定順（0〜13） */
  readonly order: number;
  readonly http_status: number;
  readonly resolution: Resolution;
  readonly retry_at_rule: RetryAtRule;
}

/** 拒否理由（列挙 rejection_reason）ごとの、判定順・HTTP ステータス・区分・retry_at の規則。 */
export const HTTP_REJECTIONS = deepFreeze({
  invalid_input: {
    order: 0,
    http_status: 422,
    resolution: "fix_input",
    retry_at_rule: "none",
  },
  not_logged_in: {
    order: 1,
    http_status: 401,
    resolution: "log_in",
    retry_at_rule: "none",
  },
  rate_limited: {
    order: 2,
    http_status: 429,
    resolution: "wait",
    retry_at_rule: "rate_limit_window",
  },
  bot_check_failed: {
    order: 3,
    http_status: 403,
    resolution: "wait",
    retry_at_rule: "none",
  },
  broadcast_in_progress: {
    order: 4,
    http_status: 409,
    resolution: "stop_first",
    retry_at_rule: "none",
  },
  youtube_not_connected: {
    order: 5,
    http_status: 409,
    resolution: "connect",
    retry_at_rule: "none",
  },
  authorization_revoked: {
    order: 6,
    http_status: 409,
    resolution: "reconnect",
    retry_at_rule: "none",
  },
  live_not_enabled: {
    order: 7,
    http_status: 409,
    resolution: "enable_live",
    retry_at_rule: "none",
  },
  allowance_consumed: {
    order: 8,
    http_status: 409,
    resolution: "next_usage_day",
    retry_at_rule: "next_usage_day_start",
  },
  attempts_exhausted: {
    order: 9,
    http_status: 409,
    resolution: "next_usage_day",
    retry_at_rule: "next_usage_day_start",
  },
  intake_paused: {
    order: 10,
    http_status: 503,
    resolution: "after_release",
    retry_at_rule: "none",
  },
  transfer_budget_exceeded: {
    order: 11,
    http_status: 503,
    resolution: "next_month",
    retry_at_rule: "next_month_start",
  },
  capacity_full: {
    order: 12,
    http_status: 503,
    resolution: "wait",
    retry_at_rule: "none",
  },
  quota_insufficient: {
    order: 13,
    http_status: 503,
    resolution: "next_quota_day",
    retry_at_rule: "next_quota_day_start",
  },
} as const satisfies Record<RejectionReason, HttpRejection>);
