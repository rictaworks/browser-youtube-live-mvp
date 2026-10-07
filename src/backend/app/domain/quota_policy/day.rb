# frozen_string_literal: true

module QuotaPolicy
  # 割り当て台帳の 1 日（割り当て日ごとの合計）。requirements.md 20.1 の quota_days に当たる値。
  #   quota_date          割り当て日（太平洋時間の日付）
  #   used_units          配信の使用済み（配信の予約から支出した実費の合計）
  #   reserved_units      予約中（配信の予約の残額の合計。負にならない）
  #   common_used_units   共通枠の使用済み（配信に属さない呼び出しの実費の合計。共通枠 500 まで）
  #   exhausted           割り当て超過の印。台帳の計上に反して、YouTube から割り当て超過が返った日は true（既定 false）。
  #                       true の日は、当該割り当て日の終わりまで、新規の予約を受け付けない（8.4）。進行中の配信の記帳・解放は続ける
  class Day < Data.define(:quota_date, :used_units, :reserved_units, :common_used_units, :exhausted)
    def initialize(quota_date:, used_units:, reserved_units:, common_used_units:, exhausted: false)
      Preconditions.date!(quota_date, "quota_date")
      Preconditions.integer!(used_units, "used_units", min: 0)
      Preconditions.integer!(reserved_units, "reserved_units", min: 0)
      Preconditions.integer!(common_used_units, "common_used_units", min: 0)
      Preconditions.boolean!(exhausted, "exhausted")
      super
    end
  end
end
