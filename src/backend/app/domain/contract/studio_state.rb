# frozen_string_literal: true

module Contract
  # 列挙 studio_state（requirements.md 20.4（スタジオの状態）・25.3）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module StudioState
    extend ValueSet

    IDLE = "idle"
    REQUESTING = "requesting"
    CONNECTING = "connecting"
    PROBING = "probing"
    STARTING = "starting"
    LIVE = "live"
    DEGRADED = "degraded"
    RECONNECTING = "reconnecting"
    STOPPING = "stopping"
    ENDED = "ended"

    ALL = [
      IDLE,
      REQUESTING,
      CONNECTING,
      PROBING,
      STARTING,
      LIVE,
      DEGRADED,
      RECONNECTING,
      STOPPING,
      ENDED
    ].freeze
  end
end
