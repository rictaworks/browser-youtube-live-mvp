# 健全性の標本（requirements.md 13・20.1）。10 秒間隔。30 日で削除する（20.3）。
class HealthSample < ApplicationRecord
  include OwnerScope

  belongs_to :user
  belongs_to :broadcast

  validates :sampled_at, presence: true
end
