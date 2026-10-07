require "rails_helper"

# 配信キー・トークン・配信のタイトルを、ログへ出さない（CLAUDE.md の不変条件）
RSpec.describe "ログから除くパラメータ" do
  let(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  {
    "配信のタイトル" => :title,
    "接続チケット" => :ticket,
    "更新トークン" => :refresh_token,
    "アクセストークン" => :access_token,
    "配信キー（スネークケース）" => :stream_key,
    "配信キー（キャメルケース）" => :streamKey,
    "配信キー（YouTube の streamName）" => :streamName,
    "共有の秘密値" => :relay_shared_secret,
    "パスワード" => :password
  }.each do |label, key|
    it "#{label}（#{key}）は伏せる" do
      filtered = filter.filter({ key => "dummy-value-must-not-appear" })

      expect(filtered[key]).to eq("[FILTERED]")
    end
  end

  it "入れ子になったパラメータも伏せる" do
    filtered = filter.filter({ "broadcast" => { "title" => "dummy-title" } })

    expect(filtered.dig("broadcast", "title")).to eq("[FILTERED]")
  end

  it "関係の無いパラメータは伏せない" do
    filtered = filter.filter({ "profile" => "standard" })

    expect(filtered["profile"]).to eq("standard")
  end
end
