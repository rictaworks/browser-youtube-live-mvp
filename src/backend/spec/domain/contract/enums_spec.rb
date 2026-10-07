require "spec_helper"
require_relative "support/contracts_loader"

# 契約の列挙（src/contracts/enums.json）と、Ruby の定数モジュール（Contract::<名前>）の一致。
# JSON にあるものがモジュールに無い、モジュールにあるものが JSON に無い、のどちらも失敗する（両方向）。
RSpec.describe "契約の列挙（Ruby の定数モジュール）" do
  enums = ContractSpecSupport.load_json("enums.json").fetch("enums")
  counts = ContractSpecSupport::REQUIREMENTS_20_4_COUNTS.merge(ContractSpecSupport::CONTRACT_ONLY_COUNTS)

  before(:all) { ContractSpecSupport.load_contract_namespace! }

  it "24 の列挙がある（20.4 の 17 区分と、契約独自の 7 区分）" do
    expect(enums.keys.sort).to eq(counts.keys.sort)
    expect(enums.size).to eq(24)
  end

  it "20.4 の件数は 5・4・2・6・4・13・14・4・10・5・14・4・24・20・9・7・12" do
    expect(ContractSpecSupport::REQUIREMENTS_20_4_COUNTS.values).to eq([ 5, 4, 2, 6, 4, 13, 14, 4, 10, 5, 14, 4, 24, 20, 9, 7, 12 ])
  end

  enums.each do |name, definition|
    describe name do
      let(:values) { definition.fetch("values") }
      let(:mod) { Contract.const_get(ContractSpecSupport.module_name_for(name), false) }

      it "#{counts.fetch(name)} 件（#{ContractSpecSupport::REQUIREMENTS_20_4_COUNTS.key?(name) ? "20.4" : "契約独自"}）" do
        expect(mod::ALL.size).to eq(counts.fetch(name))
        expect(values.size).to eq(counts.fetch(name))
      end

      it "ALL は、JSON の values と一致する（順も含む）" do
        expect(mod::ALL).to eq(values)
      end

      it "ALL は凍結され、要素も凍結された文字列" do
        expect(mod::ALL).to be_frozen
        expect(mod::ALL).to all(be_a(String).and(be_frozen))
      end

      it "符号は英小文字の snake_case（数字を含んでよい）で、重複が無い" do
        expect(mod::ALL).to all(match(/\A[a-z0-9]+(_[a-z0-9]+)*\z/))
        expect(mod::ALL.uniq.size).to eq(mod::ALL.size)
      end

      it "値ごとの定数が、値と 1 対 1 である" do
        # color_role だけは、値ごとの定数のほかに、配色の表（HEX・ON_HEX）を持つ
        non_value_constants = name == "color_role" ? [ :ALL, :HEX, :ON_HEX ] : [ :ALL ]
        constants = mod.constants(false) - non_value_constants
        expected = values.map { |value| ContractSpecSupport.constant_name_for(value).to_sym }

        expect(constants.sort).to eq(expected.sort)
        values.each do |value|
          expect(mod.const_get(ContractSpecSupport.constant_name_for(value), false)).to eq(value)
        end
      end

      it "valid? は、各値で真" do
        values.each { |value| expect(mod.valid?(value)).to be(true), "#{value} が valid? で偽" }
      end

      it "valid? は、符号に似ていても、符号でないものは偽（型違い・大文字・空白・未知の値）" do
        invalid = [ nil, "", " ", "unknown", :symbol, 0, 1.5, true, [], {}, "x" * 100 ]
        values.each do |value|
          invalid += [ value.to_sym, "#{value} ", " #{value}", "#{value}\n", value.upcase, value.capitalize, "#{value}_" ]
        end
        invalid.reject! { |candidate| values.include?(candidate) }

        invalid.each { |candidate| expect(mod.valid?(candidate)).to be(false), "#{candidate.inspect} が valid? で真" }
      end

      it "valid? は、to_str を持ち、符号の文字列と等しく振る舞うオブジェクトも偽（文字列だけが符号）" do
        duck = Object.new
        value = values.first
        duck.define_singleton_method(:to_str) { value }
        duck.define_singleton_method(:==) { |other| other == value }

        expect(mod.valid?(duck)).to be(false)
      end

      it "値の定数は、凍結された文字列" do
        values.each { |value| expect(mod.const_get(ContractSpecSupport.constant_name_for(value), false)).to be_frozen }
      end
    end
  end

  describe "ValueSet" do
    it "valid? は、ALL を持つモジュールが extend して使う述語" do
      expect(Contract::ValueSet.instance_methods).to eq([ :valid? ])
    end

    it "すべての列挙が、ValueSet を extend している" do
      enums.each_key do |name|
        expect(Contract.const_get(ContractSpecSupport.module_name_for(name), false).singleton_class.include?(Contract::ValueSet)).to be(true), name
      end
    end
  end

  describe "ColorRole（17.2 の 12 役割の 16 進値）" do
    attributes = enums.fetch("color_role").fetch("attributes")

    it "HEX は、JSON の属性 hex と一致する（12 役割）" do
      expected = attributes.transform_values { |attribute| attribute.fetch("hex") }

      expect(Contract::ColorRole::HEX).to eq(expected)
      expect(Contract::ColorRole::HEX.size).to eq(12)
    end

    it "ON_HEX は、上に載せる文字の色を持つ役割（アクセントとライブ）だけ" do
      expected = attributes.select { |_, attribute| attribute.key?("on_hex") }.transform_values { |attribute| attribute.fetch("on_hex") }

      expect(Contract::ColorRole::ON_HEX).to eq(expected)
      expect(Contract::ColorRole::ON_HEX.keys).to eq(%w[ accent live ])
    end

    it "HEX・ON_HEX は凍結され、キーと値も凍結された文字列" do
      [ Contract::ColorRole::HEX, Contract::ColorRole::ON_HEX ].each do |table|
        expect(table).to be_frozen
        expect(table.keys).to all(be_frozen)
        expect(table.values).to all(be_frozen)
      end
    end

    it "HEX のキーは ALL と一致する" do
      expect(Contract::ColorRole::HEX.keys).to eq(Contract::ColorRole::ALL)
    end
  end

  describe "列挙どうしの整合" do
    it "ブラウザ側の出来事は、配信の出来事の種別の部分集合" do
      expect(Contract::BrowserEventKind::ALL - Contract::BroadcastEventType::ALL).to be_empty
    end

    it "拒否理由の順は 9.2 の順 0〜13（先頭は入力不備、末尾は API 割り当て不足）" do
      expect(Contract::RejectionReason::ALL.first).to eq(Contract::RejectionReason::INVALID_INPUT)
      expect(Contract::RejectionReason::ALL.last).to eq(Contract::RejectionReason::QUOTA_INSUFFICIENT)
    end

    it "メッセージ種別 end は、予約語 END と衝突しないよう END_ の定数名" do
      expect(Contract::WsMessageType::END_).to eq("end")
    end

    it "プロファイルの定数名は P720・P480" do
      expect(Contract::Profile::P720).to eq("720p")
      expect(Contract::Profile::P480).to eq("480p")
    end
  end
end
