# 配信中の出来事（requirements.md 13・20.1・21 章）。30 日で削除する（20.3）。
class CreateBroadcastEvents < ActiveRecord::Migration[8.1]
  # 契約の列挙 broadcast_event_type（20.4）
  EVENT_TYPES = %w[
    accepted verified probe_done provision_started provision_done publish_started live_confirmed source_added source_lost
    fallback_switched bitrate_down bitrate_up video_dropped degraded_started degraded_cleared interrupted resumed
    throttle_directed keyframe_requested youtube_warning time_limit_notice ended settlement_succeeded settlement_failed
  ].freeze

  def change
    create_table :broadcast_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :user_id, null: false # アカウント識別子
      t.uuid :broadcast_id, null: false
      t.datetime :occurred_at, null: false
      t.string :event_type, null: false
      t.string :detail # 符号と数値のみ。自由記述の文字列を保存しない

      t.check_constraint in_list("event_type", EVENT_TYPES), name: "chk_broadcast_events_event_type"
    end

    add_index :broadcast_events, :occurred_at, name: "idx_broadcast_events_occurred_at" # 保持期間の適用（20.3）が引く
    add_index :broadcast_events, %i[ broadcast_id occurred_at ], name: "idx_broadcast_events_broadcast_id_occurred_at"
    add_index :broadcast_events, :user_id, name: "idx_broadcast_events_user_id"
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
