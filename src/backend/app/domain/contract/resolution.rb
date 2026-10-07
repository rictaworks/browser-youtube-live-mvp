# frozen_string_literal: true

module Contract
  # 列挙 resolution（契約独自の列挙（#3）。拒否の「再試行で解消するか」の区分（9.2））の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module Resolution
    extend ValueSet

    FIX_INPUT = "fix_input"
    LOG_IN = "log_in"
    WAIT = "wait"
    STOP_FIRST = "stop_first"
    CONNECT = "connect"
    RECONNECT = "reconnect"
    ENABLE_LIVE = "enable_live"
    NEXT_USAGE_DAY = "next_usage_day"
    AFTER_RELEASE = "after_release"
    NEXT_MONTH = "next_month"
    NEXT_QUOTA_DAY = "next_quota_day"

    ALL = [
      FIX_INPUT,
      LOG_IN,
      WAIT,
      STOP_FIRST,
      CONNECT,
      RECONNECT,
      ENABLE_LIVE,
      NEXT_USAGE_DAY,
      AFTER_RELEASE,
      NEXT_MONTH,
      NEXT_QUOTA_DAY
    ].freeze
  end
end
