# アカウント（requirements.md 7.1・20.1）。Google の `sub` だけを持つ。メールアドレス・氏名は取得しない（28.2）。
# 主キーの id が、アカウント識別子（利用者に属するテーブルの user_id が、これを指す）。
#
# 子のレコードの削除は、DB の外部キー（ON DELETE CASCADE / SET NULL。db/migrate/*_add_foreign_keys.rb）が行う。
# 関連に dependent を置かない（アカウントの削除の順序を、アプリケーションに持たせない。7.4）。
class User < ApplicationRecord
  has_many :sessions
  has_one :youtube_connection
  has_many :broadcasts
  has_many :daily_usages
  has_many :relay_tickets
  has_many :health_samples
  has_many :broadcast_events
  has_many :usage_events

  validates :google_sub, presence: true
  validates :last_login_at, presence: true
end
