# 制限値・受付停止（requirements.md 8 章・19 章・20.1・21 章）。システム全体の表。主キーは、設定のキー。
# 初期値は DB に入れない（行が無ければ既定値。#5 の Settings）。
class CreateSystemSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :system_settings, id: :string, primary_key: :key do |t|
      t.string :value, null: false
      t.datetime :updated_at, null: false
    end
  end
end
