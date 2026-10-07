# frozen_string_literal: true

module Contract
  # 列挙 broadcast_event_type（requirements.md 20.4（配信の出来事の種別））の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module BroadcastEventType
    extend ValueSet

    ACCEPTED = "accepted"
    VERIFIED = "verified"
    PROBE_DONE = "probe_done"
    PROVISION_STARTED = "provision_started"
    PROVISION_DONE = "provision_done"
    PUBLISH_STARTED = "publish_started"
    LIVE_CONFIRMED = "live_confirmed"
    SOURCE_ADDED = "source_added"
    SOURCE_LOST = "source_lost"
    FALLBACK_SWITCHED = "fallback_switched"
    BITRATE_DOWN = "bitrate_down"
    BITRATE_UP = "bitrate_up"
    VIDEO_DROPPED = "video_dropped"
    DEGRADED_STARTED = "degraded_started"
    DEGRADED_CLEARED = "degraded_cleared"
    INTERRUPTED = "interrupted"
    RESUMED = "resumed"
    THROTTLE_DIRECTED = "throttle_directed"
    KEYFRAME_REQUESTED = "keyframe_requested"
    YOUTUBE_WARNING = "youtube_warning"
    TIME_LIMIT_NOTICE = "time_limit_notice"
    ENDED = "ended"
    SETTLEMENT_SUCCEEDED = "settlement_succeeded"
    SETTLEMENT_FAILED = "settlement_failed"

    ALL = [
      ACCEPTED,
      VERIFIED,
      PROBE_DONE,
      PROVISION_STARTED,
      PROVISION_DONE,
      PUBLISH_STARTED,
      LIVE_CONFIRMED,
      SOURCE_ADDED,
      SOURCE_LOST,
      FALLBACK_SWITCHED,
      BITRATE_DOWN,
      BITRATE_UP,
      VIDEO_DROPPED,
      DEGRADED_STARTED,
      DEGRADED_CLEARED,
      INTERRUPTED,
      RESUMED,
      THROTTLE_DIRECTED,
      KEYFRAME_REQUESTED,
      YOUTUBE_WARNING,
      TIME_LIMIT_NOTICE,
      ENDED,
      SETTLEMENT_SUCCEEDED,
      SETTLEMENT_FAILED
    ].freeze
  end
end
