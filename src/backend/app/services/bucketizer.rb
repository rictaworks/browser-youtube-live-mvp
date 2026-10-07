# 数値の区分（issue #7。requirements.md 18.2「配信時間・スループット等の数値は区分で記録する」）。
#
# 測定イベントには、数値そのものではなく、区分の文字列を記録する（数値のまま保存しない）。
#   "throughput_kbps:4100-4999"（4100 以上 4999 以下）・"count:0"（単独の値）・"duration_seconds:3600+"（以上。最後の区分）
# 区分の境界は、下の表（BOUNDARIES）で定義する。各区分は、境界（下限）から、次の境界の 1 つ前までで、最後の区分は、上限が無い。
# 区分の文字列の種類は、有限（labels）。測定イベントへ、任意の文字列を入れさせない（UsageRecorder が、valid_label? で検査する）。
module Bucketizer
  # 種類（単位つき） => 区分の下限の昇順（0 から始まる）
  #   duration_seconds  配信時間（秒）。3600 は、時間上限（既定 60 分）。上限に達した配信が、最後の区分に入る
  #   throughput_kbps   実効スループット（kbps）。1200・4100 は、プロファイルの選定の閾値（11.8）。境界が閾値をまたがない
  #   bitrate_kbps      映像ビットレート（kbps）。800・1500・2500・3000・4500・6000 は、プロファイルの下限・初期値・上限（11.7）
  #   dropped_frames    破棄したフレーム数（配信あたり）
  #   count             回数（劣化・再接続の発生など）
  BOUNDARIES = {
    "duration_seconds" => [ 0, 60, 300, 900, 1800, 2700, 3600 ].freeze,
    "throughput_kbps" => [ 0, 800, 1200, 2000, 3000, 4100, 5000, 6000, 8000 ].freeze,
    "bitrate_kbps" => [ 0, 800, 1500, 2500, 3000, 4500, 6000 ].freeze,
    "dropped_frames" => [ 0, 1, 10, 100, 1000 ].freeze,
    "count" => [ 0, 1, 2, 3, 5, 10 ].freeze
  }.freeze

  # 数値（0 以上の整数）の、区分の文字列。種類が未知・値が 0 以上の整数でなければ ArgumentError
  def self.bucket(kind, value)
    boundaries = BOUNDARIES.fetch(kind) { raise ArgumentError, "unknown bucket kind" }
    raise ArgumentError, "value must be a non-negative Integer" unless value.is_a?(Integer) && value >= 0

    label(kind, boundaries, boundaries.rindex { |lower| value >= lower })
  end

  # 有効な区分の文字列の一覧（種類 x 区分）
  def self.labels
    LABELS
  end

  # 区分の文字列か（nil・文字列でないもの・表に無い文字列は false）
  def self.valid_label?(value)
    value.is_a?(String) && LABEL_SET.include?(value)
  end

  # 境界の表の index 番目の区分の文字列
  def self.label(kind, boundaries, index)
    lower = boundaries.fetch(index)
    upper = boundaries[index + 1]
    return "#{kind}:#{lower}+" if upper.nil?
    return "#{kind}:#{lower}" if upper - 1 == lower

    "#{kind}:#{lower}-#{upper - 1}"
  end
  private_class_method :label

  LABELS = BOUNDARIES.flat_map { |kind, boundaries| boundaries.each_index.map { |index| label(kind, boundaries, index) } }.freeze
  LABEL_SET = LABELS.to_h { |text| [ text, true ] }.freeze
  private_constant :LABEL_SET
end
