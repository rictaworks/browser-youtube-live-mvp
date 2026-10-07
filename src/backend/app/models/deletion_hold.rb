# 削除したアカウントの再登録の保留（requirements.md 7.4・20.1・20.3）。
# Google 識別子の要約値（sub_digest）と、保留の期限（削除時点の利用日）だけを持つ。アカウント識別子は持たない（20.1）。
class DeletionHold < ApplicationRecord
  self.primary_key = "sub_digest"

  validates :sub_digest, presence: true
  validates :hold_usage_date, presence: true
end
