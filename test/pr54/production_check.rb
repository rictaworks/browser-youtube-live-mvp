# PR 54（issue #11 YouTube 接続）の、本番（RAILS_ENV=production）の構成の確認。
# backend コンテナの中で、`bin/rails runner -` へ標準入力から渡して実行する（check_production.sh が、ダミーの環境変数を与える）。
# 本番の設定（eager_load・force_ssl・assume_ssl・config.hosts）で Rails を起動し、本番と同じミドルウェアの構成へ、Rack の要求を直接渡す
# （ソケットは開かない。DB へ接続しない。外部サービス（Google・YouTube）へ接続しない）。
#
# 確かめること
#   1. YouTube 接続の手続き（YouTubeConnectService.current）は、実物（GoogleOidcClient・YouTubeGateway・TokenVault）で組み立つ。疑似ではない
#   2. 疑似の Google・疑似の YouTube の窓口・疑似のトークンエンドポイントは、本番では構築できない（FakeServices::NotAllowedError）
#   3. 実物の認可 URL: https://accounts.google.com。client_id つき。スコープは youtube の 1 種・offline・consent・PKCE。include_granted_scopes・nonce は無い
#   4. 疑似の同意画面の経路（/api/dev/）は、経路の表に無く、要求は 404 not_found。本番の YouTube 接続の経路（connect/start・connect/callback・recheck）は、ある
#   5. connect/start・recheck は、ログインが要る（セッションなしは 401。DB を引かずに拒否する）。ログインの方針は、動作ごとに宣言されている
#   6. 設定の YouTube のスコープは、1 種（youtube）。TOKEN_ENCRYPTION_KEY の形式の検査は、起動時に済んでいる
require "json"
require "uri"

class Checker
  attr_reader :checks, :failures

  def initialize
    @checks = 0
    @failures = 0
  end

  def check(label)
    @checks += 1
    ok = yield
    puts(ok ? "ok   #{label}" : "FAIL #{label}")
    @failures += 1 unless ok
  rescue StandardError => e
    puts "FAIL #{label}（例外: #{e.class}）"
    @failures += 1
  end
end

checker = Checker.new
mock = Rack::MockRequest.new(Rails.application)
secret = ENV.fetch("BFF_SHARED_SECRET")
public_env = { "bl.listener_port" => ListenerPort.public_port }
bff_headers = {
  "HTTP_HOST" => "backend-production-1234.up.railway.app", "HTTP_X_BFF_SECRET" => secret, "HTTP_X_FORWARDED_HOST" => "app.example.jp",
  "HTTP_X_FORWARDED_PROTO" => "https", "HTTP_X_FORWARDED_FOR" => "203.0.113.9"
}

def error_of(response)
  JSON.parse(response.body).dig("error", "code")
rescue JSON::ParserError
  nil
end

checker.check("本番の環境で起動している（環境の判定は production。外部サービスの選択は :live）") do
  Rails.env.production? && AppEnvironment.current.production? && AppEnvironment.current.external_services == :live
end
checker.check("YouTubeConnectService.current は、実物で組み立つ（Google は GoogleOidcClient・YouTube の窓口は YouTubeGateway・TokenVault）。疑似のクラスではない") do
  service = YouTubeConnectService.current
  oidc = service.instance_variable_get(:@oidc)
  gateway = service.instance_variable_get(:@youtube)
  vault = service.instance_variable_get(:@vault)
  oidc.instance_of?(GoogleOidcClient) && gateway.instance_of?(YouTubeGateway) && vault.instance_of?(TokenVault) &&
    !oidc.is_a?(FakeGoogleOidc) && !gateway.is_a?(FakeYouTubeGateway)
end
checker.check("疑似の Google は、本番では構築できない（FakeServices::NotAllowedError）") do
  FakeGoogleOidc.new(secret: "dummy-secret-key-base")
  false
rescue FakeServices::NotAllowedError => e
  e.message.include?("production")
end
checker.check("疑似の YouTube の窓口・疑似のトークンエンドポイントは、本番では構築できない（FakeServices::NotAllowedError）") do
  raised = []
  begin
    FakeYouTubeGateway.new(token_vault: nil, api: nil, api_base: "https://www.googleapis.com/youtube/v3", stream_title: "dummy")
  rescue FakeServices::NotAllowedError
    raised << :gateway
  end
  begin
    FakeGoogleTokenClient.new
  rescue FakeServices::NotAllowedError
    raised << :token_client
  end
  raised == %i[ gateway token_client ]
end
checker.check("実物の認可 URL: https://accounts.google.com。client_id つき・スコープは youtube の 1 種・offline・consent・S256・login_hint。include_granted_scopes・nonce は無い") do
  oidc = YouTubeConnectService.current.instance_variable_get(:@oidc)
  url = oidc.youtube_authorization_url(state: "dummy-state", code_challenge: "dummy-challenge", redirect_uri: "https://app.example.jp/api/youtube/connect/callback", login_hint: "dummy-sub")
  uri = URI.parse(url)
  query = Rack::Utils.parse_query(uri.query)
  "#{uri.scheme}://#{uri.host}#{uri.path}" == "https://accounts.google.com/o/oauth2/v2/auth" && query["client_id"] == ENV.fetch("GOOGLE_CLIENT_ID") &&
    query["scope"] == "https://www.googleapis.com/auth/youtube" && query["access_type"] == "offline" && query["prompt"] == "consent" &&
    query["code_challenge_method"] == "S256" && query["login_hint"] == "dummy-sub" && !query.key?("include_granted_scopes") && !query.key?("nonce")
end
checker.check("設定の YouTube のスコープは 1 種（youtube）。ログインの openid を含まない") do
  scope = ExternalServices.config.fetch(:google_oidc).fetch(:youtube_scope)
  scope == "https://www.googleapis.com/auth/youtube" && scope.split.size == 1
end
checker.check("疑似の同意画面の経路（/api/dev/）は、経路の表に無い") do
  Rails.application.routes.routes.none? { |route| route.path.spec.to_s.include?("/dev/") } &&
    Rails.application.routes.routes.none? { |route| route.defaults[:controller].to_s.start_with?("dev/") }
end
checker.check("疑似の同意画面への要求は 404 not_found（BFF の確認のあと）。選択（choose）も 404") do
  consent = mock.get("/api/dev/google/connect?response_type=code", bff_headers.merge(public_env))
  choose = mock.get("/api/dev/google/connect/choose?scenario=allow", bff_headers.merge(public_env))
  consent.status == 404 && error_of(consent) == "not_found" && choose.status == 404 && error_of(choose) == "not_found" && !consent.headers.key?("Location")
end
checker.check("本番の YouTube 接続の経路は、ある（POST connect/start・GET connect/callback・POST recheck）") do
  routes = Rails.application.routes.routes.select { |route| route.defaults[:controller] == "api/youtube" }.map { |route| [ route.verb, route.defaults[:action] ] }
  routes.sort == [ %w[ GET connect_callback ], %w[ POST connect_start ], %w[ POST recheck ] ]
end
checker.check("connect/start・recheck はログインが要る（セッションなしは 401。DB を引かずに拒否する）") do
  headers = bff_headers.merge(public_env).merge("HTTP_X_BL_CLIENT" => "web", "CONTENT_TYPE" => "application/json", "HTTP_ORIGIN" => "https://app.example.jp")
  start = mock.post("/api/youtube/connect/start", headers.merge(input: JSON.generate("recaptcha_token" => "dummy")))
  recheck = mock.post("/api/youtube/recheck", headers)
  start.status == 401 && error_of(start) == "not_logged_in" && recheck.status == 401 && error_of(recheck) == "not_logged_in"
end
checker.check("ログインの方針は、動作ごとに宣言されている（開始・再確認は login、戻り先は anonymous）") do
  Api::YoutubeController.login_policy_for("connect_start") == :login && Api::YoutubeController.login_policy_for("recheck") == :login &&
    Api::YoutubeController.login_policy_for("connect_callback") == :anonymous
end
checker.check("TOKEN_ENCRYPTION_KEY の形式は、起動時に検査済み（TokenVault.parse_key が通る）") do
  TokenVault.parse_key(ENV.fetch("TOKEN_ENCRYPTION_KEY")).bytesize == 32
end
checker.check("チャンネル名のキャッシュの寿命は、最長 10 分（契約の保持期間）。プロセスで共有する") do
  ChannelNameCache::MAX_TTL_SECONDS == 600 && ChannelNameCache.shared.ttl_seconds == 600 && ChannelNameCache.shared.equal?(ChannelNameCache.shared)
end

puts
puts "確認 #{checker.checks} 項目、失敗 #{checker.failures} 項目"
exit(checker.failures.zero? ? 0 : 1)
