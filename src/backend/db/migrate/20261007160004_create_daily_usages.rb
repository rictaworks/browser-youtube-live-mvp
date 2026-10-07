# 利用日ごとの利用枠・開始試行（requirements.md 8.1・8.2・20.1・21 章）。
class CreateDailyUsages < ActiveRecord::Migration[8.1]
  def change
    create_table :daily_usages, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :user_id, null: false # アカウント識別子
      t.date :usage_date, null: false # 利用日（JST 03:00 区切り）
      t.integer :consumed_count, null: false, default: 0 # ライブが確定した回数
      t.integer :attempt_count, null: false, default: 0 # 開始試行の回数
      t.integer :extra_grants, null: false, default: 0 # 手動リセットによる追加

      t.check_constraint "consumed_count >= 0", name: "chk_daily_usages_consumed_count_non_negative"
      t.check_constraint "attempt_count >= 0", name: "chk_daily_usages_attempt_count_non_negative"
      t.check_constraint "extra_grants >= 0", name: "chk_daily_usages_extra_grants_non_negative"
    end

    # 20.2: アカウントと利用日の組で一意（user_id の索引も兼ねる）
    add_index :daily_usages, %i[ user_id usage_date ], unique: true, name: "idx_daily_usages_user_id_usage_date"
  end
end
