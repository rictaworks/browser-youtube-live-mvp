# frozen_string_literal: true

module Contract
  # 列挙 relay_event_kind（契約独自の列挙（#3）。internal-api.md の事象の種類）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module RelayEventKind
    extend ValueSet

    PUBLISH_STARTED = "publish_started"
    INTERRUPTED = "interrupted"
    RESUMED = "resumed"
    PUBLISH_FAILED = "publish_failed"
    RELAY_DISCONNECTED = "relay_disconnected"
    SESSION_ENDED = "session_ended"

    ALL = [
      PUBLISH_STARTED,
      INTERRUPTED,
      RESUMED,
      PUBLISH_FAILED,
      RELAY_DISCONNECTED,
      SESSION_ENDED
    ].freeze
  end
end
