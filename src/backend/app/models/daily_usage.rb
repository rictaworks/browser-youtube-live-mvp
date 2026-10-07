# 利用日ごとの利用枠・開始試行（requirements.md 8.1・8.2・20.1）。アカウントと利用日の組で一意（DB の一意索引）。
class DailyUsage < ApplicationRecord
  include OwnerScope

  belongs_to :user
  has_many :broadcasts

  validates :usage_date, presence: true
  validates :consumed_count, :attempt_count, :extra_grants,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
