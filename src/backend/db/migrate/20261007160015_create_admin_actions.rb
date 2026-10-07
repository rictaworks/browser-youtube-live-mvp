# 管理操作の記録（requirements.md 19 章・20.1・21 章）。システム全体の表。
# target は対象の内部識別子、detail は符号と数値のみ（トークン・配信キー・タイトルを含めない）。
class CreateAdminActions < ActiveRecord::Migration[8.1]
  def change
    create_table :admin_actions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :action, null: false
      t.string :target
      t.string :detail
      t.datetime :occurred_at, null: false
    end

    add_index :admin_actions, :occurred_at, name: "idx_admin_actions_occurred_at" # 操作の記録を新しい順に並べる
  end
end
