# 配信レコード（requirements.md 9・10・13・14・20・21・25 章）。
#
# 制約で保証すること（アプリケーションの判定に依存しない）:
#   - 終了していないレコードは、アカウントにつき 1 件まで（部分一意索引。14 章・20.2）
#   - 状態・終了理由・清算状態・プロファイル・公開範囲は、決まった符号だけ（CHECK。符号は src/contracts/enums.json と一致する）
#   - 件数・量は、負にならない（CHECK）
#   - タイトル（pending_title）は、YouTube の配信識別子を保存した時点、または終了した時点で消える（CHECK。10.1・20.3・28.2）
class CreateBroadcasts < ActiveRecord::Migration[8.1]
  # 契約の列挙 broadcast_state（20.4・25.1）
  STATES = %w[ reserved awaiting_media confirming live interrupted ended ].freeze
  # 契約の列挙 end_reason（20.4）
  END_REASONS = %w[
    user_stop time_limit connection_lost youtube_ended authorization_revoked admin_stop start_timeout
    confirm_timeout prepare_failed prior_unsettled insufficient_bandwidth user_cancel relay_disconnect
  ].freeze
  # 契約の列挙 settlement_state（20.4・25.2）
  SETTLEMENT_STATES = %w[ none pending settled abandoned ].freeze
  # 契約の列挙 profile（20.4・11.7）
  PROFILES = %w[ 720p 480p ].freeze
  # 公開範囲（契約 http-api.md の privacy_status）
  PRIVACY_STATUSES = %w[ public unlisted private ].freeze

  # 件数・量の列（負にならない）
  NON_NEGATIVE_COLUMNS = %w[
    settlement_attempts prep_reserved_units settle_reserved_units resume_count sent_bytes publisher_epoch
  ].freeze

  def change
    create_table :broadcasts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :user_id, null: false # アカウント識別子
      t.uuid :daily_usage_id, null: false # 受理時の利用日の利用実績
      t.string :state, null: false, default: "reserved" # 受理の直後は、受理済み（reserved）
      t.string :end_reason # 終了理由。終了するまで空
      t.string :settlement_state, null: false, default: "none" # 清算状態。終了と同時に定める（10.4）。それまでは、不要（none）
      t.integer :settlement_attempts, null: false, default: 0
      t.date :usage_date, null: false # 受理時の利用日
      t.date :quota_date, null: false # 予約が属する割り当て日。またいだ場合は移す（8.4）
      t.integer :prep_reserved_units, null: false, default: 0 # 準備・確認枠の残額
      t.integer :settle_reserved_units, null: false, default: 0 # 終了・清算枠の残額
      t.boolean :attempt_counted, null: false, default: false # 開始試行を計上済みの印
      t.integer :resume_count, null: false, default: 0 # 復帰の回数
      t.bigint :sent_bytes, null: false, default: 0 # 中継が報告した送出量
      t.string :profile # 720p / 480p。確定するまで空
      t.integer :publisher_epoch, null: false, default: 0 # 送出世代。接続チケットの照合のたびに 1 進む
      t.string :pending_title # 配信のタイトル。識別子の保存時または終了時に消去する
      t.datetime :scheduled_start_at # YouTube へ送った開始予定時刻
      t.string :privacy_status, null: false # 受付の入力値
      t.boolean :made_for_kids, null: false # 受付の入力値。利用者の明示的な選択を必須とする（9.1）
      t.string :youtube_broadcast_id # 終了から 30 日で消去（20.3）
      t.string :youtube_stream_id # 紐づけたストリームの識別子
      t.boolean :bound, null: false, default: false # 紐づけ済みの印
      t.boolean :allowance_consumed, null: false, default: false
      t.datetime :accepted_at, null: false
      t.datetime :provisioned_at
      t.datetime :publish_started_at
      t.datetime :live_at
      t.datetime :interrupted_at
      t.datetime :last_heartbeat_at
      t.datetime :last_checked_at # YouTube 側の状態の最終確認
      t.datetime :ended_at

      t.check_constraint in_list("state", STATES), name: "chk_broadcasts_state"
      t.check_constraint "end_reason IS NULL OR #{in_list('end_reason', END_REASONS)}", name: "chk_broadcasts_end_reason"
      t.check_constraint in_list("settlement_state", SETTLEMENT_STATES), name: "chk_broadcasts_settlement_state"
      t.check_constraint "profile IS NULL OR #{in_list('profile', PROFILES)}", name: "chk_broadcasts_profile"
      t.check_constraint in_list("privacy_status", PRIVACY_STATUSES), name: "chk_broadcasts_privacy_status"

      NON_NEGATIVE_COLUMNS.each do |column|
        t.check_constraint "#{column} >= 0", name: "chk_broadcasts_#{column}_non_negative"
      end

      # タイトルは、識別子を保存する前の、終了していない配信だけが持つ（保存と同じ更新で、タイトルを消す）
      t.check_constraint "pending_title IS NULL OR (youtube_broadcast_id IS NULL AND state <> 'ended')",
        name: "chk_broadcasts_pending_title_lifecycle"
    end

    # 14 章・20.2: アカウントにつき、終了していないレコードは 1 件まで（部分一意索引）
    add_index :broadcasts, :user_id, unique: true, where: "state <> 'ended'", name: "idx_broadcasts_one_unended_per_user"

    # 期限監視（#15）・保持期間の適用（20.3）が引く列。所有権の絞り込み・外部キーの索引
    add_index :broadcasts, %i[ state accepted_at ], name: "idx_broadcasts_state_accepted_at"
    add_index :broadcasts, :settlement_state, name: "idx_broadcasts_settlement_state"
    add_index :broadcasts, :ended_at, name: "idx_broadcasts_ended_at"
    add_index :broadcasts, %i[ user_id accepted_at ], name: "idx_broadcasts_user_id_accepted_at"
    add_index :broadcasts, :daily_usage_id, name: "idx_broadcasts_daily_usage_id"
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
