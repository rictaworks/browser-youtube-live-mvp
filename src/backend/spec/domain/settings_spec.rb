require "spec_helper"
require_relative "support/domain_loader"

# 制限値・設定（requirements.md 8 章・19 章・20.4）。9 設定（契約の setting_key）を持つ、不変の値オブジェクト。
# 既定値は契約の limits.json（setting_defaults）。文字列の入力（管理画面・DB から）を型変換して検証する。
# 範囲外・型違いは例外にし、既定値へ黙って戻さない（9.3・CLAUDE.md のフォールバック禁止）。
#
# 範囲（仮置き。requirements.md に定めが無い）:
#   整数の設定は 0 以上 2,147,483,647（32 ビット符号付き整数。DB の integer 型に収まる）以下。
#   ただし、時間上限（分）と受付要求の頻度（回 / 時）は 1 以上（0 は、配信がすぐ終わる・受付がすべて拒否される、の意味になるため）、
#   1 日の割り当て（ユニット）は 1,000 以上（共通枠 500 と安全余裕 500 を引いて、配信に使える上限が負にならないため）。
#   bot 判定のスコアの閾値は、0 以上 1 以下（reCAPTCHA v3 のスコアの範囲）。
RSpec.describe "制限値・設定（Settings）" do
  let(:settings_class) { Settings }

  integer_keys = %w[
    daily_allowance attempt_limit concurrent_limit time_limit_minutes
    intake_rate_per_hour monthly_transfer_budget_gb daily_quota_units
  ].freeze
  all_keys = (integer_keys + %w[bot_score_threshold intake_paused]).freeze

  describe "9 設定（契約の setting_key）と既定値（契約の limits.json）" do
    it "メンバーは、契約の setting_key と同じ 9 件で、順も同じ" do
      expect(settings_class.members).to eq(Contract::SettingKey::ALL.map(&:to_sym))
      expect(settings_class.members.size).to eq(9)
      expect(settings_class.members.map(&:to_s)).to eq(all_keys.sort_by { |key| Contract::SettingKey::ALL.index(key) })
    end

    it "既定値は、契約の setting_defaults と、値も型（整数・浮動小数点・真偽値）も同じ" do
      defaults = settings_class.defaults

      Contract::Limits::SETTING_DEFAULTS.each do |key, expected|
        expect(defaults.public_send(key)).to eql(expected), "#{key}: #{defaults.public_send(key).inspect} != #{expected.inspect}"
      end
    end

    it "既定値は 1・3・3・60・10・10・10,000・0.5・false（requirements.md 8 章と U4 の仮置き）" do
      defaults = settings_class.defaults

      expect(defaults.to_h.values).to eq([ 1, 3, 3, 60, 10, 10, 10_000, 0.5, false ])
    end

    it "to_h は、シンボルのキーと型付きの値の、凍結した Hash" do
      hash = settings_class.defaults.to_h

      expect(hash.keys).to eq(settings_class.members)
      expect(hash).to be_frozen
    end
  end

  describe "不変" do
    it "値オブジェクトは凍結され、書き込みのメソッドを持たない" do
      settings = settings_class.defaults

      expect(settings).to be_frozen
      all_keys.each { |key| expect(settings).not_to respond_to("#{key}=") }
    end

    it "同じ値の Settings は等しい" do
      expect(settings_class.defaults).to eq(settings_class.defaults)
      expect(settings_class.defaults).not_to eq(settings_class.from_raw("daily_allowance" => "2"))
    end

    it "型付きの生成（new・with）は、検証する。文字列は受け付けない（文字列の変換は from_raw）" do
      defaults = settings_class.defaults

      expect { defaults.with(daily_allowance: -1) }.to raise_error(settings_class::InvalidSetting) { |error|
        expect([ error.key, error.reason ]).to eq([ "daily_allowance", :out_of_range ])
      }
      expect { defaults.with(daily_allowance: "1") }.to raise_error(settings_class::InvalidSetting) { |error|
        expect([ error.key, error.reason ]).to eq([ "daily_allowance", :invalid_type ])
      }
      expect { defaults.with(intake_paused: "false") }.to raise_error(settings_class::InvalidSetting) { |error|
        expect([ error.key, error.reason ]).to eq([ "intake_paused", :invalid_type ])
      }
      expect(defaults.with(daily_allowance: 2).daily_allowance).to eq(2)
      expect(defaults.daily_allowance).to eq(1)
    end

    it "すべてを指定しない new は失敗する（既定値で補わない。部分的な変更は defaults.with）" do
      expect { settings_class.new(daily_allowance: 2) }.to raise_error(ArgumentError)
    end
  end

  describe ".from_raw（文字列・型付きの入力を、型変換して検証する）" do
    {
      "daily_allowance" => [ [ "1", 1 ], [ "0", 0 ], [ "5", 5 ], [ "007", 7 ], [ 7, 7 ], [ "2147483647", 2_147_483_647 ] ],
      "attempt_limit" => [ [ "3", 3 ], [ "0", 0 ], [ 10, 10 ], [ "2147483647", 2_147_483_647 ] ],
      "concurrent_limit" => [ [ "3", 3 ], [ "0", 0 ], [ "100", 100 ], [ 5, 5 ] ],
      "time_limit_minutes" => [ [ "60", 60 ], [ "1", 1 ], [ 90, 90 ], [ "2147483647", 2_147_483_647 ] ],
      "intake_rate_per_hour" => [ [ "10", 10 ], [ "1", 1 ], [ 20, 20 ] ],
      "monthly_transfer_budget_gb" => [ [ "10", 10 ], [ "0", 0 ], [ 5, 5 ] ],
      "daily_quota_units" => [ [ "10000", 10_000 ], [ "1000", 1000 ], [ 20_000, 20_000 ], [ "2147483647", 2_147_483_647 ] ],
      "bot_score_threshold" => [
        [ "0.5", 0.5 ], [ "0", 0.0 ], [ "1", 1.0 ], [ "0.0", 0.0 ], [ "1.0", 1.0 ], [ "0.95", 0.95 ], [ "0.50", 0.5 ],
        [ "1e-1", 0.1 ], [ "5e-1", 0.5 ], [ "1.0e-05", 1.0e-05 ], [ 0.7, 0.7 ], [ 1, 1.0 ], [ 0, 0.0 ], [ 0.0, 0.0 ], [ 1.0, 1.0 ]
      ],
      "intake_paused" => [ [ "true", true ], [ "false", false ], [ true, true ], [ false, false ] ]
    }.each do |key, cases|
      cases.each do |raw, expected|
        it "#{key}: #{raw.inspect} は #{expected.inspect}" do
          value = settings_class.from_raw(key => raw).public_send(key)

          expect(value).to eql(expected)
        end
      end
    end

    it "シンボルのキーも受け付ける" do
      settings = settings_class.from_raw(daily_allowance: "2", intake_paused: "true")

      expect(settings.daily_allowance).to eq(2)
      expect(settings.intake_paused).to be(true)
    end

    it "9 設定すべてを、文字列で渡せる（管理画面・DB からの入力）" do
      raw = {
        "daily_allowance" => "2", "attempt_limit" => "5", "concurrent_limit" => "4", "time_limit_minutes" => "45",
        "intake_rate_per_hour" => "20", "monthly_transfer_budget_gb" => "8", "daily_quota_units" => "12000",
        "bot_score_threshold" => "0.7", "intake_paused" => "true"
      }

      expect(settings_class.from_raw(raw).to_h).to eq(
        daily_allowance: 2, attempt_limit: 5, concurrent_limit: 4, time_limit_minutes: 45,
        intake_rate_per_hour: 20, monthly_transfer_budget_gb: 8, daily_quota_units: 12_000,
        bot_score_threshold: 0.7, intake_paused: true
      )
    end

    it "指定しなかった項目は、既定値（契約の setting_defaults）になる。指定した項目だけが変わる" do
      settings = settings_class.from_raw("daily_allowance" => "2")

      expect(settings.daily_allowance).to eq(2)
      expect(settings.to_h.except(:daily_allowance)).to eq(settings_class.defaults.to_h.except(:daily_allowance))
      expect(settings_class.from_raw({})).to eq(settings_class.defaults)
    end

    it "to_h の往復（型付き・文字列）で、同じ値に戻る" do
      settings = settings_class.from_raw("daily_allowance" => "2", "bot_score_threshold" => "0.25", "intake_paused" => "true")

      expect(settings_class.from_raw(settings.to_h)).to eq(settings)
      expect(settings_class.from_raw(settings.to_h.transform_values(&:to_s))).to eq(settings)
    end

    it "入力の Hash を変更しない（凍結した Hash も渡せる）" do
      raw = { "daily_allowance" => "2" }.freeze

      expect(settings_class.from_raw(raw).daily_allowance).to eq(2)
      expect(raw).to eq({ "daily_allowance" => "2" })
    end
  end

  describe ".from_raw の型違い（invalid_type。既定値へ黙って戻さず、例外）" do
    integer_type_errors = [
      "", " ", " 1", "1 ", "1\n", "\n1", "1.5", "1.0", "1e3", "0x10", "0b1", "1_000", "abc", "-", "+1", "--1", "1-", "１",
      nil, true, false, 1.5, 3.0, [], {}, :one, Rational(1, 2)
    ]
    float_type_errors = [
      "", " ", " 0.5", "0.5 ", "0.5\n", ".5", "5.", "0,5", "abc", "NaN", "Infinity", "-Infinity", "0.5.1", "0x1", "１.０", "1e", "e1",
      nil, true, false, [], {}, :half, Float::NAN, Float::INFINITY, -Float::INFINITY, Rational(1, 2)
    ]
    boolean_type_errors = [
      "", " ", "TRUE", "True", "FALSE", "False", "yes", "no", "1", "0", "on", "off", " true", "true ", "t", "f",
      nil, 1, 0, 1.0, [], {}, :true
    ]

    integer_keys.each do |key|
      integer_type_errors.each do |raw|
        it "#{key}: #{raw.inspect} は型違い" do
          expect { settings_class.from_raw(key => raw) }.to raise_error(settings_class::InvalidSetting) { |error|
            expect(error.key).to eq(key)
            expect(error.reason).to eq(:invalid_type)
          }
        end
      end
    end

    float_type_errors.each do |raw|
      it "bot_score_threshold: #{raw.inspect} は型違い" do
        expect { settings_class.from_raw("bot_score_threshold" => raw) }.to raise_error(settings_class::InvalidSetting) { |error|
          expect(error.key).to eq("bot_score_threshold")
          expect(error.reason).to eq(:invalid_type)
        }
      end
    end

    boolean_type_errors.each do |raw|
      it "intake_paused: #{raw.inspect} は型違い" do
        expect { settings_class.from_raw("intake_paused" => raw) }.to raise_error(settings_class::InvalidSetting) { |error|
          expect(error.key).to eq("intake_paused")
          expect(error.reason).to eq(:invalid_type)
        }
      end
    end
  end

  describe ".from_raw の範囲外（out_of_range。既定値へ黙って戻さず、例外）" do
    {
      "daily_allowance" => [ "-1", -1, "2147483648", 2_147_483_648, 10**30 ],
      "attempt_limit" => [ "-1", -1, "2147483648" ],
      "concurrent_limit" => [ "-1", -1, "2147483648" ],
      "time_limit_minutes" => [ "0", 0, "-1", "2147483648" ],
      "intake_rate_per_hour" => [ "0", 0, "-1", "2147483648" ],
      "monthly_transfer_budget_gb" => [ "-1", -1, "2147483648" ],
      "daily_quota_units" => [ "999", 999, "0", "-1", "2147483648" ],
      "bot_score_threshold" => [ "-0.1", "-1", "1.1", "1.0000001", "2", "100", "1e1", -0.1, 1.1, 1.0000001, 2, -1, 100 ]
    }.each do |key, values|
      values.each do |raw|
        it "#{key}: #{raw.inspect} は範囲外" do
          expect { settings_class.from_raw(key => raw) }.to raise_error(settings_class::InvalidSetting) { |error|
            expect(error.key).to eq(key)
            expect(error.reason).to eq(:out_of_range)
          }
        end
      end
    end

    it "長すぎる文字列（65 文字以上）は、数値として解釈せず、型違い。64 文字までは解釈する" do
      expect { settings_class.from_raw("daily_allowance" => "1" * 65) }.to raise_error(settings_class::InvalidSetting) { |error|
        expect([ error.key, error.reason ]).to eq([ "daily_allowance", :invalid_type ])
      }
      expect { settings_class.from_raw("bot_score_threshold" => "0.#{'1' * 64}") }.to raise_error(settings_class::InvalidSetting) { |error|
        expect([ error.key, error.reason ]).to eq([ "bot_score_threshold", :invalid_type ])
      }
      expect(settings_class.from_raw("daily_allowance" => "0" * 64).daily_allowance).to eq(0)
      expect { settings_class.from_raw("daily_allowance" => "9" * 64) }.to raise_error(settings_class::InvalidSetting) { |error|
        expect(error.reason).to eq(:out_of_range)
      }
    end

    it "不正な値は、既定値へ黙って戻さず、例外になる（ほかの項目が正しくても）" do
      expect { settings_class.from_raw("daily_allowance" => "abc", "attempt_limit" => "5") }.to raise_error(settings_class::InvalidSetting)
      expect { settings_class.from_raw("daily_allowance" => "-1") }.to raise_error(settings_class::InvalidSetting)
    end

    it "範囲の境界（ちょうど）は有効で、1 つ外は無効" do
      expect(settings_class.from_raw("time_limit_minutes" => "1").time_limit_minutes).to eq(1)
      expect { settings_class.from_raw("time_limit_minutes" => "0") }.to raise_error(settings_class::InvalidSetting)
      expect(settings_class.from_raw("daily_quota_units" => "1000").daily_quota_units).to eq(1000)
      expect { settings_class.from_raw("daily_quota_units" => "999") }.to raise_error(settings_class::InvalidSetting)
      expect(settings_class.from_raw("bot_score_threshold" => "1").bot_score_threshold).to eq(1.0)
      expect { settings_class.from_raw("bot_score_threshold" => "1.01") }.to raise_error(settings_class::InvalidSetting)
    end

    it "1 日の割り当ての下限は、共通枠と安全余裕の合計（契約の固定値）" do
      floor = Contract::Limits::QUOTA.fetch("common_units") + Contract::Limits::QUOTA.fetch("safety_margin_units")

      expect(settings_class.from_raw("daily_quota_units" => floor.to_s).daily_quota_units).to eq(floor)
      expect { settings_class.from_raw("daily_quota_units" => (floor - 1).to_s) }.to raise_error(settings_class::InvalidSetting)
    end
  end

  describe ".from_raw のキーの検査" do
    it "未知のキー（綴りの誤り）は、unknown_key で失敗する（無視しない）" do
      [ "unknown_setting", "Daily_Allowance", "daily-allowance", "", :unknown, nil, 1 ].each do |key|
        expect { settings_class.from_raw(key => "1") }.to raise_error(settings_class::InvalidSetting) { |error|
          expect(error.reason).to eq(:unknown_key)
        }
      end
    end

    it "同じ項目を、文字列とシンボルの両方で渡すと、duplicate_key で失敗する（どちらが有効か曖昧）" do
      expect { settings_class.from_raw("daily_allowance" => "1", daily_allowance: "2") }.to raise_error(settings_class::InvalidSetting) { |error|
        expect([ error.key, error.reason ]).to eq([ "daily_allowance", :duplicate_key ])
      }
    end

    it "Hash 以外は ArgumentError" do
      [ nil, [], "daily_allowance=1", 1, :a ].each do |raw|
        expect { settings_class.from_raw(raw) }.to raise_error(ArgumentError, /raw/)
      end
    end

    it "複数の項目が不正なときは、契約の順で最初のものを報告する（決定的）" do
      expect { settings_class.from_raw("bot_score_threshold" => "9", "attempt_limit" => "x", "daily_allowance" => "-1") }
        .to raise_error(settings_class::InvalidSetting) { |error|
          expect(error.key).to eq("daily_allowance")
        }
      expect { settings_class.from_raw("bot_score_threshold" => "9", "attempt_limit" => "x") }
        .to raise_error(settings_class::InvalidSetting) { |error|
          expect(error.key).to eq("attempt_limit")
        }
    end
  end

  describe "InvalidSetting（失敗した項目・理由・値を、デバッグで辿れる）" do
    it "ArgumentError で、項目名・理由・入力の値（先頭だけ）をメッセージに含む。メッセージは ASCII" do
      expect { settings_class.from_raw("attempt_limit" => "-5") }.to raise_error(settings_class::InvalidSetting) { |error|
        expect(error).to be_a(ArgumentError)
        expect(error.message).to include("key=attempt_limit", "reason=out_of_range", "-5")
        expect(error.message).to be_ascii_only
      }
    end

    it "長い入力は、メッセージに全部を載せない（先頭の一部だけ）" do
      long = "9" * 500

      expect { settings_class.from_raw("attempt_limit" => long) }.to raise_error(settings_class::InvalidSetting) { |error|
        expect(error.message.length).to be < 200
      }
    end

    it "未知のキーのメッセージにも、キーと理由がある" do
      expect { settings_class.from_raw("nope" => "1") }.to raise_error(settings_class::InvalidSetting, /key=nope.*reason=unknown_key/)
    end
  end
end
