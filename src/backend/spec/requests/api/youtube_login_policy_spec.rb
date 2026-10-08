require "rails_helper"
require "support/api_helpers"
require "support/youtube_connect_support"

# YouTube 接続の API のログインの方針の宣言（issue #11。#8 の提案 P1。OWASP A01・A04）。
# /api の全動作は、requires_login か allow_anonymous のどちらか 1 つを明示して宣言する（spec/requests/api/login_policy_routes_spec.rb が全体を走査する）。
# ここでは、この issue の動作ごとの方針（ログインが要る API と、匿名で受ける API を取り違えていないこと）と、動作の一覧を固定する。
#   POST /api/youtube/connect/start      ログインが要る
#   GET  /api/youtube/connect/callback   匿名で受ける（ブラウザの遷移。ログインしていなければ、unverifiable で戻す。CSRF の対象外 = state で守る）
#   POST /api/youtube/recheck            ログインが要る
RSpec.describe "YouTube 接続の API のログインの方針の宣言", type: :request do
  include ApiHelpers
  include_context "API の環境"
  include_context "YouTube 接続の環境"

  def routed_actions(controller_name)
    Rails.application.routes.routes.filter_map do |route|
      route.defaults[:action] if route.defaults[:controller] == controller_name
    end
  end

  it "動作ごとの方針（ログインが要る API と、匿名で受ける API を、取り違えていない）" do
    expect(Api::YoutubeController.login_policy_for("connect_start")).to eq(:login)
    expect(Api::YoutubeController.login_policy_for("connect_callback")).to eq(:anonymous)
    expect(Api::YoutubeController.login_policy_for("recheck")).to eq(:login)
  end

  it "疑似の同意画面（開発・テストのみ）は、匿名" do
    expect(Dev::GoogleConnectController.login_policy_for("consent")).to eq(:anonymous)
    expect(Dev::GoogleConnectController.login_policy_for("choose")).to eq(:anonymous)
  end

  it "動作（public のメソッド。Api::BaseController の動作を除く）は、この 3 つだけ。すべて経路がある" do
    actions = Api::YoutubeController.action_methods - Api::BaseController.action_methods

    expect(actions.to_a).to match_array(%w[ connect_start connect_callback recheck ])
    expect(routed_actions("api/youtube")).to match_array(%w[ connect_start connect_callback recheck ])
  end

  it "経路の HTTP メソッド: 開始・再確認は POST、戻り先は GET だけ（状態を変える要求は POST。戻り先は state で守る）" do
    verbs = Rails.application.routes.routes.select { |route| route.defaults[:controller] == "api/youtube" }.to_h { |route| [ route.defaults[:action], route.verb ] }

    expect(verbs).to eq("connect_start" => "POST", "connect_callback" => "GET", "recheck" => "POST")
  end

  it "経路: /api/youtube/connect/start・/api/youtube/connect/callback・/api/youtube/recheck（契約 3 章）" do
    paths = Rails.application.routes.routes.select { |route| route.defaults[:controller] == "api/youtube" }.map { |route| route.path.spec.to_s.sub("(.:format)", "") }

    expect(paths).to match_array(%w[ /api/youtube/connect/start /api/youtube/connect/callback /api/youtube/recheck ])
  end

  it "ログインしていない要求の扱い: 開始・再確認は 401。戻り先は 401 にしない（302 でアカウント画面へ戻す）" do
    api_post "/api/youtube/connect/start", { recaptcha_token: "dev-pass" }
    expect(response).to have_http_status(401)

    api_post "/api/youtube/recheck"
    expect(response).to have_http_status(401)

    api_get "/api/youtube/connect/callback", headers: { "Cookie" => "" }
    expect(response).to have_http_status(:found)
  end
end
