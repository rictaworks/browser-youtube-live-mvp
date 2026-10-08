require "rails_helper"
require "support/api_helpers"

# 疑似の Google の経路（/api/dev/google/authorize）は、疑似を使う環境（開発・テスト）にだけある。本番では、経路を描かない（issue #8）。
# 本番の要求は、存在しない /api の経路として 404 not_found になる（BFF も、本番では /api/dev/ を転送しない。src/frontend の中継）。
# 環境の判定（AppEnvironment#external_services）は、外部サービスの実装の選択（ExternalServices）と同じ。環境変数では決めない。
RSpec.describe "疑似の Google の経路（環境の判定）", type: :request do
  include ApiHelpers
  include_context "API の環境"

  # 経路の表を、環境の判定を差し替えて引き直す。終わったら、本来の環境で引き直す
  after do
    allow(AppEnvironment).to receive(:current).and_call_original
    Rails.application.reload_routes!
  end

  def redraw_for(name)
    allow(AppEnvironment).to receive(:current).and_return(AppEnvironment.new(name))
    Rails.application.reload_routes!
  end

  def dev_routes
    Rails.application.routes.routes.select { |route| route.defaults[:controller] == "dev/google" }
  end

  def request_dev_authorize
    query = URI.encode_www_form(
      response_type: "code", scope: "openid", redirect_uri: "#{ApiHelpers::PUBLIC_ORIGIN}/api/auth/callback",
      state: "dummy-state", nonce: "dummy-nonce", code_challenge: "dummy-challenge", code_challenge_method: "S256"
    )
    api_get "/api/dev/google/authorize?#{query}", headers: { "Cookie" => "" }
  end

  it "このテストの環境（test）には、経路がある（GET /api/dev/google/authorize → Dev::GoogleController#authorize）" do
    expect(AppEnvironment.current.name).to eq(:test)
    expect(dev_routes.map { |route| [ route.verb, route.path.spec.to_s.sub("(.:format)", ""), route.defaults[:action] ] }).to eq([ [ "GET", "/api/dev/google/authorize", "authorize" ] ])
  end

  %w[ development test ].each do |name|
    it "#{name}: 経路があり、画面が出る（200）" do
      redraw_for(name)

      request_dev_authorize

      expect(dev_routes.size).to eq(1)
      expect(response).to have_http_status(:ok)
    end
  end

  it "production: 経路が無い。経路の表に、疑似の Google が一つも無い" do
    redraw_for("production")

    expect(dev_routes).to be_empty
    expect(Rails.application.routes.routes.map { |route| route.path.spec.to_s }).to all(satisfy { |path| !path.include?("/dev/") })
  end

  it "production: 要求は 404 not_found（存在しない /api の経路。画面を出さない・本番の転送は BFF も止める）" do
    redraw_for("production")

    request_dev_authorize

    expect(response).to have_http_status(404)
    expect(json_body).to eq({ "error" => { "code" => "not_found", "details" => {} } })
    expect(response.body).not_to include("<a")
  end

  it "production: 本番の認証の経路（login/start・callback・logout）は、ある" do
    redraw_for("production")

    controllers = Rails.application.routes.routes.filter_map { |route| [ route.defaults[:controller], route.defaults[:action] ] if route.defaults[:controller] == "api/auth" }

    expect(controllers).to match_array([ %w[ api/auth login_start ], %w[ api/auth callback ], %w[ api/auth logout ] ])
  end

  it "疑似の認可 URL が指す経路（設定の authorize_path）は、経路の表にある" do
    redraw_for("test")

    expect(Rails.application.routes.url_helpers.api_dev_google_authorize_path).to eq(ExternalServices.config.fetch(:fake_google).fetch(:authorize_path))
  end

  it "本番の外部サービスの選択は :live（常に実物）。疑似の経路を描く条件と同じ判定" do
    expect(AppEnvironment.new("production").external_services).to eq(:live)
    expect(AppEnvironment.new("development").external_services).to eq(:fake)
    expect(AppEnvironment.new("test").external_services).to eq(:fake)
  end

  it "疑似の経路を描く条件は、環境変数ではない（config/routes.rb に、ENV の参照が無い）" do
    source = Rails.root.join("config/routes.rb").read

    expect(source).not_to match(/\bENV\b/)
    expect(source).to include("AppEnvironment.current.external_services")
  end
end
