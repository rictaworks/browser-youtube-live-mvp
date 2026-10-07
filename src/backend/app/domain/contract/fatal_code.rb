# frozen_string_literal: true

module Contract
  # 列挙 fatal_code（契約独自の列挙（#3）。ws-protocol.md の致命通知）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module FatalCode
    extend ValueSet

    MESSAGE_TOO_LARGE = "message_too_large"
    BITRATE_EXCEEDED = "bitrate_exceeded"
    HELLO_TIMEOUT = "hello_timeout"
    INVALID_TICKET = "invalid_ticket"
    STALE_EPOCH = "stale_epoch"
    BROADCAST_ENDED = "broadcast_ended"
    PROTOCOL_VIOLATION = "protocol_violation"
    HEARTBEAT_LOST = "heartbeat_lost"
    PUBLISH_FAILED = "publish_failed"
    INTERNAL_ERROR = "internal_error"

    ALL = [
      MESSAGE_TOO_LARGE,
      BITRATE_EXCEEDED,
      HELLO_TIMEOUT,
      INVALID_TICKET,
      STALE_EPOCH,
      BROADCAST_ENDED,
      PROTOCOL_VIOLATION,
      HEARTBEAT_LOST,
      PUBLISH_FAILED,
      INTERNAL_ERROR
    ].freeze
  end
end
