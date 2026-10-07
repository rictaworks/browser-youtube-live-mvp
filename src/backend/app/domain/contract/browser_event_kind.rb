# frozen_string_literal: true

module Contract
  # 列挙 browser_event_kind（契約独自の列挙（#3）。状態報告に載せる、ブラウザ側の出来事（配信の出来事の種別の部分集合））の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module BrowserEventKind
    extend ValueSet

    SOURCE_ADDED = "source_added"
    SOURCE_LOST = "source_lost"
    FALLBACK_SWITCHED = "fallback_switched"
    BITRATE_DOWN = "bitrate_down"
    BITRATE_UP = "bitrate_up"
    VIDEO_DROPPED = "video_dropped"
    DEGRADED_STARTED = "degraded_started"
    DEGRADED_CLEARED = "degraded_cleared"

    ALL = [
      SOURCE_ADDED,
      SOURCE_LOST,
      FALLBACK_SWITCHED,
      BITRATE_DOWN,
      BITRATE_UP,
      VIDEO_DROPPED,
      DEGRADED_STARTED,
      DEGRADED_CLEARED
    ].freeze
  end
end
