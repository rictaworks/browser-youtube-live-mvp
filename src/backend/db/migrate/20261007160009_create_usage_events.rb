# 測定イベント（requirements.md 18.2・20.1・21 章）。内部のアカウント識別子にのみ紐づけ、氏名・メールアドレス・IP アドレスを含めない。
# アカウントの削除時は、アカウントとの紐づけを外して残す（user_id を NULL にする。7.4）。
class CreateUsageEvents < ActiveRecord::Migration[8.1]
  # 契約の列挙 usage_event_type（20.4・18 章）
  EVENT_TYPES = %w[
    login_started login_completed connect_started connect_completed connect_failed capability_detected source_granted
    source_denied start_requested start_rejected line_measured prepared live_confirmed degraded reconnect_started
    reconnect_succeeded broadcast_ended watch_url_copied disconnected account_deleted
  ].freeze

  def change
    create_table :usage_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :user_id # アカウント識別子。削除時に外す（NULL 可）
      t.datetime :occurred_at, null: false
      t.string :event_type, null: false
      t.string :reason_code # 符号
      t.string :bucket # 区分化した数値
      t.string :browser_class # 系統と対応可否の分類

      t.check_constraint in_list("event_type", EVENT_TYPES), name: "chk_usage_events_event_type"
    end

    add_index :usage_events, :user_id, name: "idx_usage_events_user_id"
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
