require "rails_helper"
require "support/model_support"

# 設定値の読み書き（requirements.md 8 章・19 章・20.4）。system_settings（キーと値の文字列）を、#5 の Settings へ変換する。
# 規則（型・範囲・既定値）は Domain Core（Settings・契約の limits.json）が持つ。このサービスは、読み書きだけを行う。
#   current   毎回 DB を読む（キャッシュしない。制限値の変更は、次の受付から適用する）。行が無いキーは既定値。壊れた値は例外
#   update!   検証したうえで、upsert する。操作の記録は、呼び出し側（管理画面）が別に行う
RSpec.describe SettingsStore do
  def store_row(key, value)
    SystemSetting.create!(key: key, value: value)
  end

  # 検証を通さずに（モデルの検証が先に拒否しないように）、行を書く
  def store_raw_row(key, value)
    save_without_validation!(SystemSetting.new(key: key, value: value, updated_at: Time.current))
  end

  describe ".current" do
    it "行が無ければ、すべて既定値（#5 の Settings.defaults。契約の limits.json の setting_defaults）" do
      expect(described_class.current).to eq(Settings.defaults)
      expect(described_class.current.to_h).to eq(Contract::Limits::SETTING_DEFAULTS.transform_keys(&:to_sym))
    end

    it "戻り値は、型付きの Settings（Data。不変）" do
      settings = described_class.current

      expect(settings).to be_a(Settings)
      expect(settings).to be_frozen
    end

    it "行があるキーだけを上書きし、ほかのキーは既定値のまま" do
      store_row("daily_allowance", "3")

      settings = described_class.current

      expect(settings.daily_allowance).to eq(3)
      expect(settings.with(daily_allowance: Settings.defaults.daily_allowance)).to eq(Settings.defaults)
    end

    {
      "daily_allowance" => [ "2", 2 ],
      "attempt_limit" => [ "5", 5 ],
      "concurrent_limit" => [ "4", 4 ],
      "time_limit_minutes" => [ "30", 30 ],
      "intake_rate_per_hour" => [ "20", 20 ],
      "monthly_transfer_budget_gb" => [ "100", 100 ],
      "daily_quota_units" => [ "8000", 8000 ],
      "bot_score_threshold" => [ "0.7", 0.7 ],
      "intake_paused" => [ "true", true ]
    }.each do |key, (stored, typed)|
      it "#{key}: 文字列 #{stored.inspect} を、型付きの値 #{typed.inspect} に変換して返す" do
        store_row(key, stored)

        expect(described_class.current.public_send(key)).to eq(typed)
      end
    end

    it "9 つの設定を、すべて同時に上書きできる" do
      { "daily_allowance" => "2", "attempt_limit" => "5", "concurrent_limit" => "4", "time_limit_minutes" => "30",
        "intake_rate_per_hour" => "20", "monthly_transfer_budget_gb" => "100", "daily_quota_units" => "8000",
        "bot_score_threshold" => "0.7", "intake_paused" => "true" }.each { |key, value| store_row(key, value) }

      expect(described_class.current.to_h).to eq(
        daily_allowance: 2, attempt_limit: 5, concurrent_limit: 4, time_limit_minutes: 30, intake_rate_per_hour: 20,
        monthly_transfer_budget_gb: 100, daily_quota_units: 8000, bot_score_threshold: 0.7, intake_paused: true
      )
    end

    it "キャッシュしない: 行を書き換えると、次の呼び出しに、すぐ反映される（制限値の変更は、次の受付から適用する）" do
      store_row("daily_allowance", "2")
      expect(described_class.current.daily_allowance).to eq(2)

      SystemSetting.find("daily_allowance").update_columns(value: "9")

      expect(described_class.current.daily_allowance).to eq(9)
    end

    it "呼び出しのたびに、system_settings を読む（SELECT が毎回発行される）" do
      statements = capture_sql do
        described_class.current
        described_class.current
      end

      expect(statements.grep(/\ASELECT .*FROM "system_settings"/).size).to eq(2)
    end

    it "行を追加・削除しても、次の呼び出しに反映される（行が無くなれば、既定値へ戻る。これは、行が無い場合の既定値であって、壊れた値の救済ではない）" do
      store_row("attempt_limit", "7")
      expect(described_class.current.attempt_limit).to eq(7)

      SystemSetting.where(key: "attempt_limit").delete_all

      expect(described_class.current.attempt_limit).to eq(Settings.defaults.attempt_limit)
    end

    describe "壊れた値は、既定値へ黙って戻さず、例外にする" do
      {
        "整数でない文字列" => [ "daily_allowance", "abc", :invalid_type ],
        "小数の整数" => [ "attempt_limit", "1.5", :invalid_type ],
        "前後に空白" => [ "concurrent_limit", " 3", :invalid_type ],
        "桁区切り" => [ "time_limit_minutes", "1,000", :invalid_type ],
        "真偽値でない文字列" => [ "intake_paused", "yes", :invalid_type ],
        "数値でない閾値" => [ "bot_score_threshold", "high", :invalid_type ],
        "負の整数" => [ "daily_allowance", "-1", :out_of_range ],
        "時間上限が 0" => [ "time_limit_minutes", "0", :out_of_range ],
        "1 日の割り当てが、共通枠と安全余裕に満たない" => [ "daily_quota_units", "999", :out_of_range ],
        "閾値が 1 を超える" => [ "bot_score_threshold", "1.5", :out_of_range ],
        "32 ビットの上限を超える" => [ "concurrent_limit", "2147483648", :out_of_range ]
      }.each do |label, (key, value, reason)|
        it "#{label}（#{key} = #{value.inspect}）: SettingsStore::CorruptSetting（理由 #{reason}）" do
          store_row(key, value)

          expect { described_class.current }.to raise_error(SettingsStore::CorruptSetting) { |error|
            expect(error.key).to eq(key)
            expect(error.reason).to eq(reason)
            expect(error.message).to include(key, reason.to_s)
          }
        end
      end

      it "未知のキーの行（契約の setting_key に無い）: SettingsStore::CorruptSetting（理由 unknown_key）" do
        store_raw_row("no_such_setting", "1")

        expect { described_class.current }.to raise_error(SettingsStore::CorruptSetting) { |error|
          expect(error.key).to eq("no_such_setting")
          expect(error.reason).to eq(:unknown_key)
        }
      end

      it "原因（Settings::InvalidSetting）を残す（デバッグでたどれる）" do
        store_row("daily_allowance", "abc")

        expect { described_class.current }.to raise_error(SettingsStore::CorruptSetting) { |error|
          expect(error.cause).to be_a(Settings::InvalidSetting)
        }
      end

      it "1 つでも壊れた行があれば、ほかの行が正しくても、例外（一部だけ既定値にした設定を返さない）" do
        store_row("attempt_limit", "5")
        store_row("daily_allowance", "abc")

        expect { described_class.current }.to raise_error(SettingsStore::CorruptSetting)
      end
    end
  end

  describe ".update!" do
    it "設定を保存して、型付きの値を返す。次の current に反映される" do
      value = described_class.update!(key: "daily_allowance", value: 3)

      expect(value).to eq(3)
      expect(SystemSetting.find("daily_allowance").value).to eq("3")
      expect(described_class.current.daily_allowance).to eq(3)
    end

    it "キーは、文字列でもシンボルでもよい" do
      described_class.update!(key: :attempt_limit, value: 4)
      described_class.update!(key: "concurrent_limit", value: 5)

      expect(described_class.current).to have_attributes(attempt_limit: 4, concurrent_limit: 5)
    end

    it "同じキーの更新は、行を増やさず、値を置き換える（upsert）" do
      described_class.update!(key: "daily_allowance", value: 2)
      described_class.update!(key: "daily_allowance", value: 5)

      expect(SystemSetting.where(key: "daily_allowance").count).to eq(1)
      expect(described_class.current.daily_allowance).to eq(5)
    end

    it "ほかのキーの行に触れない" do
      described_class.update!(key: "attempt_limit", value: 6)
      before = SystemSetting.find("attempt_limit").attributes

      described_class.update!(key: "daily_allowance", value: 2)

      expect(SystemSetting.find("attempt_limit").attributes).to eq(before)
    end

    {
      "整数（型付き）" => [ "daily_allowance", 7, "7", 7 ],
      "整数（文字列）" => [ "daily_allowance", "7", "7", 7 ],
      "先頭の 0 がある整数の文字列は、正規の形で保存する" => [ "attempt_limit", "05", "5", 5 ],
      "小数（型付き）" => [ "bot_score_threshold", 0.8, "0.8", 0.8 ],
      "小数（文字列）" => [ "bot_score_threshold", "0.80", "0.8", 0.8 ],
      "小数の設定に整数を渡す" => [ "bot_score_threshold", 1, "1.0", 1.0 ],
      "真偽値（true）" => [ "intake_paused", true, "true", true ],
      "真偽値（文字列 false）" => [ "intake_paused", "false", "false", false ],
      "境界: 1 日の割り当ての下限（共通枠 + 安全余裕）" => [ "daily_quota_units", 1000, "1000", 1000 ],
      "境界: 閾値の下限 0" => [ "bot_score_threshold", 0.0, "0.0", 0.0 ],
      "境界: 閾値の上限 1" => [ "bot_score_threshold", 1.0, "1.0", 1.0 ],
      "境界: 時間上限の下限 1" => [ "time_limit_minutes", 1, "1", 1 ]
    }.each do |label, (key, input, stored, typed)|
      it "#{label}: #{key} = #{input.inspect} を、#{stored.inspect} として保存し、#{typed.inspect} を返す" do
        expect(described_class.update!(key: key, value: input)).to eq(typed)
        expect(SystemSetting.find(key).value).to eq(stored)
        expect(described_class.current.public_send(key)).to eq(typed)
      end
    end

    describe "intake_paused の読み書き" do
      it "true にすると、受付停止になり、false にすると、解除される" do
        expect(described_class.current.intake_paused).to be(false)

        described_class.update!(key: "intake_paused", value: true)
        expect(described_class.current.intake_paused).to be(true)

        described_class.update!(key: "intake_paused", value: false)
        expect(described_class.current.intake_paused).to be(false)
      end
    end

    describe "不正な入力は、例外にし、何も保存しない" do
      {
        "未知のキー" => [ "no_such_setting", 1, :unknown_key ],
        "キーが nil" => [ nil, 1, :unknown_key ],
        "整数でない文字列" => [ "daily_allowance", "abc", :invalid_type ],
        "整数の設定に小数" => [ "daily_allowance", 1.5, :invalid_type ],
        "整数の設定に真偽値" => [ "daily_allowance", true, :invalid_type ],
        "整数の設定に nil" => [ "daily_allowance", nil, :invalid_type ],
        "前後に空白のある整数" => [ "attempt_limit", " 3", :invalid_type ],
        "真偽値の設定に整数" => [ "intake_paused", 1, :invalid_type ],
        "真偽値の設定に yes" => [ "intake_paused", "yes", :invalid_type ],
        "小数の設定に文字列でない値" => [ "bot_score_threshold", [ 0.5 ], :invalid_type ],
        "小数の設定に NaN" => [ "bot_score_threshold", Float::NAN, :invalid_type ],
        "負の整数" => [ "concurrent_limit", -1, :out_of_range ],
        "時間上限 0" => [ "time_limit_minutes", 0, :out_of_range ],
        "受付要求の頻度 0" => [ "intake_rate_per_hour", 0, :out_of_range ],
        "1 日の割り当てが下限未満" => [ "daily_quota_units", 999, :out_of_range ],
        "閾値が負" => [ "bot_score_threshold", -0.1, :out_of_range ],
        "閾値が 1 を超える" => [ "bot_score_threshold", 1.1, :out_of_range ],
        "32 ビットの上限を超える" => [ "monthly_transfer_budget_gb", 2_147_483_648, :out_of_range ]
      }.each do |label, (key, value, reason)|
        it "#{label}: Settings::InvalidSetting（理由 #{reason}）。行は作られない" do
          expect { described_class.update!(key: key, value: value) }.to raise_error(Settings::InvalidSetting) { |error|
            expect(error.reason).to eq(reason)
          }
          expect(SystemSetting.count).to eq(0)
        end
      end

      it "不正な更新は、保存済みの値を変えない" do
        described_class.update!(key: "daily_allowance", value: 2)

        expect { described_class.update!(key: "daily_allowance", value: -5) }.to raise_error(Settings::InvalidSetting)

        expect(SystemSetting.find("daily_allowance").value).to eq("2")
      end
    end

    it "操作の記録（admin_actions）を書かない（記録は、呼び出し側の管理画面が別に行う）" do
      expect { described_class.update!(key: "daily_allowance", value: 2) }.not_to change(AdminAction, :count)
    end

    it "updated_at を設定する" do
      described_class.update!(key: "daily_allowance", value: 2)

      expect(SystemSetting.find("daily_allowance").updated_at).to be_within(1.minute).of(Time.current)
    end

    it "ほかの行が壊れていても、検証に通る値は保存できる（更新は、ほかの行を読まない）" do
      store_raw_row("no_such_setting", "1")

      expect(described_class.update!(key: "daily_allowance", value: 2)).to eq(2)
      expect(SystemSetting.find("daily_allowance").value).to eq("2")
    end

    it "1 つの upsert 文で保存する（読んでから書く 2 段にしない。同時の更新で、行が重ならない）" do
      statements = capture_sql { described_class.update!(key: "daily_allowance", value: 2) }
      writes = statements.grep(/\A(INSERT|UPDATE) /)

      expect(writes.size).to eq(1)
      expect(writes.first).to match(/\AINSERT INTO "system_settings".*ON CONFLICT \("key"\) DO UPDATE/m)
    end
  end
end
