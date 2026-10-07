require "rails_helper"

# 数値の区分（issue #7。requirements.md 18.2「配信時間・スループット等の数値は区分で記録する」）。
# 測定イベントには、数値そのものではなく、区分の文字列（"throughput_kbps:4100-4999" など）を記録する。
# 区分の境界は、表（Bucketizer::BOUNDARIES）で定義する。境界の値の前後で、区分が変わることを確かめる。
RSpec.describe Bucketizer do
  # [ 種類, [ [ 値, 期待する区分 ], ... ] ]。境界の値（下限）と、その 1 つ前の値の両方を含める
  tables = {
    "duration_seconds" => [
      [ 0, "duration_seconds:0-59" ],
      [ 59, "duration_seconds:0-59" ],
      [ 60, "duration_seconds:60-299" ],
      [ 299, "duration_seconds:60-299" ],
      [ 300, "duration_seconds:300-899" ],
      [ 899, "duration_seconds:300-899" ],
      [ 900, "duration_seconds:900-1799" ],
      [ 1799, "duration_seconds:900-1799" ],
      [ 1800, "duration_seconds:1800-2699" ],
      [ 2699, "duration_seconds:1800-2699" ],
      [ 2700, "duration_seconds:2700-3599" ],
      [ 3599, "duration_seconds:2700-3599" ],
      [ 3600, "duration_seconds:3600+" ],
      [ 7200, "duration_seconds:3600+" ]
    ],
    "throughput_kbps" => [
      [ 0, "throughput_kbps:0-799" ],
      [ 799, "throughput_kbps:0-799" ],
      [ 800, "throughput_kbps:800-1199" ],
      [ 1199, "throughput_kbps:800-1199" ],
      [ 1200, "throughput_kbps:1200-1999" ],
      [ 1999, "throughput_kbps:1200-1999" ],
      [ 2000, "throughput_kbps:2000-2999" ],
      [ 2999, "throughput_kbps:2000-2999" ],
      [ 3000, "throughput_kbps:3000-4099" ],
      [ 4099, "throughput_kbps:3000-4099" ],
      [ 4100, "throughput_kbps:4100-4999" ],
      [ 4999, "throughput_kbps:4100-4999" ],
      [ 5000, "throughput_kbps:5000-5999" ],
      [ 5999, "throughput_kbps:5000-5999" ],
      [ 6000, "throughput_kbps:6000-7999" ],
      [ 7999, "throughput_kbps:6000-7999" ],
      [ 8000, "throughput_kbps:8000+" ],
      [ 1_000_000, "throughput_kbps:8000+" ]
    ],
    "bitrate_kbps" => [
      [ 0, "bitrate_kbps:0-799" ],
      [ 799, "bitrate_kbps:0-799" ],
      [ 800, "bitrate_kbps:800-1499" ],
      [ 1499, "bitrate_kbps:800-1499" ],
      [ 1500, "bitrate_kbps:1500-2499" ],
      [ 2499, "bitrate_kbps:1500-2499" ],
      [ 2500, "bitrate_kbps:2500-2999" ],
      [ 2999, "bitrate_kbps:2500-2999" ],
      [ 3000, "bitrate_kbps:3000-4499" ],
      [ 4499, "bitrate_kbps:3000-4499" ],
      [ 4500, "bitrate_kbps:4500-5999" ],
      [ 5999, "bitrate_kbps:4500-5999" ],
      [ 6000, "bitrate_kbps:6000+" ]
    ],
    "dropped_frames" => [
      [ 0, "dropped_frames:0" ],
      [ 1, "dropped_frames:1-9" ],
      [ 9, "dropped_frames:1-9" ],
      [ 10, "dropped_frames:10-99" ],
      [ 99, "dropped_frames:10-99" ],
      [ 100, "dropped_frames:100-999" ],
      [ 999, "dropped_frames:100-999" ],
      [ 1000, "dropped_frames:1000+" ],
      [ 50_000, "dropped_frames:1000+" ]
    ],
    "count" => [
      [ 0, "count:0" ],
      [ 1, "count:1" ],
      [ 2, "count:2" ],
      [ 3, "count:3-4" ],
      [ 4, "count:3-4" ],
      [ 5, "count:5-9" ],
      [ 9, "count:5-9" ],
      [ 10, "count:10+" ],
      [ 11, "count:10+" ]
    ]
  }

  it "区分の種類は、配信時間・スループット・ビットレート・破棄フレーム数・回数の 5 つ" do
    expect(described_class::BOUNDARIES.keys).to eq(tables.keys)
    expect(described_class::BOUNDARIES).to be_frozen
  end

  tables.each do |kind, cases|
    describe "#{kind} の境界の表" do
      cases.each do |value, expected|
        it "#{value} → #{expected}" do
          expect(described_class.bucket(kind, value)).to eq(expected)
        end
      end

      it "境界（下限）は、昇順で、0 から始まる" do
        boundaries = described_class::BOUNDARIES.fetch(kind)

        expect(boundaries.first).to eq(0)
        expect(boundaries).to eq(boundaries.sort.uniq)
      end

      it "表のすべての区分が、有効な区分の文字列として認められる" do
        cases.each { |_, label| expect(described_class.valid_label?(label)).to be(true) }
      end
    end
  end

  describe "契約の数値との整合（区分の境界が、判定の閾値をまたがない）" do
    it "スループットの境界に、プロファイルの閾値（4,100・1,200 kbps。11.8）が入っている" do
      thresholds = Contract::Limits::PROFILES.values.map { |profile| profile.fetch("line_threshold_kbps") }

      expect(described_class::BOUNDARIES.fetch("throughput_kbps")).to include(*thresholds)
    end

    it "ビットレートの境界に、プロファイルの下限・初期値・上限（11.7）が入っている" do
      values = Contract::Limits::PROFILES.values.flat_map do |profile|
        profile.values_at("video_bitrate_min_kbps", "video_bitrate_initial_kbps", "video_bitrate_max_kbps")
      end

      expect(described_class::BOUNDARIES.fetch("bitrate_kbps")).to include(*values)
    end

    it "配信時間の境界に、時間上限（既定 60 分）が入っている" do
      limit = Contract::Limits::SETTING_DEFAULTS.fetch("time_limit_minutes") * 60

      expect(described_class::BOUNDARIES.fetch("duration_seconds")).to include(limit)
    end
  end

  describe "#bucket（入力の検査）" do
    it "未知の種類は、例外にする" do
      [ "unknown", nil, :count, "" ].each do |kind|
        expect { described_class.bucket(kind, 1) }.to raise_error(ArgumentError, /kind/)
      end
    end

    {
      "負の数" => -1,
      "小数" => 1.5,
      "文字列" => "5",
      "nil" => nil,
      "真偽値" => true,
      "配列" => [ 1 ],
      "NaN" => Float::NAN,
      "無限大" => Float::INFINITY
    }.each do |label, value|
      it "値が #{label} なら、例外にする（0 以上の整数だけ）" do
        expect { described_class.bucket("count", value) }.to raise_error(ArgumentError, /value/)
      end
    end

    it "整数なら、どんなに大きくても、最後の区分に入る（例外にしない）" do
      expect(described_class.bucket("count", 10**30)).to eq("count:10+")
    end
  end

  describe ".valid_label?（区分の文字列の検査。測定イベントに、任意の文字列を入れない）" do
    it "すべての区分の文字列を、認める（種類 x 区分）" do
      all = described_class.labels

      expect(all).not_to be_empty
      expect(all).to all(satisfy { |label| described_class.valid_label?(label) })
      expect(all.size).to eq(described_class::BOUNDARIES.values.sum(&:size))
    end

    [ nil, "", "count", "count:", "count:11", "count:5-8", "unknown:0", "count:0 ", " count:0", "COUNT:0", "count:0\n", 5, :"count:0" ].each do |label|
      it "区分でない文字列 #{label.inspect} は認めない" do
        expect(described_class.valid_label?(label)).to be(false)
      end
    end

    it "氏名・メールアドレス・IP・タイトルのような文字列は、認めない" do
      [ "dummy@example.test", "203.0.113.5", "Mozilla/5.0 (X11; Linux x86_64)", "dummy-title" ].each do |text|
        expect(described_class.valid_label?(text)).to be(false)
      end
    end
  end

  describe ".labels" do
    it "区分の文字列の一覧は、凍結されている" do
      expect(described_class.labels).to be_frozen
    end

    it "重複が無い" do
      expect(described_class.labels).to eq(described_class.labels.uniq)
    end
  end
end
