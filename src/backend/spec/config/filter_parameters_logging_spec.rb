require "rails_helper"
require "support/model_support"

# ログへ出さないパラメータ・ヘッダ・Cookie（issue #7。requirements.md 6.1・7.3・10.1・28.1）。
# 要求を実際に送って、ログの出力に値が現れないことは、spec/requests/api/log_hygiene_spec.rb で確かめる。ここでは、設定の一覧を確かめる。
RSpec.describe "ログから除くパラメータ・ヘッダ（issue #7）" do
  let(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  # issue #7 が名前を挙げた 16 個（パラメータの名前として）
  named_in_issue = {
    "接続チケット" => "ticket",
    "配信キー（スネークケース）" => "stream_key",
    "bot 判定のトークン" => "recaptcha_token",
    "認可コード" => "code",
    "認可の state" => "state",
    "更新トークン" => "refresh_token",
    "アクセストークン" => "access_token",
    "ID トークン" => "id_token",
    "トークン" => "token",
    "秘密値" => "secret",
    "パスワード" => "password",
    "配信のタイトル" => "title",
    "Authorization ヘッダ" => "authorization",
    "Cookie ヘッダ" => "cookie",
    "BFF の秘密値のヘッダ" => "x-bff-secret",
    "中継の秘密値のヘッダ" => "x-relay-secret"
  }

  named_in_issue.each do |label, key|
    it "#{label}（#{key}）は伏せる" do
      filtered = filter.filter({ key => "dummy-value-must-not-appear" })

      expect(filtered[key]).to eq("[FILTERED]")
    end

    it "#{label}（#{key}）は、入れ子になっていても伏せる" do
      filtered = filter.filter({ "outer" => { key => "dummy-value-must-not-appear" } })

      expect(filtered.dig("outer", key)).to eq("[FILTERED]")
    end
  end

  # Rack の env では、ヘッダは HTTP_ で始まる大文字の名前になる（例外の報告・デバッグ画面が env を使う）
  {
    "HTTP_COOKIE" => "Cookie ヘッダ",
    "HTTP_AUTHORIZATION" => "Authorization ヘッダ",
    "HTTP_X_BFF_SECRET" => "BFF の秘密値のヘッダ",
    "HTTP_X_RELAY_SECRET" => "中継の秘密値のヘッダ"
  }.each do |env_key, label|
    it "env のキー #{env_key}（#{label}）も伏せる" do
      expect(filter.filter({ env_key => "dummy-value-must-not-appear" })[env_key]).to eq("[FILTERED]")
    end
  end

  {
    "Google の利用者識別子" => "google_sub",
    "削除したアカウントの識別子の要約値" => "sub_digest",
    "nonce" => "nonce",
    "PKCE の検証子" => "code_verifier"
  }.each do |label, key|
    it "#{label}（#{key}）は伏せる" do
      expect(filter.filter({ key => "dummy-value-must-not-appear" })[key]).to eq("[FILTERED]")
    end
  end

  # code・state は短い名前なので、完全一致だけ伏せる（reason_code など、デバッグに要るパラメータを、巻き込まない）
  %w[ reason_code error_code status_code event_type value browser_class profile statement estate ].each do |key|
    it "関係の無いパラメータ #{key} は伏せない" do
      expect(filter.filter({ key => "visible" })[key]).to eq("visible")
    end
  end

  it "OAuth の state はパラメータとして伏せるが、モデルの state 列（配信の状態など）は、伏せない（機密ではなく、デバッグに要る値）" do
    expect(ActiveRecord::Base.filter_attributes.grep(Regexp).none? { |pattern| pattern.match?("state") }).to be(true)

    broadcast = create(:broadcast)
    expect(broadcast.inspect).to include('state: "reserved"')
    expect(ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter({ "state" => "dummy" })["state"]).to eq("[FILTERED]")
  end

  it "code・state は、大文字・小文字を区別せずに伏せる" do
    filtered = filter.filter({ "Code" => "x", "STATE" => "y" })

    expect(filtered).to eq({ "Code" => "[FILTERED]", "STATE" => "[FILTERED]" })
  end
end
