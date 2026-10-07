# 管理操作の記録（requirements.md 19 章・20.1）。システム全体の表。
# target は対象の内部識別子、detail は符号と数値のみ（トークン・配信キー・タイトルを含めない）。
class AdminAction < ApplicationRecord
  validates :action, presence: true
  validates :occurred_at, presence: true
end
