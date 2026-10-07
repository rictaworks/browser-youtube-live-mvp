# 接続チケット（requirements.md 11.9・14・20.1・21 章）。要約値だけを保存する（チケットそのものの列を持たない）。
# 使用済みの印（used_at）は、1 度だけ立てられる。UPDATE ... WHERE used_at IS NULL の条件付き更新で、原子的に確保する（20.2）。
class CreateRelayTickets < ActiveRecord::Migration[8.1]
  def change
    create_table :relay_tickets, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :user_id, null: false # アカウント識別子
      t.uuid :broadcast_id, null: false
      t.string :token_digest, null: false # 接続チケットの要約値
      t.integer :epoch, null: false # 発行時点の送出世代
      t.datetime :expires_at, null: false
      t.datetime :used_at # 空の間だけ、確保できる

      t.check_constraint "epoch >= 0", name: "chk_relay_tickets_epoch_non_negative"
    end

    add_index :relay_tickets, :token_digest, unique: true, name: "idx_relay_tickets_token_digest" # 20.2: 要約値は一意
    add_index :relay_tickets, :expires_at, name: "idx_relay_tickets_expires_at" # 失効から 1 日で削除（20.3）
    add_index :relay_tickets, :broadcast_id, name: "idx_relay_tickets_broadcast_id"
    add_index :relay_tickets, :user_id, name: "idx_relay_tickets_user_id"
  end
end
