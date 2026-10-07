# ログインセッション（requirements.md 7.1・20.1）。セッション識別子そのものは保存せず、要約値（token_digest）だけを保存する。
class Session < ApplicationRecord
  include OwnerScope

  belongs_to :user

  validates :token_digest, presence: true
  validates :last_used_at, presence: true
  validates :expires_at, presence: true
end
