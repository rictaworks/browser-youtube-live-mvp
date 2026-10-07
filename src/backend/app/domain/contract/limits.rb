# frozen_string_literal: true

module Contract
  # 契約の制限値・間隔・閾値・固定値（src/contracts/limits.json の複製。文書用のキーを除く）。
  # JSON のトップレベルのキー（セクション）ごとに、JSON と同じ形（String のキー）の、深く凍結した Hash を持つ。
  # 例：Contract::Limits::RELAY.fetch("hello_timeout_seconds")
  # キーは snake_case で、単位は名前に含まれる（_kbps・_ms・_us・_seconds・_bytes）。
  module Limits
    # Hash・Array を、再帰的に凍結する（キーの文字列も）。
    def self.deep_freeze(value)
      case value
      when Hash
        value.each do |key, child|
          key.freeze
          deep_freeze(child)
        end
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end

    # profiles
    PROFILES = deep_freeze(
      {
        "720p" => {
          "width" => 1280,
          "height" => 720,
          "framerate" => 30,
          "video_bitrate_min_kbps" => 3000,
          "video_bitrate_initial_kbps" => 4500,
          "video_bitrate_max_kbps" => 6000,
          "line_threshold_kbps" => 4100
        },
        "480p" => {
          "width" => 854,
          "height" => 480,
          "framerate" => 30,
          "video_bitrate_min_kbps" => 800,
          "video_bitrate_initial_kbps" => 1500,
          "video_bitrate_max_kbps" => 2500,
          "line_threshold_kbps" => 1200
        }
      }
    )

    # video
    VIDEO = deep_freeze(
      {
        "codec_main" => "avc1.4D401F",
        "codec_constrained_baseline" => "avc1.42E01F",
        "keyframe_interval_seconds" => 2
      }
    )

    # audio
    AUDIO = deep_freeze(
      {
        "codec" => "mp4a.40.2",
        "sample_rate_hz" => 44100,
        "channels" => 2,
        "bitrate_kbps" => 128,
        "samples_per_video_frame" => 1470
      }
    )

    # line_probe
    LINE_PROBE = deep_freeze(
      {
        "duration_seconds" => 3,
        "max_rate_kbps" => 6000,
        "message_bytes_hint" => 32768,
        "start_bitrate_throughput_ratio" => 0.75
      }
    )

    # adaptive
    ADAPTIVE = deep_freeze(
      {
        "evaluation_interval_ms" => 1000,
        "target_change_min_interval_ms" => 1000,
        "encoder_queue_max_frames" => 2,
        "conditions" => {
          "backlog_high_twice" => {
            "backlog_over_ms" => 1500,
            "consecutive_evaluations" => 2,
            "decrease_percent" => 30
          },
          "backlog_low_no_drop" => {
            "backlog_under_ms" => 300,
            "no_drop_window_seconds" => 10,
            "increase_percent" => 10
          },
          "backlog_critical" => {
            "backlog_over_ms" => 4000
          },
          "video_ack_stalled" => {
            "stalled_seconds" => 10
          },
          "backlog_severe_sustained" => {
            "backlog_over_ms" => 8000,
            "duration_seconds" => 10
          },
          "degraded_enter" => {
            "backlog_over_ms" => 1500,
            "duration_seconds" => 20
          },
          "degraded_exit" => {
            "backlog_at_most_ms" => 1500,
            "duration_seconds" => 10
          }
        }
      }
    )

    # ws_frame
    WS_FRAME = deep_freeze(
      {
        "magic" => [ 66, 76 ],
        "version" => 1,
        "header_bytes" => 17,
        "header_fields" => {
          "magic" => {
            "offset" => 0,
            "length" => 2
          },
          "version" => {
            "offset" => 2,
            "length" => 1
          },
          "type" => {
            "offset" => 3,
            "length" => 1
          },
          "attributes" => {
            "offset" => 4,
            "length" => 1
          },
          "timestamp_us" => {
            "offset" => 5,
            "length" => 8
          },
          "body_length" => {
            "offset" => 13,
            "length" => 4
          }
        },
        "keyframe_attribute_bit" => 0,
        "max_message_bytes" => 2097152,
        "directions" => [ "browser_to_relay", "relay_to_browser" ],
        "types" => {
          "hello" => {
            "code" => 1,
            "direction" => "browser_to_relay"
          },
          "probe" => {
            "code" => 2,
            "direction" => "browser_to_relay"
          },
          "start" => {
            "code" => 3,
            "direction" => "browser_to_relay"
          },
          "video" => {
            "code" => 4,
            "direction" => "browser_to_relay"
          },
          "audio" => {
            "code" => 5,
            "direction" => "browser_to_relay"
          },
          "report" => {
            "code" => 6,
            "direction" => "browser_to_relay"
          },
          "end" => {
            "code" => 7,
            "direction" => "browser_to_relay"
          },
          "accepted" => {
            "code" => 129,
            "direction" => "relay_to_browser"
          },
          "probe_result" => {
            "code" => 130,
            "direction" => "relay_to_browser"
          },
          "ack" => {
            "code" => 131,
            "direction" => "relay_to_browser"
          },
          "keyframe_request" => {
            "code" => 132,
            "direction" => "relay_to_browser"
          },
          "throttle" => {
            "code" => 133,
            "direction" => "relay_to_browser"
          },
          "status" => {
            "code" => 134,
            "direction" => "relay_to_browser"
          },
          "fatal" => {
            "code" => 135,
            "direction" => "relay_to_browser"
          }
        }
      }
    )

    # relay
    RELAY = deep_freeze(
      {
        "hello_timeout_seconds" => 10,
        "ingress_bitrate_limit_factor" => 1.5,
        "ingress_bitrate_window_seconds" => 10,
        "ingress_bitrate_limit_probe_profile" => "720p",
        "media_stall_seconds" => 5,
        "heartbeat_interval_seconds" => 2,
        "heartbeat_lost_stop_seconds" => 60,
        "egress_buffer_limit_ms" => 3000,
        "egress_throttle_ms" => 1500,
        "ack_interval_ms" => 500,
        "report_interval_ms" => 1000
      }
    )

    # tickets
    TICKETS = deep_freeze(
      {
        "ttl_seconds" => 60
      }
    )

    # deadlines
    DEADLINES = deep_freeze(
      {
        "reserved_seconds" => 90,
        "awaiting_media_seconds" => 30,
        "confirming_seconds" => 120,
        "interrupted_relay_notified_seconds" => 30,
        "interrupted_heartbeat_lost_seconds" => 75,
        "heartbeat_lost_detect_seconds" => 10,
        "max_resumes" => 10,
        "live_confirm_poll_interval_seconds" => 5,
        "live_check_interval_seconds" => 300,
        "deadline_monitor_max_interval_seconds" => 5,
        "reconnect_backoff_cap_ms" => 5000,
        "time_limit_notice_before_seconds" => 300,
        "settlement_retry_delays_seconds" => [ 60, 120, 240 ]
      }
    )

    # quota
    QUOTA = deep_freeze(
      {
        "common_units" => 500,
        "safety_margin_units" => 500,
        "broadcast_usable_units_at_default" => 9000,
        "broadcast_reservation_units" => 550,
        "prep_reservation_units" => 340,
        "settle_reservation_units" => 210,
        "unit_costs" => {
          "list" => 1,
          "insert" => 50,
          "update" => 50,
          "bind" => 50,
          "transition" => 50,
          "delete" => 50
        }
      }
    )

    # rtmps_ingest
    RTMPS_INGEST = deep_freeze(
      {
        "scheme" => "rtmps",
        "hosts" => [ "a.rtmps.youtube.com", "b.rtmps.youtube.com" ],
        "port" => 443,
        "userinfo_allowed" => false,
        "query_allowed" => false
      }
    )

    # dev_ingest
    DEV_INGEST = deep_freeze(
      {
        "scheme" => "rtmps",
        "host" => "fake-ingest",
        "port" => 1935,
        "tls" => "self_signed",
        "allowed_environments" => [ "development", "test" ]
      }
    )

    # rate_limits
    RATE_LIMITS = deep_freeze(
      {
        "login_start" => {
          "scope" => "ip",
          "limit" => 30,
          "window_seconds" => 3600
        },
        "connect_start" => {
          "scope" => "ip",
          "limit" => 30,
          "window_seconds" => 3600
        },
        "recheck_per_minute" => {
          "scope" => "account",
          "limit" => 1,
          "window_seconds" => 60
        },
        "recheck_per_day" => {
          "scope" => "account",
          "limit" => 20,
          "window_seconds" => 86400
        },
        "intake" => {
          "scope" => "account",
          "limit_setting" => "intake_rate_per_hour",
          "window_seconds" => 3600
        }
      }
    )

    # retention
    RETENTION = deep_freeze(
      {
        "youtube_broadcast_id_days_after_end" => 30,
        "health_samples_days" => 30,
        "broadcast_events_days" => 30,
        "relay_ticket_days_after_expiry" => 1,
        "session_days_after_last_use" => 30,
        "stream_id_days_after_last_verified" => 30,
        "channel_title_memory_max_minutes" => 10
      }
    )

    # setting_defaults
    SETTING_DEFAULTS = deep_freeze(
      {
        "daily_allowance" => 1,
        "attempt_limit" => 3,
        "concurrent_limit" => 3,
        "time_limit_minutes" => 60,
        "intake_rate_per_hour" => 10,
        "monthly_transfer_budget_gb" => 10,
        "daily_quota_units" => 10000,
        "bot_score_threshold" => 0.5,
        "intake_paused" => false
      }
    )

    private_class_method :deep_freeze
  end
end
