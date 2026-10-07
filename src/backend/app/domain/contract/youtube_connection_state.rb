# frozen_string_literal: true

module Contract
  # 列挙 youtube_connection_state（requirements.md 20.4（YouTube 接続状態）・25.4）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module YoutubeConnectionState
    extend ValueSet

    NOT_CONNECTED = "not_connected"
    CONNECTED = "connected"
    LIVE_NOT_ENABLED = "live_not_enabled"
    REVOKED = "revoked"

    ALL = [
      NOT_CONNECTED,
      CONNECTED,
      LIVE_NOT_ENABLED,
      REVOKED
    ].freeze
  end
end
