# ブラウザが送る測定イベントの検査（POST /api/usage-events の本文。src/contracts/http-api.md 3 章。requirements.md 18.2・28.2）。
#
# ブラウザが送れる種別は、capability_detected・source_granted・source_denied・line_measured・watch_url_copied の 5 つだけ
# （それ以外は UnsupportedType = 422 unsupported_event。ほかの測定イベントは、サーバーが記録する）。
# 数値（value）は、サーバーが区分（Bucketizer）に変換して記録する（数値のまま保存しない）。value を持つ種別は、line_measured だけ
# （実効スループット kbps）。ブラウザの分類は、系統と対応可否のオブジェクトだけ。ユーザーエージェントの文字列を受け取らない。
# 未知のキーは、無視する（契約: 要求の未知のキーは、無視します）。受け取った値は、保持しない。
#
# 入力の不備は InvalidInput（fields に、不備のある項目名を、種別・符号・値・ブラウザの分類の順に並べる。422 invalid_input）。
# 例外のメッセージ・fields に、送られた値を含めない。
class BrowserUsageEvent < Data.define(:type, :reason_code, :bucket, :browser_class)
  SENDABLE_TYPES = %w[ capability_detected source_granted source_denied line_measured watch_url_copied ].freeze

  # 数値（value）を持つ種別 => 区分の種類
  VALUE_KINDS = { "line_measured" => "throughput_kbps" }.freeze

  # 数値の上限（32 ビット符号付き整数。DB・設定の整数と同じ）
  MAX_VALUE = 2_147_483_647

  # ブラウザから送れない種別
  class UnsupportedType < StandardError
    def initialize(message = "event type cannot be sent by the browser")
      super
    end
  end

  # 入力の不備。fields は、不備のある項目名
  class InvalidInput < StandardError
    attr_reader :fields

    def initialize(fields)
      @fields = fields.dup.freeze
      super("invalid input: #{@fields.join(', ')}")
    end
  end

  # raw は、要求の本文の Hash（文字列またはシンボルのキー）。Hash でなければ、種別の不備
  def self.parse(raw)
    attributes = normalize(raw)
    type = attributes["event_type"]
    raise InvalidInput, [ "event_type" ] unless type.is_a?(String) && !type.strip.empty?
    raise UnsupportedType unless SENDABLE_TYPES.include?(type)

    fields = []
    reason_code = pick(fields, "reason_code") { reason_code_of(attributes["reason_code"]) }
    bucket = pick(fields, "value") { bucket_of(type, attributes["value"]) }
    browser_class = pick(fields, "browser_class") { browser_class_of(attributes["browser_class"]) }
    raise InvalidInput, fields unless fields.empty?

    new(type: type, reason_code: reason_code, bucket: bucket, browser_class: browser_class)
  end

  def self.normalize(raw)
    raise InvalidInput, [ "event_type" ] unless raw.is_a?(Hash)

    raw.deep_stringify_keys
  end
  private_class_method :normalize

  # ブロックの検査が ArgumentError なら、項目名を fields に足し、nil を返す
  def self.pick(fields, name)
    yield
  rescue ArgumentError
    fields << name
    nil
  end
  private_class_method :pick

  def self.reason_code_of(value)
    return nil if value.nil?
    raise ArgumentError, "reason_code is invalid" unless value.is_a?(String) && UsageRecorder::REASON_CODE_PATTERN.match?(value)

    value
  end
  private_class_method :reason_code_of

  # value は、line_measured の実効スループットだけ。0 以上 MAX_VALUE 以下の整数。区分に変換する
  def self.bucket_of(type, value)
    return nil if value.nil?

    kind = VALUE_KINDS.fetch(type) { raise ArgumentError, "value is not accepted for this event type" }
    raise ArgumentError, "value is invalid" unless value.is_a?(Integer) && value.between?(0, MAX_VALUE)

    Bucketizer.bucket(kind, value)
  end
  private_class_method :bucket_of

  def self.browser_class_of(value)
    return nil if value.nil?
    raise ArgumentError, "browser_class is invalid" unless value.is_a?(Hash)

    BrowserClass.new(family: value["family"], supported: value["supported"])
  end
  private_class_method :browser_class_of
end
