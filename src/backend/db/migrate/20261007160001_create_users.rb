# アカウント（requirements.md 20.1・21 章）。Google の `sub` だけを持つ。メールアドレス・氏名は取得しない（7.1・28.2）。
class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :google_sub, null: false # Google の不透明な利用者識別子
      t.datetime :created_at, null: false
      t.datetime :last_login_at, null: false # アカウントはログインで作られるので、作成の時点で分かっている
    end

    add_index :users, :google_sub, unique: true, name: "idx_users_google_sub" # 20.2: google_sub は一意
  end
end
