# frozen_string_literal: true

module Contract
  # 列挙 connect_result（契約独自の列挙（#3）。YouTube 接続の結果（7.2））の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module ConnectResult
    extend ValueSet

    CONNECTED = "connected"
    LIVE_NOT_ENABLED = "live_not_enabled"
    SCOPE_DENIED = "scope_denied"
    NO_REFRESH_TOKEN = "no_refresh_token"
    NO_CHANNEL = "no_channel"
    UNVERIFIABLE = "unverifiable"

    ALL = [
      CONNECTED,
      LIVE_NOT_ENABLED,
      SCOPE_DENIED,
      NO_REFRESH_TOKEN,
      NO_CHANNEL,
      UNVERIFIABLE
    ].freeze
  end
end
