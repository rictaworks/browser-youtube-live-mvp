require "spec_helper"
require_relative "support/contracts_loader"

# 契約の制限値・定数（src/contracts/limits.json）と、Ruby の定数 Contract::Limits::<セクション> の一致。
# セクション（JSON のトップレベルのキー）ごとに、深く凍結した、JSON と同じ形の Hash を持つ。
# JSON にあるものがモジュールに無い、モジュールにあるものが JSON に無い、のどちらも失敗する（両方向）。
RSpec.describe "契約の制限値（Ruby の定数 Contract::Limits）" do
  limits = ContractSpecSupport.strip_document_keys(ContractSpecSupport.load_json("limits.json"))

  before(:all) { ContractSpecSupport.load_contract_namespace! }

  def deep_frozen?(value)
    case value
    when Hash then value.frozen? && value.all? { |key, child| key.frozen? && deep_frozen?(child) }
    when Array then value.frozen? && value.all? { |child| deep_frozen?(child) }
    else value.frozen?
    end
  end

  it "セクションは、JSON のトップレベルと過不足なく一致する" do
    expect(Contract::Limits.constants(false).sort).to eq(limits.keys.map { |section| section.upcase.to_sym }.sort)
  end

  limits.each do |section, expected|
    describe section do
      let(:actual) { Contract::Limits.const_get(section.upcase, false) }

      it "JSON と一致する（型まで。整数と浮動小数点を区別する）" do
        expect(ContractSpecSupport.same_value?(actual, expected)).to be(true), "#{section}: #{actual.inspect} != #{expected.inspect}"
      end

      it "深く凍結されている（Hash・Array・文字列）" do
        expect(deep_frozen?(actual)).to be(true)
      end
    end
  end

  describe "設計メモの値（抜き取り）" do
    it "プロファイル 720p・480p（11.7）と回線の閾値（11.8）" do
      expect(Contract::Limits::PROFILES.fetch(Contract::Profile::P720)).to eq(
        "width" => 1280, "height" => 720, "framerate" => 30,
        "video_bitrate_min_kbps" => 3000, "video_bitrate_initial_kbps" => 4500, "video_bitrate_max_kbps" => 6000,
        "line_threshold_kbps" => 4100
      )
      expect(Contract::Limits::PROFILES.fetch(Contract::Profile::P480).fetch("line_threshold_kbps")).to eq(1200)
    end

    it "プロファイルのキーは、列挙 Profile の値" do
      expect(Contract::Limits::PROFILES.keys).to eq(Contract::Profile::ALL)
    end

    it "適応制御の条件のキーは、列挙 AdaptiveCondition の値（12 章の表の順）" do
      expect(Contract::Limits::ADAPTIVE.fetch("conditions").keys).to eq(Contract::AdaptiveCondition::ALL)
    end

    it "設定の既定値のキーは、列挙 SettingKey の値（8 章の 9 設定）" do
      expect(Contract::Limits::SETTING_DEFAULTS.keys).to eq(Contract::SettingKey::ALL)
      expect(Contract::Limits::SETTING_DEFAULTS.fetch(Contract::SettingKey::BOT_SCORE_THRESHOLD)).to eq(0.5)
      expect(Contract::Limits::SETTING_DEFAULTS.fetch(Contract::SettingKey::INTAKE_PAUSED)).to be(false)
    end

    it "WebSocket フレームの種別は、列挙 WsMessageType の値。種別符号は重複しない" do
      types = Contract::Limits::WS_FRAME.fetch("types")
      codes = types.values.map { |type| type.fetch("code") }

      expect(types.keys).to eq(Contract::WsMessageType::ALL)
      expect(codes.uniq.size).to eq(14)
      expect(types.fetch(Contract::WsMessageType::HELLO).fetch("code")).to eq(0x01)
      expect(types.fetch(Contract::WsMessageType::END_).fetch("code")).to eq(0x07)
      expect(types.fetch(Contract::WsMessageType::ACCEPTED).fetch("code")).to eq(0x81)
      expect(types.fetch(Contract::WsMessageType::FATAL).fetch("code")).to eq(0x87)
      expect(Contract::Limits::WS_FRAME.fetch("max_message_bytes")).to eq(2_097_152)
      expect(Contract::Limits::WS_FRAME.fetch("header_bytes")).to eq(17)
      expect(Contract::Limits::WS_FRAME.fetch("magic")).to eq([ 0x42, 0x4C ])
    end

    it "割り当て台帳（8.4）の算術：共通枠 + 安全余裕 + 配信に使える上限 = 1 日の割り当て、予約 550 = 340 + 210" do
      quota = Contract::Limits::QUOTA
      daily = Contract::Limits::SETTING_DEFAULTS.fetch("daily_quota_units")

      expect(quota.fetch("common_units") + quota.fetch("safety_margin_units") + quota.fetch("broadcast_usable_units_at_default")).to eq(daily)
      expect(quota.fetch("prep_reservation_units") + quota.fetch("settle_reservation_units")).to eq(quota.fetch("broadcast_reservation_units"))
      expect(quota.fetch("unit_costs")).to eq("list" => 1, "insert" => 50, "update" => 50, "bind" => 50, "transition" => 50, "delete" => 50)
    end

    it "期限（13.2）：受理済み 90 秒・送出待ち 30 秒・確定待ち 120 秒・復帰 10 回・清算の再試行は 1・2・4 分" do
      deadlines = Contract::Limits::DEADLINES

      expect(deadlines.values_at("reserved_seconds", "awaiting_media_seconds", "confirming_seconds")).to eq([ 90, 30, 120 ])
      expect(deadlines.fetch("max_resumes")).to eq(10)
      expect(deadlines.fetch("settlement_retry_delays_seconds")).to eq([ 60, 120, 240 ])
    end

    it "RTMPS の送出先の許可（ホスト・ポート 443・rtmps）と、疑似の取り込み口（fake-ingest・1935）" do
      ingest = Contract::Limits::RTMPS_INGEST
      dev = Contract::Limits::DEV_INGEST

      expect(ingest.fetch("hosts")).to eq([ "a.rtmps.youtube.com", "b.rtmps.youtube.com" ])
      expect(ingest.values_at("scheme", "port", "userinfo_allowed", "query_allowed")).to eq([ "rtmps", 443, false, false ])
      expect(dev.values_at("host", "port", "scheme")).to eq([ "fake-ingest", 1935, "rtmps" ])
      expect(dev.fetch("allowed_environments")).to eq(%w[ development test ])
    end
  end

  describe "文書用のキーを複製しない" do
    it "モジュールの Hash に、$comment・note・*_note のキーが無い" do
      Contract::Limits.constants(false).each do |name|
        keys = []
        collector = lambda do |value|
          case value
          when Hash then value.each { |key, child| keys << key; collector.call(child) }
          when Array then value.each { |child| collector.call(child) }
          end
        end
        collector.call(Contract::Limits.const_get(name, false))

        expect(keys.grep(ContractSpecSupport::DOCUMENT_KEY)).to be_empty, "#{name} に文書用のキーがあります"
      end
    end
  end
end
