# 健全性の標本（requirements.md 13・20.1・21 章）。10 秒間隔。30 日で削除する（20.3）。
# 測定値の列は、ブラウザの状態報告がまだ無いときは空になり得る。
class CreateHealthSamples < ActiveRecord::Migration[8.1]
  def change
    create_table :health_samples, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :user_id, null: false # アカウント識別子
      t.uuid :broadcast_id, null: false
      t.datetime :sampled_at, null: false
      t.integer :sent_kbps
      t.integer :target_kbps
      t.integer :backlog_ms
      t.integer :dropped_video_frames
      t.integer :relay_out_kbps
      t.string :state
    end

    add_index :health_samples, :sampled_at, name: "idx_health_samples_sampled_at" # 保持期間の適用（20.3）が引く
    add_index :health_samples, %i[ broadcast_id sampled_at ], name: "idx_health_samples_broadcast_id_sampled_at"
    add_index :health_samples, :user_id, name: "idx_health_samples_user_id"
  end
end
