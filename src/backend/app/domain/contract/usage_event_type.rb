# frozen_string_literal: true

module Contract
  # 列挙 usage_event_type（requirements.md 20.4（測定イベントの種別）・18 章）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module UsageEventType
    extend ValueSet

    LOGIN_STARTED = "login_started"
    LOGIN_COMPLETED = "login_completed"
    CONNECT_STARTED = "connect_started"
    CONNECT_COMPLETED = "connect_completed"
    CONNECT_FAILED = "connect_failed"
    CAPABILITY_DETECTED = "capability_detected"
    SOURCE_GRANTED = "source_granted"
    SOURCE_DENIED = "source_denied"
    START_REQUESTED = "start_requested"
    START_REJECTED = "start_rejected"
    LINE_MEASURED = "line_measured"
    PREPARED = "prepared"
    LIVE_CONFIRMED = "live_confirmed"
    DEGRADED = "degraded"
    RECONNECT_STARTED = "reconnect_started"
    RECONNECT_SUCCEEDED = "reconnect_succeeded"
    BROADCAST_ENDED = "broadcast_ended"
    WATCH_URL_COPIED = "watch_url_copied"
    DISCONNECTED = "disconnected"
    ACCOUNT_DELETED = "account_deleted"

    ALL = [
      LOGIN_STARTED,
      LOGIN_COMPLETED,
      CONNECT_STARTED,
      CONNECT_COMPLETED,
      CONNECT_FAILED,
      CAPABILITY_DETECTED,
      SOURCE_GRANTED,
      SOURCE_DENIED,
      START_REQUESTED,
      START_REJECTED,
      LINE_MEASURED,
      PREPARED,
      LIVE_CONFIRMED,
      DEGRADED,
      RECONNECT_STARTED,
      RECONNECT_SUCCEEDED,
      BROADCAST_ENDED,
      WATCH_URL_COPIED,
      DISCONNECTED,
      ACCOUNT_DELETED
    ].freeze
  end
end
