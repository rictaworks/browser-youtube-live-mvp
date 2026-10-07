# frozen_string_literal: true

module Contract
  # 列挙 adaptive_condition（requirements.md 20.4（適応制御の条件）・12 章。配列の順が 12 章の表の 7 行の順）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module AdaptiveCondition
    extend ValueSet

    BACKLOG_HIGH_TWICE = "backlog_high_twice"
    BACKLOG_LOW_NO_DROP = "backlog_low_no_drop"
    BACKLOG_CRITICAL = "backlog_critical"
    VIDEO_ACK_STALLED = "video_ack_stalled"
    BACKLOG_SEVERE_SUSTAINED = "backlog_severe_sustained"
    DEGRADED_ENTER = "degraded_enter"
    DEGRADED_EXIT = "degraded_exit"

    ALL = [
      BACKLOG_HIGH_TWICE,
      BACKLOG_LOW_NO_DROP,
      BACKLOG_CRITICAL,
      VIDEO_ACK_STALLED,
      BACKLOG_SEVERE_SUSTAINED,
      DEGRADED_ENTER,
      DEGRADED_EXIT
    ].freeze
  end
end
