require "rails_helper"

# ブラウザの分類（issue #7。requirements.md 18.2「ブラウザの種別は、分類（系統と対応の可否）のみを記録する」）。
# ユーザーエージェントの文字列を、受け取らない・保存しない。
RSpec.describe BrowserClass do
  describe ".new" do
    it "系統（chromium・firefox・webkit・other）と、対応可否（真偽値）だけを持つ" do
      browser = described_class.new(family: "chromium", supported: true)

      expect(browser.family).to eq("chromium")
      expect(browser.supported).to be(true)
    end

    it "系統の一覧は、4 つ" do
      expect(described_class::FAMILIES).to eq(%w[ chromium firefox webkit other ])
    end

    [ "Chrome", "chrome", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36", "", nil, :chromium, 1 ].each do |family|
      it "系統 #{family.inspect[0, 30]} は、例外にする（ユーザーエージェントの文字列を、受け取らない）" do
        expect { described_class.new(family: family, supported: true) }.to raise_error(ArgumentError)
      end
    end

    [ nil, "true", 1, 0, "yes", :true ].each do |supported|
      it "対応可否 #{supported.inspect} は、例外にする（真偽値だけ）" do
        expect { described_class.new(family: "chromium", supported: supported) }.to raise_error(ArgumentError)
      end
    end

    it "余分な属性（ユーザーエージェント・端末）は、受け付けない" do
      expect { described_class.new(family: "chromium", supported: true, user_agent: "Mozilla/5.0") }.to raise_error(ArgumentError)
    end
  end

  describe "#to_s（DB の列 usage_events.browser_class の値）" do
    {
      [ "chromium", true ] => "chromium:supported",
      [ "chromium", false ] => "chromium:unsupported",
      [ "firefox", true ] => "firefox:supported",
      [ "webkit", false ] => "webkit:unsupported",
      [ "other", false ] => "other:unsupported"
    }.each do |(family, supported), expected|
      it "#{family}・#{supported} → #{expected}" do
        expect(described_class.new(family: family, supported: supported).to_s).to eq(expected)
      end
    end
  end

  describe ".parse（DB の値から、元に戻す）" do
    it "往復できる" do
      browser = described_class.new(family: "webkit", supported: false)

      expect(described_class.parse(browser.to_s)).to eq(browser)
    end

    [ nil, "", "chromium", "chromium:", "chromium:maybe", "Chrome:supported", "chromium:supported:extra", "Mozilla/5.0" ].each do |value|
      it "不正な値 #{value.inspect} は、例外にする" do
        expect { described_class.parse(value) }.to raise_error(ArgumentError)
      end
    end
  end
end
