require "rails_helper"

# config/locales/ja.yml は、管理画面用の文言の置き場（issue #7。日本語版のみ）。本 issue では、空に近い。
# 利用者に表示する文章は、文言カタログへ分離する（コードに直書きしない）。モックの文言を仮置きする場合も、新しい文章を創作しない。
RSpec.describe "config/locales/ja.yml" do
  let(:path) { Rails.root.join("config/locales/ja.yml") }

  it "ある" do
    expect(path).to exist
  end

  it "YAML として読め、トップレベルのキーは ja だけ" do
    data = YAML.safe_load_file(path, permitted_classes: [], aliases: false)

    expect(data).to be_a(Hash)
    expect(data.keys).to eq([ "ja" ])
  end

  it "I18n の読み込みの対象に入っている" do
    expect(I18n.load_path.map(&:to_s)).to include(path.to_s)
  end

  it "日本語版のみ（アプリケーションの config/locales に、他の言語のファイルを置かない）" do
    names = Dir[Rails.root.join("config/locales/*.yml")].map { |file| File.basename(file) }

    expect(names).to eq([ "ja.yml" ])
  end
end
