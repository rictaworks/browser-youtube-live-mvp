# frozen_string_literal: true

module Admission
  # 受理のときに適用される上限（requirements.md 9.3）。
  #   time_limit_seconds  1 配信の時間上限（秒。設定の時間上限（分）から）。ライブ確定からの経過で数える（8.3）
  #   profiles            エンコードプロファイルの範囲（契約の limits.json の profiles。映像ビットレートの下限・初期値・上限など）
  class AppliedLimits < Data.define(:time_limit_seconds, :profiles)
    SECONDS_PER_MINUTE = 60

    # 設定から作る。profiles は、契約の値（凍結済み）をそのまま持つ。
    def self.from_settings(settings)
      Preconditions.kind!(settings, Settings, "settings")

      new(time_limit_seconds: settings.time_limit_minutes * SECONDS_PER_MINUTE, profiles: Contract::Limits::PROFILES)
    end

    def initialize(time_limit_seconds:, profiles:)
      Preconditions.integer!(time_limit_seconds, "time_limit_seconds", min: 1)
      Preconditions.kind!(profiles, Hash, "profiles")
      super
    end
  end
end
