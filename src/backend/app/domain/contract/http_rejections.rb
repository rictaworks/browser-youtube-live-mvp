# frozen_string_literal: true

module Contract
  # 開始の受付の拒否理由 14 種ごとの、判定の順・HTTP ステータス・区分・retry_at の規則
  # （src/contracts/http-rejections.json の複製）。拒否理由の符号は Contract::RejectionReason。
  module HttpRejections
    # 応答の retry_at（再試行の目安時刻）の決め方。none は null。
    RETRY_AT_RULES = [
      "none",
      "rate_limit_window",
      "next_usage_day_start",
      "next_month_start",
      "next_quota_day_start"
    ].freeze

    # 拒否理由 => { "order" => 9.2 の判定順（0〜13）, "http_status" => HTTP ステータス,
    #               "resolution" => 再試行で解消するかの区分, "retry_at_rule" => retry_at の決め方 }
    BY_REASON = {
      "invalid_input" => {
        "order" => 0,
        "http_status" => 422,
        "resolution" => "fix_input",
        "retry_at_rule" => "none"
      }.freeze,
      "not_logged_in" => {
        "order" => 1,
        "http_status" => 401,
        "resolution" => "log_in",
        "retry_at_rule" => "none"
      }.freeze,
      "rate_limited" => {
        "order" => 2,
        "http_status" => 429,
        "resolution" => "wait",
        "retry_at_rule" => "rate_limit_window"
      }.freeze,
      "bot_check_failed" => {
        "order" => 3,
        "http_status" => 403,
        "resolution" => "wait",
        "retry_at_rule" => "none"
      }.freeze,
      "broadcast_in_progress" => {
        "order" => 4,
        "http_status" => 409,
        "resolution" => "stop_first",
        "retry_at_rule" => "none"
      }.freeze,
      "youtube_not_connected" => {
        "order" => 5,
        "http_status" => 409,
        "resolution" => "connect",
        "retry_at_rule" => "none"
      }.freeze,
      "authorization_revoked" => {
        "order" => 6,
        "http_status" => 409,
        "resolution" => "reconnect",
        "retry_at_rule" => "none"
      }.freeze,
      "live_not_enabled" => {
        "order" => 7,
        "http_status" => 409,
        "resolution" => "enable_live",
        "retry_at_rule" => "none"
      }.freeze,
      "allowance_consumed" => {
        "order" => 8,
        "http_status" => 409,
        "resolution" => "next_usage_day",
        "retry_at_rule" => "next_usage_day_start"
      }.freeze,
      "attempts_exhausted" => {
        "order" => 9,
        "http_status" => 409,
        "resolution" => "next_usage_day",
        "retry_at_rule" => "next_usage_day_start"
      }.freeze,
      "intake_paused" => {
        "order" => 10,
        "http_status" => 503,
        "resolution" => "after_release",
        "retry_at_rule" => "none"
      }.freeze,
      "transfer_budget_exceeded" => {
        "order" => 11,
        "http_status" => 503,
        "resolution" => "next_month",
        "retry_at_rule" => "next_month_start"
      }.freeze,
      "capacity_full" => {
        "order" => 12,
        "http_status" => 503,
        "resolution" => "wait",
        "retry_at_rule" => "none"
      }.freeze,
      "quota_insufficient" => {
        "order" => 13,
        "http_status" => 503,
        "resolution" => "next_quota_day",
        "retry_at_rule" => "next_quota_day_start"
      }.freeze
    }.freeze

    # 拒否理由の HTTP ステータスなどを返す。未知の拒否理由は、既定値へ倒さず、KeyError にする。
    def self.fetch(reason)
      BY_REASON.fetch(reason)
    end
  end
end
