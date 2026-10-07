# frozen_string_literal: true

module Admission
  # 受理のときに適用される上限（requirements.md 9.3）。
  #   time_limit_seconds  1 配信の時間上限（秒。設定の時間上限（分）から）。ライブ確定からの経過で数える（8.3）
  #   profiles            エンコードプロファイルの範囲（契約の limits.json の profiles。映像ビットレートの下限・初期値・上限など）
  #                       JSON の形（Hash・Array・String・数値・真偽値・nil）。生成時に、深く凍結する
  #
  # profiles は、深く凍結された値だけを、そのまま持つ（契約の値は、凍結済みなので、複製しない）。凍結されていない部分があれば
  # （外側だけ凍結した Hash も含む）、深く凍結した複製を持つ。呼び出し側の Hash は、凍結せず、あとからの変更の影響も受けない。
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
      super(time_limit_seconds: time_limit_seconds, profiles: deeply_frozen?(profiles) ? profiles : frozen_copy(profiles))
    end

    private

    # Hash・Array・String を、再帰的にたどって、すべて凍結されているか（それ以外の値は、凍結されていれば真。数値・真偽値・nil・シンボルは、常に凍結されている）。
    def deeply_frozen?(value)
      case value
      when Hash then value.frozen? && value.all? { |key, child| deeply_frozen?(key) && deeply_frozen?(child) }
      when Array then value.frozen? && value.all? { |child| deeply_frozen?(child) }
      else value.frozen?
      end
    end

    # 深く凍結した複製。Hash・Array・String は複製して凍結し、それ以外の値（数値・真偽値・nil・シンボル）は、不変なので、そのまま。
    def frozen_copy(value)
      case value
      when Hash then value.to_h { |key, child| [ frozen_copy(key), frozen_copy(child) ] }.freeze
      when Array then value.map { |child| frozen_copy(child) }.freeze
      when String then value.frozen? ? value : value.dup.freeze
      else value
      end
    end
  end
end
