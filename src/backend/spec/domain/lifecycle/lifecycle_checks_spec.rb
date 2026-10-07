require "spec_helper"
require "date"
require_relative "../support/domain_loader"

# 配信の生命周期の Domain Core が、引数・値の検査に使う部品（LifecycleChecks）。
# 違反は ArgumentError。黙って変換しない・既定値へ倒さない（フォールバック禁止）。メッセージは ASCII で、名前と型だけを載せる。
RSpec.describe "配信の生命周期の引数の検査（LifecycleChecks）" do
  describe ".time!" do
    it "Time を通し、そのまま返す" do
      time = Time.utc(2026, 10, 7, 12, 0, 0)

      expect(LifecycleChecks.time!(time, "now")).to equal(time)
    end

    {
      "文字列" => "2026-10-07T12:00:00Z",
      "整数" => 1_790_000_000,
      "nil" => nil,
      "Date（時刻を持たない）" => Date.new(2026, 10, 7)
    }.each do |label, value|
      it "#{label} は拒否する。名前と型をメッセージに載せる" do
        expect { LifecycleChecks.time!(value, "now") }
          .to raise_error(ArgumentError, "now must be a Time, got #{value.class}")
      end
    end
  end

  describe ".time_or_nil!" do
    it "nil を通す" do
      expect(LifecycleChecks.time_or_nil!(nil, "ended_at")).to be_nil
    end

    it "Time を通す" do
      time = Time.utc(2026, 10, 7)

      expect(LifecycleChecks.time_or_nil!(time, "ended_at")).to equal(time)
    end

    it "Time 以外は拒否する" do
      expect { LifecycleChecks.time_or_nil!("x", "ended_at") }
        .to raise_error(ArgumentError, "ended_at must be a Time or nil, got String")
    end
  end

  describe ".date!" do
    it "時刻を持たない Date を通し、そのまま返す" do
      date = Date.new(2026, 10, 7)

      expect(LifecycleChecks.date!(date, "usage_date")).to equal(date)
    end

    {
      "文字列" => "2026-10-07",
      "Time" => Time.utc(2026, 10, 7),
      "DateTime（時刻を持つ。Date のサブクラスだが拒否する）" => DateTime.new(2026, 10, 7),
      "nil" => nil
    }.each do |label, value|
      it "#{label} は拒否する" do
        expect { LifecycleChecks.date!(value, "usage_date") }
          .to raise_error(ArgumentError, "usage_date must be a Date, got #{value.class}")
      end
    end
  end

  describe ".integer!" do
    it "整数を通す" do
      expect(LifecycleChecks.integer!(3, "attempts", min: 0)).to eq(3)
    end

    [ 1.5, true, false, nil, "1", :one ].each do |value|
      it "#{value.inspect} は整数ではないので拒否する" do
        expect { LifecycleChecks.integer!(value, "attempts") }
          .to raise_error(ArgumentError, "attempts must be an Integer, got #{value.class}")
      end
    end

    it "最小値より小さければ拒否し、最小値ちょうどは通す" do
      expect(LifecycleChecks.integer!(0, "attempts", min: 0)).to eq(0)
      expect { LifecycleChecks.integer!(-1, "attempts", min: 0) }
        .to raise_error(ArgumentError, "attempts must be >= 0, got -1")
    end

    it "最大値より大きければ拒否し、最大値ちょうどは通す" do
      expect(LifecycleChecks.integer!(3, "attempts", max: 3)).to eq(3)
      expect { LifecycleChecks.integer!(4, "attempts", max: 3) }
        .to raise_error(ArgumentError, "attempts must be <= 3, got 4")
    end
  end

  describe ".boolean!" do
    it "true・false を通す" do
      expect(LifecycleChecks.boolean!(true, "flag")).to be(true)
      expect(LifecycleChecks.boolean!(false, "flag")).to be(false)
    end

    [ nil, "true", 1 ].each do |value|
      it "#{value.inspect} は拒否する" do
        expect { LifecycleChecks.boolean!(value, "flag") }
          .to raise_error(ArgumentError, "flag must be true or false, got #{value.class}")
      end
    end
  end

  describe ".text!" do
    it "空でない文字列を通す" do
      expect(LifecycleChecks.text!("dummy-id-1", "id")).to eq("dummy-id-1")
    end

    [ "", "   ", nil, :id, 1 ].each do |value|
      it "#{value.inspect} は拒否する" do
        expect { LifecycleChecks.text!(value, "id") }
          .to raise_error(ArgumentError, "id must be a non-empty String, got #{value.class}")
      end
    end
  end

  describe ".text_or_nil!" do
    it "nil と、空でない文字列を通す" do
      expect(LifecycleChecks.text_or_nil!(nil, "stream_id")).to be_nil
      expect(LifecycleChecks.text_or_nil!("dummy-stream", "stream_id")).to eq("dummy-stream")
    end

    it "空の文字列は拒否する（nil と区別する）" do
      expect { LifecycleChecks.text_or_nil!("", "stream_id") }
        .to raise_error(ArgumentError, "stream_id must be a non-empty String or nil, got String")
    end
  end

  describe ".contract_value!" do
    it "契約の列挙の符号（文字列）を通す" do
      expect(LifecycleChecks.contract_value!(Contract::EndReason, "user_stop", "reason")).to eq("user_stop")
    end

    it "列挙に無い値・シンボル・nil は拒否する。メッセージに列挙の名前と、値を載せる" do
      expect { LifecycleChecks.contract_value!(Contract::EndReason, "unknown_reason", "reason") }
        .to raise_error(ArgumentError, 'reason must be a Contract::EndReason value, got "unknown_reason"')
      expect { LifecycleChecks.contract_value!(Contract::EndReason, :user_stop, "reason") }
        .to raise_error(ArgumentError, "reason must be a Contract::EndReason value, got :user_stop")
      expect { LifecycleChecks.contract_value!(Contract::EndReason, nil, "reason") }
        .to raise_error(ArgumentError, "reason must be a Contract::EndReason value, got nil")
    end
  end

  describe ".kind!" do
    it "指定のクラスのインスタンスを通す" do
      expect(LifecycleChecks.kind!([], Array, "list")).to eq([])
    end

    it "別のクラスは拒否する" do
      expect { LifecycleChecks.kind!({}, Array, "list") }
        .to raise_error(ArgumentError, "list must be a Array, got Hash")
    end
  end
end
