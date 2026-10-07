# frozen_string_literal: true

# 配信の生命周期（issue #6）のスペックの共通部品。
#
# スペックのファイルの読み込み中（describe の本体）では、Domain Core の定数（BroadcastSnapshot など）を参照しない
# （spec/domain/support/domain_loader.rb の方針。ローダーはスイートの開始時に設定される）。このモジュールの定数・メソッドは、
# 参照を、メソッドの中（例の実行時）だけに持つ。
module LifecycleSpecHelpers
  # 基準の時刻（UTC）。スペックの時刻は、これからの秒数で書く。
  T0 = Time.utc(2026, 10, 7, 12, 0, 0)

  # 進行中の配信にも現在の設定を適用する（時間上限）ための、設定の代役。#5 の Settings と同じく time_limit_minutes に応答する。
  FakeSettings = Struct.new(:time_limit_minutes)

  # 状態ごとの、整合した既定の値（ダミー）。YouTube 資源は、準備の完了（送出待ち）から持つ。
  # 終了は、ライブから停止した配信で、YouTube 資源を持ち、最初の清算の試行が失敗した直後（未清算・試行 1 回）。
  ATTRIBUTES = {
    "reserved" => {},
    "awaiting_media" => {
      provisioned_at: T0 + 20,
      youtube_broadcast_id: "dummy-youtube-broadcast-1",
      youtube_stream_id: "dummy-youtube-stream-1"
    },
    "confirming" => {
      provisioned_at: T0 + 20,
      publish_started_at: T0 + 40,
      last_checked_at: T0 + 40,
      youtube_broadcast_id: "dummy-youtube-broadcast-1",
      youtube_stream_id: "dummy-youtube-stream-1"
    },
    "live" => {
      provisioned_at: T0 + 20,
      publish_started_at: T0 + 40,
      live_at: T0 + 60,
      last_heartbeat_at: T0 + 60,
      last_checked_at: T0 + 60,
      youtube_broadcast_id: "dummy-youtube-broadcast-1",
      youtube_stream_id: "dummy-youtube-stream-1"
    },
    "interrupted" => {
      provisioned_at: T0 + 20,
      publish_started_at: T0 + 40,
      live_at: T0 + 60,
      last_heartbeat_at: T0 + 100,
      last_checked_at: T0 + 60,
      interrupted_at: T0 + 100,
      youtube_broadcast_id: "dummy-youtube-broadcast-1",
      youtube_stream_id: "dummy-youtube-stream-1"
    },
    "ended" => {
      provisioned_at: T0 + 20,
      publish_started_at: T0 + 40,
      live_at: T0 + 60,
      last_heartbeat_at: T0 + 200,
      last_checked_at: T0 + 200,
      ended_at: T0 + 200,
      end_reason: "user_stop",
      settlement_state: "pending",
      settlement_attempts: 1,
      settlement_attempted_at: T0 + 200,
      youtube_broadcast_id: "dummy-youtube-broadcast-1",
      youtube_stream_id: "dummy-youtube-stream-1"
    }
  }.freeze

  # 状態ごとの既定の値に overrides を重ねた、配信のスナップショット。
  def snapshot(state, **overrides)
    base = { id: "dummy-broadcast-1", user_id: "dummy-user-1", state: state, accepted_at: T0 }
    BroadcastSnapshot.new(**base.merge(ATTRIBUTES.fetch(state)).merge(overrides))
  end

  # 終了済みの配信（既定は、未清算・YouTube 資源あり）。
  def ended_snapshot(**overrides)
    snapshot("ended", **overrides)
  end

  # 時間上限の設定の代役。
  def settings(time_limit_minutes: 60)
    FakeSettings.new(time_limit_minutes)
  end
end
