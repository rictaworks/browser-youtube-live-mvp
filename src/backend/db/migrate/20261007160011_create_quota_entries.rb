# 割り当ての記帳の明細（requirements.md 8.4・20.1・21 章）。システム全体の表。
# broadcast_id は、配信に属さない呼び出し（共通枠）と、アカウント削除後は空（7.4）。
# 列名 method は、ER 図のとおり（ActiveRecord では、属性のリーダーが生成されない。QuotaEntry#api_method を参照）。
class CreateQuotaEntries < ActiveRecord::Migration[8.1]
  BUCKETS = %w[ prep settle common ].freeze # 準備・確認枠 / 終了・清算枠 / 共通枠
  RESULTS = %w[ ok error ].freeze

  def change
    create_table :quota_entries, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.date :quota_date, null: false
      t.uuid :broadcast_id
      t.string :method, null: false # 呼び出しの種別
      t.integer :units, null: false
      t.string :result, null: false # ok / error の符号
      t.string :bucket, null: false # prep / settle / common
      t.datetime :called_at, null: false

      t.check_constraint "units >= 0", name: "chk_quota_entries_units_non_negative"
      t.check_constraint in_list("bucket", BUCKETS), name: "chk_quota_entries_bucket"
      t.check_constraint in_list("result", RESULTS), name: "chk_quota_entries_result"
    end

    add_index :quota_entries, :quota_date, name: "idx_quota_entries_quota_date"
    add_index :quota_entries, :broadcast_id, name: "idx_quota_entries_broadcast_id"
  end

  private

  # column::text IN (...)。列を text へ明示的に変換する書き方にする。
  # PostgreSQL は、この形の CHECK 制約を、structure.sql へ書き出し、読み込み直して、再び書き出しても、同じ文字列にする。
  # （列を変換せずに IN (...) と書くと、読み込み直したあとの書き出しが、別の（同じ意味の）文字列になり、
  #   structure.sql が、読み込んだ DB から作り直すたびに変わる）
  def in_list(column, values)
    "#{column}::text IN (#{values.map { |value| "'#{value}'" }.join(', ')})"
  end
end
