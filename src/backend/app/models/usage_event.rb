# 測定イベント（requirements.md 18.2・20.1）。内部のアカウント識別子にのみ紐づけ、氏名・メールアドレス・IP アドレスを含めない。
# アカウントの削除時は、アカウントとの紐づけを外して残す（DB の外部キーが user_id を NULL にする。7.4）。
class UsageEvent < ApplicationRecord
  include OwnerScope

  belongs_to :user, optional: true

  validates :event_type, inclusion: { in: Contract::UsageEventType::ALL }
  validates :occurred_at, presence: true
end
