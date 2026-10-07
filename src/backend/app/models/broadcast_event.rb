# 配信中の出来事（requirements.md 13・20.1）。detail は、符号と数値のみ（自由記述の文字列を保存しない）。30 日で削除する（20.3）。
class BroadcastEvent < ApplicationRecord
  include OwnerScope

  belongs_to :user
  belongs_to :broadcast

  validates :event_type, inclusion: { in: Contract::BroadcastEventType::ALL }
  validates :occurred_at, presence: true
end
