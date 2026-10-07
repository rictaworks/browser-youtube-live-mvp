# frozen_string_literal: true

module Contract
  # 列挙 end_reason（requirements.md 20.4（終了理由））の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module EndReason
    extend ValueSet

    USER_STOP = "user_stop"
    TIME_LIMIT = "time_limit"
    CONNECTION_LOST = "connection_lost"
    YOUTUBE_ENDED = "youtube_ended"
    AUTHORIZATION_REVOKED = "authorization_revoked"
    ADMIN_STOP = "admin_stop"
    START_TIMEOUT = "start_timeout"
    CONFIRM_TIMEOUT = "confirm_timeout"
    PREPARE_FAILED = "prepare_failed"
    PRIOR_UNSETTLED = "prior_unsettled"
    INSUFFICIENT_BANDWIDTH = "insufficient_bandwidth"
    USER_CANCEL = "user_cancel"
    RELAY_DISCONNECT = "relay_disconnect"

    ALL = [
      USER_STOP,
      TIME_LIMIT,
      CONNECTION_LOST,
      YOUTUBE_ENDED,
      AUTHORIZATION_REVOKED,
      ADMIN_STOP,
      START_TIMEOUT,
      CONFIRM_TIMEOUT,
      PREPARE_FAILED,
      PRIOR_UNSETTLED,
      INSUFFICIENT_BANDWIDTH,
      USER_CANCEL,
      RELAY_DISCONNECT
    ].freeze
  end
end
