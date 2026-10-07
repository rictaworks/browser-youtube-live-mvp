# 割り当て日ごとの台帳（requirements.md 8.4・20.1）。システム全体の表。主キーは、割り当て日（太平洋時間の日付）。
# 使用済み・予約中が負にならないことは、DB の CHECK 制約でも保証する（20.2）。
class QuotaDay < ApplicationRecord
  self.primary_key = "quota_date"

  has_many :quota_entries, foreign_key: :quota_date, primary_key: :quota_date, inverse_of: :quota_day

  validates :quota_date, presence: true
  validates :used_units, :reserved_units, :common_used_units,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :exhausted, inclusion: { in: [ true, false ] }
end
