# frozen_string_literal: true

module Contract
  # 列挙 setting_key（requirements.md 20.4（制限値・設定）・8 章）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module SettingKey
    extend ValueSet

    DAILY_ALLOWANCE = "daily_allowance"
    ATTEMPT_LIMIT = "attempt_limit"
    CONCURRENT_LIMIT = "concurrent_limit"
    TIME_LIMIT_MINUTES = "time_limit_minutes"
    INTAKE_RATE_PER_HOUR = "intake_rate_per_hour"
    MONTHLY_TRANSFER_BUDGET_GB = "monthly_transfer_budget_gb"
    DAILY_QUOTA_UNITS = "daily_quota_units"
    BOT_SCORE_THRESHOLD = "bot_score_threshold"
    INTAKE_PAUSED = "intake_paused"

    ALL = [
      DAILY_ALLOWANCE,
      ATTEMPT_LIMIT,
      CONCURRENT_LIMIT,
      TIME_LIMIT_MINUTES,
      INTAKE_RATE_PER_HOUR,
      MONTHLY_TRANSFER_BUDGET_GB,
      DAILY_QUOTA_UNITS,
      BOT_SCORE_THRESHOLD,
      INTAKE_PAUSED
    ].freeze
  end
end
