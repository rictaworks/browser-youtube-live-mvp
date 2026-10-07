# 割り当ての記帳の明細（requirements.md 8.4・20.1）。システム全体の表。
# broadcast は、配信に属さない呼び出し（共通枠）と、アカウント削除後は空（7.4）。
#
# 列名 method（呼び出しの種別）は、ER 図のとおり。Object#method（リフレクション）と同じ名前のため、
# ActiveRecord が生成する属性のリーダーが Object#method を隠す（entry.method(:name) が、引数の数の誤りで失敗する）。
# そこで、このクラスの method を、引数なしなら列の値を返し、引数ありなら Object#method として働くものにする。
#   entry.method            列 method の値（呼び出しの種別）
#   entry.method(:save)     Object#method（リフレクション。rspec-mocks など、レシーバに method を呼ぶ道具が壊れない）
# 書き込み（create!(method: ...)）・検索（where(method: ...)）・entry[:method] も使える。
class QuotaEntry < ApplicationRecord
  BUCKETS = %w[ prep settle common ].freeze # 準備・確認枠 / 終了・清算枠 / 共通枠
  RESULTS = %w[ ok error ].freeze

  belongs_to :quota_day, foreign_key: :quota_date, primary_key: :quota_date, inverse_of: :quota_entries
  belongs_to :broadcast, optional: true

  validates :method, presence: true
  validates :units, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :result, inclusion: { in: RESULTS }
  validates :bucket, inclusion: { in: BUCKETS }
  validates :called_at, presence: true

  # 引数なし: 列 method の値。引数あり: Object#method（リフレクション）
  def method(*arguments)
    return self[:method] if arguments.empty?

    Kernel.instance_method(:method).bind_call(self, *arguments)
  end
end
