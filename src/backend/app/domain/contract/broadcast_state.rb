# frozen_string_literal: true

module Contract
  # 列挙 broadcast_state（requirements.md 20.4（配信レコードの状態）・25.1）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module BroadcastState
    extend ValueSet

    RESERVED = "reserved"
    AWAITING_MEDIA = "awaiting_media"
    CONFIRMING = "confirming"
    LIVE = "live"
    INTERRUPTED = "interrupted"
    ENDED = "ended"

    ALL = [
      RESERVED,
      AWAITING_MEDIA,
      CONFIRMING,
      LIVE,
      INTERRUPTED,
      ENDED
    ].freeze
  end
end
