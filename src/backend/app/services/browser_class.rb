# ブラウザの分類（issue #7。requirements.md 18.2「ブラウザの種別は、分類（系統と対応の可否）のみを記録する」）。
#
# 系統（chromium・firefox・webkit・other）と、対応可否（能力検出の結果）だけを持つ。
# ユーザーエージェントの文字列を、受け取らない・保存しない（コンストラクタが受け付けるのは、この 2 つだけ）。
# 測定イベントの列 usage_events.browser_class には、"chromium:supported" の形の文字列（to_s）で保存する。
class BrowserClass < Data.define(:family, :supported)
  FAMILIES = %w[ chromium firefox webkit other ].freeze
  SUPPORT_LABELS = { true => "supported", false => "unsupported" }.freeze
  STORED_FORMAT = /\A(?<family>[a-z]+):(?<support>supported|unsupported)\z/

  def initialize(family:, supported:)
    raise ArgumentError, "family must be one of: #{FAMILIES.join(', ')}" unless FAMILIES.include?(family)
    raise ArgumentError, "supported must be true or false" unless SUPPORT_LABELS.key?(supported)

    super
  end

  # 保存する形（"chromium:supported"）
  def to_s
    "#{family}:#{SUPPORT_LABELS.fetch(supported)}"
  end

  # 保存した形から、元に戻す。形が違えば ArgumentError
  def self.parse(stored)
    match = STORED_FORMAT.match(stored.to_s)
    raise ArgumentError, "stored browser class is malformed" if match.nil?

    new(family: match[:family], supported: match[:support] == "supported")
  end
end
