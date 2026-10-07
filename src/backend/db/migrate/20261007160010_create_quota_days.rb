# 割り当て日ごとの台帳（requirements.md 8.4・20.1・21 章）。システム全体の表。主キーは、割り当て日（太平洋時間の日付）。
# 予約中・使用済みは、負にならない（CHECK。20.2）。
class CreateQuotaDays < ActiveRecord::Migration[8.1]
  def change
    create_table :quota_days, id: :date, primary_key: :quota_date do |t|
      t.integer :used_units, null: false, default: 0 # 配信の使用済み
      t.integer :reserved_units, null: false, default: 0 # 配信の予約中
      t.integer :common_used_units, null: false, default: 0 # 共通枠の使用済み
      t.boolean :exhausted, null: false, default: false # 割り当て超過を受けた印

      t.check_constraint "used_units >= 0", name: "chk_quota_days_used_units_non_negative"
      t.check_constraint "reserved_units >= 0", name: "chk_quota_days_reserved_units_non_negative"
      t.check_constraint "common_used_units >= 0", name: "chk_quota_days_common_used_units_non_negative"
    end
  end
end
