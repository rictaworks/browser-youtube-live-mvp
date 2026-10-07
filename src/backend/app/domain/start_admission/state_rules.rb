# frozen_string_literal: true

module StartAdmission
  # 開始受付判定の順 4〜13（アカウントの現況による判定。requirements.md 9.2）。表の並びが、判定順。
  # 最初に該当した理由を返す（利用者自身の状態に起因し、再試行しても解消しない理由が先。システム都合の一時的な理由は後）。
  #
  #   順 4   進行中の配信あり        当該アカウントに、終了していない配信がある
  #   順 5   YouTube 未接続          接続状態が not_connected
  #   順 6   認可失効                接続状態が revoked
  #   順 7   ライブ未有効            接続状態が live_not_enabled
  #   順 8   利用枠消費済み          設定の利用枠 + 追加付与 - 消費数 <= 0（8.1）
  #   順 9   試行上限                当該利用日の開始試行の計上数 >= 開始試行の上限（8.2）
  #   順 10  受付停止                受付停止の設定が有効
  #   順 11  転送量の予算超過        当月の送信転送量の積算が、予算に達している（TransferBudgetPolicy）
  #   順 12  満員                    同時配信数 >= 同時配信数の上限（8.3）
  #   順 13  API 割り当て不足        割り当て台帳に、配信 1 本分の予約の空きがない（QuotaPolicy.can_reserve?）
  module StateRules
    # reason: 拒否理由の符号（契約の rejection_reason）。check: (現況, 設定) を受け取り、該当するとき true を返す関数
    Rule = Data.define(:reason, :check)

    RULES = [
      Rule.new(
        reason: Contract::RejectionReason::BROADCAST_IN_PROGRESS,
        check: ->(snapshot, _settings) { snapshot.broadcast_in_progress }
      ),
      Rule.new(
        reason: Contract::RejectionReason::YOUTUBE_NOT_CONNECTED,
        check: ->(snapshot, _settings) { snapshot.connection_state == Contract::YoutubeConnectionState::NOT_CONNECTED }
      ),
      Rule.new(
        reason: Contract::RejectionReason::AUTHORIZATION_REVOKED,
        check: ->(snapshot, _settings) { snapshot.connection_state == Contract::YoutubeConnectionState::REVOKED }
      ),
      Rule.new(
        reason: Contract::RejectionReason::LIVE_NOT_ENABLED,
        check: ->(snapshot, _settings) { snapshot.connection_state == Contract::YoutubeConnectionState::LIVE_NOT_ENABLED }
      ),
      Rule.new(
        reason: Contract::RejectionReason::ALLOWANCE_CONSUMED,
        check: ->(snapshot, settings) { settings.daily_allowance + snapshot.extra_grants - snapshot.consumed_count <= 0 }
      ),
      Rule.new(
        reason: Contract::RejectionReason::ATTEMPTS_EXHAUSTED,
        check: ->(snapshot, settings) { snapshot.attempt_count >= settings.attempt_limit }
      ),
      Rule.new(
        reason: Contract::RejectionReason::INTAKE_PAUSED,
        check: ->(_snapshot, settings) { settings.intake_paused }
      ),
      Rule.new(
        reason: Contract::RejectionReason::TRANSFER_BUDGET_EXCEEDED,
        check: lambda { |snapshot, settings|
          TransferBudgetPolicy.exceeded?(sent_bytes: snapshot.transfer_sent_bytes, budget_gb: settings.monthly_transfer_budget_gb)
        }
      ),
      Rule.new(
        reason: Contract::RejectionReason::CAPACITY_FULL,
        check: ->(snapshot, settings) { snapshot.concurrent_count >= settings.concurrent_limit }
      ),
      Rule.new(
        reason: Contract::RejectionReason::QUOTA_INSUFFICIENT,
        check: lambda { |snapshot, settings|
          !QuotaPolicy.can_reserve?(snapshot.quota_day, units: QuotaPolicy::RESERVATION_UNITS, daily_total: settings.daily_quota_units)
        }
      )
    ].freeze

    class << self
      # 最初に該当した理由の符号。どれにも該当しなければ nil。
      def first_violation(snapshot, settings)
        RULES.find { |rule| rule.check.call(snapshot, settings) }&.reason
      end
    end
  end
end
