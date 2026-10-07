# frozen_string_literal: true

module Contract
  # 列挙 ws_message_type（requirements.md 20.4（転送メッセージ種別）・11.9。前の 7 種がブラウザ → 中継、後の 7 種が中継 → ブラウザ）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。例外：end は END_（数字で始まる名前・予約語を避ける）。
  module WsMessageType
    extend ValueSet

    HELLO = "hello"
    PROBE = "probe"
    START = "start"
    VIDEO = "video"
    AUDIO = "audio"
    REPORT = "report"
    END_ = "end"
    ACCEPTED = "accepted"
    PROBE_RESULT = "probe_result"
    ACK = "ack"
    KEYFRAME_REQUEST = "keyframe_request"
    THROTTLE = "throttle"
    STATUS = "status"
    FATAL = "fatal"

    ALL = [
      HELLO,
      PROBE,
      START,
      VIDEO,
      AUDIO,
      REPORT,
      END_,
      ACCEPTED,
      PROBE_RESULT,
      ACK,
      KEYFRAME_REQUEST,
      THROTTLE,
      STATUS,
      FATAL
    ].freeze
  end
end
