# DB スキーマの期待値。requirements.md 20.1（テーブル一覧）と 21 章（ER 図）から書き起こしたもの。
# マイグレーションから写したものではない。マイグレーションが ER 図からずれたとき、スペックが失敗する。
#
# 列の期待値は [ SQL の型, NULL 可, 既定値 ]（SchemaInspector.columns と同じ形）。
# ER 図は、NULL 可否を書かない。次の規則で決めている。
#   - NOT NULL: 行の作成の時点で、必ず分かっている値（識別子・外部キー・要約値・状態・受理や発生の時刻・申告）。
#   - NULL 可: 行の作成の後に、出来事が起きて初めて入る値（終了の時刻・終了理由・YouTube の識別子）、
#     消去するもの（タイトル・ストリームの識別子）、アカウントの削除時に外すもの（usage_events.user_id・quota_entries.broadcast_id）。
module ExpectedSchema
  UUID = "uuid".freeze
  STRING = "character varying".freeze
  TEXT = "text".freeze
  INTEGER = "integer".freeze
  BIGINT = "bigint".freeze
  BOOLEAN = "boolean".freeze
  DATE = "date".freeze
  DATETIME = "timestamp(6) without time zone".freeze

  GENERATED_UUID = "gen_random_uuid()".freeze

  def self.required(type, default: nil)
    [ type, false, default ].freeze
  end

  def self.optional(type)
    [ type, true, nil ].freeze
  end

  # 主キーが uuid のテーブルの、主キーの列（gen_random_uuid() が既定値）
  def self.uuid_primary_key
    required(UUID, default: GENERATED_UUID)
  end

  TABLES = {
    "users" => {
      "id" => uuid_primary_key,
      "google_sub" => required(STRING),
      "created_at" => required(DATETIME),
      "last_login_at" => required(DATETIME)
    },
    "sessions" => {
      "id" => uuid_primary_key,
      "user_id" => required(UUID),
      "token_digest" => required(STRING),
      "created_at" => required(DATETIME),
      "last_used_at" => required(DATETIME),
      "expires_at" => required(DATETIME)
    },
    "youtube_connections" => {
      "id" => uuid_primary_key,
      "user_id" => required(UUID),
      "state" => required(STRING),
      "refresh_token_ciphertext" => required(TEXT),
      "youtube_stream_id" => optional(STRING),
      "stream_verified_at" => optional(DATETIME),
      "connected_at" => required(DATETIME),
      "last_verified_at" => required(DATETIME)
    },
    "broadcasts" => {
      "id" => uuid_primary_key,
      "user_id" => required(UUID),
      "daily_usage_id" => required(UUID),
      "state" => required(STRING, default: "reserved"),
      "end_reason" => optional(STRING),
      "settlement_state" => required(STRING, default: "none"),
      "settlement_attempts" => required(INTEGER, default: "0"),
      "usage_date" => required(DATE),
      "quota_date" => required(DATE),
      "prep_reserved_units" => required(INTEGER, default: "0"),
      "settle_reserved_units" => required(INTEGER, default: "0"),
      "attempt_counted" => required(BOOLEAN, default: "false"),
      "resume_count" => required(INTEGER, default: "0"),
      "sent_bytes" => required(BIGINT, default: "0"),
      "profile" => optional(STRING),
      "publisher_epoch" => required(INTEGER, default: "0"),
      "pending_title" => optional(STRING),
      "scheduled_start_at" => optional(DATETIME),
      "privacy_status" => required(STRING),
      "made_for_kids" => required(BOOLEAN),
      "youtube_broadcast_id" => optional(STRING),
      "youtube_stream_id" => optional(STRING),
      "bound" => required(BOOLEAN, default: "false"),
      "allowance_consumed" => required(BOOLEAN, default: "false"),
      "accepted_at" => required(DATETIME),
      "provisioned_at" => optional(DATETIME),
      "publish_started_at" => optional(DATETIME),
      "live_at" => optional(DATETIME),
      "interrupted_at" => optional(DATETIME),
      "last_heartbeat_at" => optional(DATETIME),
      "last_checked_at" => optional(DATETIME),
      "ended_at" => optional(DATETIME)
    },
    "daily_usages" => {
      "id" => uuid_primary_key,
      "user_id" => required(UUID),
      "usage_date" => required(DATE),
      "consumed_count" => required(INTEGER, default: "0"),
      "attempt_count" => required(INTEGER, default: "0"),
      "extra_grants" => required(INTEGER, default: "0")
    },
    "relay_tickets" => {
      "id" => uuid_primary_key,
      "user_id" => required(UUID),
      "broadcast_id" => required(UUID),
      "token_digest" => required(STRING),
      "epoch" => required(INTEGER),
      "expires_at" => required(DATETIME),
      "used_at" => optional(DATETIME)
    },
    "health_samples" => {
      "id" => uuid_primary_key,
      "user_id" => required(UUID),
      "broadcast_id" => required(UUID),
      "sampled_at" => required(DATETIME),
      "sent_kbps" => optional(INTEGER),
      "target_kbps" => optional(INTEGER),
      "backlog_ms" => optional(INTEGER),
      "dropped_video_frames" => optional(INTEGER),
      "relay_out_kbps" => optional(INTEGER),
      "state" => optional(STRING)
    },
    "broadcast_events" => {
      "id" => uuid_primary_key,
      "user_id" => required(UUID),
      "broadcast_id" => required(UUID),
      "occurred_at" => required(DATETIME),
      "event_type" => required(STRING),
      "detail" => optional(STRING)
    },
    "usage_events" => {
      "id" => uuid_primary_key,
      "user_id" => optional(UUID),
      "occurred_at" => required(DATETIME),
      "event_type" => required(STRING),
      "reason_code" => optional(STRING),
      "bucket" => optional(STRING),
      "browser_class" => optional(STRING)
    },
    "quota_days" => {
      "quota_date" => required(DATE),
      "used_units" => required(INTEGER, default: "0"),
      "reserved_units" => required(INTEGER, default: "0"),
      "common_used_units" => required(INTEGER, default: "0"),
      "exhausted" => required(BOOLEAN, default: "false")
    },
    "quota_entries" => {
      "id" => uuid_primary_key,
      "quota_date" => required(DATE),
      "broadcast_id" => optional(UUID),
      "method" => required(STRING),
      "units" => required(INTEGER),
      "result" => required(STRING),
      "bucket" => required(STRING),
      "called_at" => required(DATETIME)
    },
    "transfer_months" => {
      "month" => required(STRING),
      "sent_bytes" => required(BIGINT, default: "0")
    },
    "deletion_holds" => {
      "sub_digest" => required(STRING),
      "hold_usage_date" => required(DATE)
    },
    "system_settings" => {
      "key" => required(STRING),
      "value" => required(STRING),
      "updated_at" => required(DATETIME)
    },
    "admin_actions" => {
      "id" => uuid_primary_key,
      "action" => required(STRING),
      "target" => optional(STRING),
      "detail" => optional(STRING),
      "occurred_at" => required(DATETIME)
    }
  }.freeze

  # 主キー。uuid（gen_random_uuid()）のほかは、自然キー（quota_days は日付、transfer_months は月の文字列、
  # deletion_holds は要約値、system_settings はキー）。
  PRIMARY_KEYS = TABLES.keys.to_h { |table| [ table, "id" ] }.merge(
    "quota_days" => "quota_date",
    "transfer_months" => "month",
    "deletion_holds" => "sub_digest",
    "system_settings" => "key"
  ).freeze

  # requirements.md 20.1 の「アカウント識別子」欄による、テーブルの分類。
  # 新しいテーブルを足したときは、ここへ分類を足す（足さないと、account_identifier_spec が失敗する）。
  ACCOUNT_TABLE = "users".freeze # 主キーがアカウント識別子
  USER_OWNED_TABLES = %w[ sessions youtube_connections broadcasts daily_usages relay_tickets health_samples broadcast_events usage_events ].freeze # 「保持する」
  NULLABLE_USER_ID_TABLES = %w[ usage_events ].freeze # 「保持する（削除時に外す）」
  SYSTEM_WIDE_TABLES = %w[ quota_days quota_entries transfer_months system_settings admin_actions ].freeze # 「システム全体」
  WITHOUT_ACCOUNT_ID_TABLES = %w[ deletion_holds ].freeze # 「保持しない」
end
