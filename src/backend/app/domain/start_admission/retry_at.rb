# frozen_string_literal: true

module StartAdmission
  # 拒否の再試行の目安時刻（retry_at）。決め方は、拒否理由ごとに、契約（http-rejections.json の retry_at_rule）が定める。
  #   none                    なし（nil）
  #   rate_limit_window       頻度の枠が空く時刻（呼び出し側が渡す。RateLimit#retry_at）
  #   next_usage_day_start    次の JST 03:00（次の利用日の始まり）
  #   next_month_start        翌月 1 日 00:00 JST
  #   next_quota_day_start    次の割り当て日の始まり（太平洋時間の 0 時）を、JST で表した時刻
  # 契約に規則が増えたとき、ここで未対応を検知できるよう、規則の一覧は、契約の RETRY_AT_RULES と一致させる（スペックで検査）。
  module RetryAt
    RULES = {
      "none" => ->(_now, _rate_limit) { nil },
      "rate_limit_window" => ->(_now, rate_limit) { rate_limit.retry_at },
      "next_usage_day_start" => ->(now, _rate_limit) { UsageCalendar.next_usage_date_start(now) },
      "next_month_start" => ->(now, _rate_limit) { UsageCalendar.next_month_start(now) },
      "next_quota_day_start" => ->(now, _rate_limit) { UsageCalendar.next_quota_date_start(now) }
    }.freeze

    class << self
      # 拒否理由の再試行の目安時刻（Time または nil）。未知の規則は、KeyError（既定値へ倒さない）。
      def for(reason, now:, rate_limit:)
        RULES.fetch(Contract::HttpRejections.fetch(reason).fetch("retry_at_rule")).call(now, rate_limit)
      end
    end
  end
end
