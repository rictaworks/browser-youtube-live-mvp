# frozen_string_literal: true

module QuotaPolicy
  # 記帳できなかった結果。台帳・予約は変わらない（呼び出し側が持つ元の値のまま）。
  #   :ledger_full         予約: 使用済み + 予約中 + 新規の予約が、配信に使える上限を超える
  #   :day_exhausted       予約: 台帳の計上に反して割り当て超過が返った日で、当該割り当て日の終わりまで新規の予約を受け付けない
  #   :bucket_insufficient 支出: 予約のその枠の残額が足りない（別の枠から取り崩さない）
  #   :common_exhausted    共通枠の支出: 共通枠の残額が足りない
  class Refused < Data.define(:reason)
    REASONS = %i[ledger_full day_exhausted bucket_insufficient common_exhausted].freeze

    def initialize(reason:)
      raise ArgumentError, "reason must be one of #{REASONS.inspect}, got #{reason.class}" unless REASONS.include?(reason)

      super
    end

    def granted?
      false
    end
  end
end
