# frozen_string_literal: true

module Contract
  # 列挙 rejection_reason（requirements.md 20.4（開始の拒否理由）・9.2。配列の順が 9.2 の順 0〜13）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module RejectionReason
    extend ValueSet

    INVALID_INPUT = "invalid_input"
    NOT_LOGGED_IN = "not_logged_in"
    RATE_LIMITED = "rate_limited"
    BOT_CHECK_FAILED = "bot_check_failed"
    BROADCAST_IN_PROGRESS = "broadcast_in_progress"
    YOUTUBE_NOT_CONNECTED = "youtube_not_connected"
    AUTHORIZATION_REVOKED = "authorization_revoked"
    LIVE_NOT_ENABLED = "live_not_enabled"
    ALLOWANCE_CONSUMED = "allowance_consumed"
    ATTEMPTS_EXHAUSTED = "attempts_exhausted"
    INTAKE_PAUSED = "intake_paused"
    TRANSFER_BUDGET_EXCEEDED = "transfer_budget_exceeded"
    CAPACITY_FULL = "capacity_full"
    QUOTA_INSUFFICIENT = "quota_insufficient"

    ALL = [
      INVALID_INPUT,
      NOT_LOGGED_IN,
      RATE_LIMITED,
      BOT_CHECK_FAILED,
      BROADCAST_IN_PROGRESS,
      YOUTUBE_NOT_CONNECTED,
      AUTHORIZATION_REVOKED,
      LIVE_NOT_ENABLED,
      ALLOWANCE_CONSUMED,
      ATTEMPTS_EXHAUSTED,
      INTAKE_PAUSED,
      TRANSFER_BUDGET_EXCEEDED,
      CAPACITY_FULL,
      QUOTA_INSUFFICIENT
    ].freeze
  end
end
