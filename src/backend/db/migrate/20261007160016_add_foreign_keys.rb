# 外部キーと、親の削除時の動作（requirements.md 7.4・14・20.2・21 章）。
#
#   CASCADE   親の削除で、子も削除する。アカウントの削除（users）で、そのアカウントに紐づく全レコードが消える。
#             配信の削除で、その配信の接続チケット・健全性の標本・出来事も消える。
#   SET NULL  親の削除で、子の参照を NULL にして残す。アカウントの削除で、測定イベント（usage_events.user_id）は
#             アカウントとの紐づけを外して残り、割り当ての明細（quota_entries.broadcast_id）は配信との紐づけを外して残る。
#   既定      参照されている間は、親を削除できない（broadcasts.daily_usage_id → daily_usages、
#             quota_entries.quota_date → quota_days）。
#
# 外部キーは、すべてのテーブルを作った後の、この 1 つのマイグレーションに集める（削除時の動作を、1 か所で読めるように）。
# 名前は fk_<テーブル>_<列>（db/structure.sql で、名前が安定する）。
class AddForeignKeys < ActiveRecord::Migration[8.1]
  def change
    # アカウントの削除で、連鎖して削除する（7.4）
    add_foreign_key :sessions, :users, column: :user_id, on_delete: :cascade, name: "fk_sessions_user_id"
    add_foreign_key :youtube_connections, :users, column: :user_id, on_delete: :cascade, name: "fk_youtube_connections_user_id"
    add_foreign_key :broadcasts, :users, column: :user_id, on_delete: :cascade, name: "fk_broadcasts_user_id"
    add_foreign_key :daily_usages, :users, column: :user_id, on_delete: :cascade, name: "fk_daily_usages_user_id"
    add_foreign_key :relay_tickets, :users, column: :user_id, on_delete: :cascade, name: "fk_relay_tickets_user_id"
    add_foreign_key :health_samples, :users, column: :user_id, on_delete: :cascade, name: "fk_health_samples_user_id"
    add_foreign_key :broadcast_events, :users, column: :user_id, on_delete: :cascade, name: "fk_broadcast_events_user_id"

    # 測定イベントは、アカウントとの紐づけを外して残す（7.4）
    add_foreign_key :usage_events, :users, column: :user_id, on_delete: :nullify, name: "fk_usage_events_user_id"

    # 配信は、受理時の利用日の利用実績に計上される（参照されている間は、利用実績を削除できない）
    add_foreign_key :broadcasts, :daily_usages, column: :daily_usage_id, name: "fk_broadcasts_daily_usage_id"

    # 配信の削除で、配信に属する記録を削除する
    add_foreign_key :relay_tickets, :broadcasts, column: :broadcast_id, on_delete: :cascade, name: "fk_relay_tickets_broadcast_id"
    add_foreign_key :health_samples, :broadcasts, column: :broadcast_id, on_delete: :cascade, name: "fk_health_samples_broadcast_id"
    add_foreign_key :broadcast_events, :broadcasts, column: :broadcast_id, on_delete: :cascade, name: "fk_broadcast_events_broadcast_id"

    # 割り当ての明細は、配信との紐づけを外して残す（7.4）。割り当て日は、明細が参照している間、削除できない
    add_foreign_key :quota_entries, :broadcasts, column: :broadcast_id, on_delete: :nullify, name: "fk_quota_entries_broadcast_id"
    add_foreign_key :quota_entries, :quota_days, column: :quota_date, primary_key: :quota_date, name: "fk_quota_entries_quota_date"
  end
end
