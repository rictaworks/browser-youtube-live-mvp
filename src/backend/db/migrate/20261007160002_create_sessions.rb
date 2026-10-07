# ログインセッション（requirements.md 7.1・20.1・21 章）。セッション識別子そのものは保存せず、要約値だけを保存する。
class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :user_id, null: false # アカウント識別子
      t.string :token_digest, null: false # セッション識別子の要約値
      t.datetime :created_at, null: false
      t.datetime :last_used_at, null: false
      t.datetime :expires_at, null: false # 最終利用から 30 日（20.3）
    end

    add_index :sessions, :token_digest, unique: true, name: "idx_sessions_token_digest"
    add_index :sessions, :user_id, name: "idx_sessions_user_id"
    add_index :sessions, :expires_at, name: "idx_sessions_expires_at" # 保持期間の適用（20.3）が引く
  end
end
