require "rails_helper"

# 言語は日本語のみ（issue #8。CLAUDE.md「日本語版のみ開発する」）。config/initializers/locale.rb が、既定の言語を ja にする。
RSpec.describe "言語の設定" do
  it "既定の言語は ja（画面の ERB の t ヘルパーが、config/locales/ja.yml を引く）" do
    expect(I18n.default_locale).to eq(:ja)
    expect(I18n.locale).to eq(:ja)
  end

  it "疑似の Google の画面の文言が、ja.yml にある（仮置き。固有名詞だけ）" do
    expect(I18n.t("dev.google.authorize.title")).to eq("Google")
  end

  it "画面の ERB の文言は、ja.yml の外に日本語の直書きが無い" do
    template = Rails.root.join("app/views/dev/google/authorize.html.erb").read(encoding: "UTF-8")
    japanese = /[\p{Hiragana}\p{Katakana}\p{Han}　-〿＀-￯]/

    expect(template).not_to match(japanese)
  end
end
