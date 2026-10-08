# PR #48（issue #8 認証）の、本番（RAILS_ENV=production）の構成の確認。
# backend コンテナの中で、`bin/rails runner -` へ標準入力から渡して実行する（check_production.sh が、ダミーの環境変数を与える）。
# 本番の設定（eager_load・force_ssl・assume_ssl・config.hosts）で Rails を起動し、本番と同じミドルウェアの構成へ、
# Rack の要求を直接渡す（ソケットは開かない。DB へ接続しない。外部サービス（Google・reCAPTCHA）へ接続しない）。
#
# 確かめること
#   1. 外部サービスの選択は :live（環境の判定）。ExternalServices.current は実物（GoogleOidcClient・RecaptchaVerifier）で、疑似ではない
#   2. 疑似の実装（FakeGoogleOidc・FakeRecaptchaVerifier）は、本番では構築できない（例外）
#   3. 疑似の Google の経路（/api/dev/）は、経路の表に無く、要求は 404 not_found（BFF の確認のあと）
#   4. 認証の経路は、ある。入力の不備（recaptcha_token なし）は 422（外部サービスを呼ぶ前に拒否する）
#   5. コールバックの失敗（error=access_denied）は、公開オリジン（X-Forwarded-Host）への 302。バックエンドの Host（Railway のドメイン）は使わない。
#      bl_oauth の失効に Secure が付く
#   6. ログアウト（セッションなし）は 401。ログインの方針は、宣言されている
#   7. assume_ssl・force_ssl が true。既定の言語は ja。WebMock は本番に読み込まれない
require "json"

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
railway_host = "backend-production-1234.up.railway.app"
frontend_host = "app.example.jp"
bff_headers = {
  "HTTP_HOST" => railway_host, "HTTP_X_BFF_SECRET" => secret, "HTTP_X_FORWARDED_HOST" => frontend_host,
  "HTTP_X_FORWARDED_PROTO" => "https", "HTTP_X_FORWARDED_FOR" => "203.0.113.9"
}

def error_of(response)
  JSON.parse(response.body).dig("error", "code")
rescue JSON::ParserError
  nil
end

def set_cookie_lines(response)
  Array(response.headers["set-cookie"] || response.headers["Set-Cookie"]).flat_map { |value| value.to_s.split("\n") }
end

checker.check("本番の環境で起動している（eager_load・force_ssl・assume_ssl。環境の判定は production）") do
  Rails.env.production? && AppEnvironment.current.production? && Rails.application.config.eager_load &&
    Rails.application.config.force_ssl && Rails.application.config.assume_ssl
end
checker.check("外部サービスの選択は :live（環境の判定）") do
  AppEnvironment.current.external_services == :live
end
checker.check("ExternalServices.current は実物（GoogleOidcClient・RecaptchaVerifier）。疑似のクラスではない") do
  gateways = ExternalServices.current
  gateways.google_oidc.instance_of?(GoogleOidcClient) && gateways.recaptcha_verifier.instance_of?(RecaptchaVerifier) &&
    !gateways.google_oidc.is_a?(FakeGoogleOidc) && !gateways.recaptcha_verifier.is_a?(FakeRecaptchaVerifier)
end
checker.check("疑似の Google は、本番では構築できない（FakeServices::NotAllowedError）") do
  FakeGoogleOidc.new(secret: "dummy-secret-key-base")
  false
rescue FakeServices::NotAllowedError => e
  e.message.include?("production")
end
checker.check("疑似の bot 判定は、本番では構築できない（FakeServices::NotAllowedError）") do
  FakeRecaptchaVerifier.new
  false
rescue FakeServices::NotAllowedError
  true
end
checker.check("実物の資格情報が欠けていれば、疑似へ倒さず、例外（欠けている名前だけを書く）") do
  ExternalServices.build(AppEnvironment.current, env: { "GOOGLE_CLIENT_ID" => "dummy" })
  false
rescue ExternalServices::MissingConfiguration => e
  e.names == %w[ GOOGLE_CLIENT_SECRET RECAPTCHA_SECRET_KEY ] && !e.message.include?("dummy")
end
checker.check("経路の表に、疑似の Google（dev/google）が無い") do
  Rails.application.routes.routes.none? { |route| route.defaults[:controller] == "dev/google" || route.path.spec.to_s.include?("/dev/") }
end
checker.check("GET /api/dev/google/authorize は 404 not_found（BFF の確認のあと、存在しない経路として。HTML を返さない）") do
  query = "response_type=code&scope=openid&redirect_uri=https%3A%2F%2F#{frontend_host}%2Fapi%2Fauth%2Fcallback&state=s&nonce=n&code_challenge=c&code_challenge_method=S256"
  response = mock.get("/api/dev/google/authorize?#{query}", public_env.merge(bff_headers))
  response.status == 404 && error_of(response) == "not_found" && !response.body.include?("<a")
end
checker.check("本番の認証の経路（login/start・callback・logout）がある") do
  actions = Rails.application.routes.routes.filter_map { |route| route.defaults[:action] if route.defaults[:controller] == "api/auth" }
  actions.sort == %w[ callback login_start logout ]
end
checker.check("POST /api/auth/login/start: recaptcha_token が無ければ 422 invalid_input（外部サービスを呼ばない）") do
  response = mock.post(
    "/api/auth/login/start", public_env.merge(bff_headers).merge("HTTP_X_BL_CLIENT" => "web", "CONTENT_TYPE" => "application/json", input: "{}")
  )
  response.status == 422 && error_of(response) == "invalid_input" && JSON.parse(response.body).dig("error", "details", "fields") == %w[ recaptcha_token ]
end
checker.check("GET /api/auth/callback?error=access_denied は 302。Location は公開オリジン（X-Forwarded-Host）。バックエンドの Host を使わない") do
  response = mock.get("/api/auth/callback?error=access_denied", public_env.merge(bff_headers))
  location = response.headers["location"] || response.headers["Location"]
  response.status == 302 && location == "https://#{frontend_host}/?login_error=oauth_failed" && !location.include?("railway")
end
checker.check("コールバックの bl_oauth の失効に Secure・HttpOnly・SameSite=Lax が付く（本番は Secure の Cookie が書ける）") do
  response = mock.get("/api/auth/callback?error=access_denied", public_env.merge(bff_headers))
  line = set_cookie_lines(response).find { |entry| entry.start_with?("bl_oauth=") }.to_s.downcase
  line.include?("secure") && line.include?("httponly") && line.include?("samesite=lax") && line.include?("expires=thu, 01 jan 1970")
end
checker.check("コールバックは、X-BFF-Secret が無ければ 403 forbidden（リダイレクトしない）") do
  response = mock.get("/api/auth/callback?error=access_denied", public_env.merge("HTTP_HOST" => railway_host, "HTTP_X_FORWARDED_HOST" => frontend_host, "HTTP_X_FORWARDED_PROTO" => "https"))
  response.status == 403 && error_of(response) == "forbidden" && response.headers["location"].nil?
end
checker.check("POST /api/auth/logout: セッションが無ければ 401 not_logged_in") do
  response = mock.post("/api/auth/logout", public_env.merge(bff_headers).merge("HTTP_X_BL_CLIENT" => "web"))
  response.status == 401 && error_of(response) == "not_logged_in"
end
checker.check("ログインの方針が、すべての /api の動作に宣言されている（requires_login か allow_anonymous）") do
  pairs = Rails.application.routes.routes.filter_map do |route|
    next unless route.path.spec.to_s.start_with?("/api")

    [ route.defaults[:controller], route.defaults[:action] ]
  end.uniq
  pairs.size >= 4 && pairs.all? do |controller, action|
    %i[ login anonymous ].include?("#{controller.camelize}Controller".constantize.login_policy_for(action))
  end
end
checker.check("Api::BaseController の既定は開いていない（宣言の無い動作は :undeclared）") do
  Api::BaseController.login_policy_for("some_new_action") == :undeclared
end
checker.check("既定の言語は ja") do
  I18n.default_locale == :ja
end
checker.check("WebMock は本番に読み込まれない（テスト用の gem）。jwt は読み込まれる") do
  !defined?(WebMock) && defined?(JWT) && true
end
checker.check("ExternalHttp の既定: 接続 3 秒・読み取り 5 秒・応答は 1 MiB まで") do
  ExternalHttp::CONNECT_TIMEOUT_SECONDS == 3 && ExternalHttp::READ_TIMEOUT_SECONDS == 5 && ExternalHttp::MAX_BODY_BYTES == 1_048_576
end
checker.check("秘密値（コンテナの環境変数）が、これらの応答に現れない") do
  responses = [
    mock.get("/api/auth/callback?error=access_denied", public_env.merge(bff_headers)),
    mock.get("/api/dev/google/authorize", public_env.merge(bff_headers)),
    mock.post("/api/auth/login/start", public_env.merge(bff_headers).merge("HTTP_X_BL_CLIENT" => "web", "CONTENT_TYPE" => "application/json", input: "{}"))
  ]
  secrets = %w[ BFF_SHARED_SECRET GOOGLE_CLIENT_SECRET RECAPTCHA_SECRET_KEY SESSION_SECRET ].map { |name| ENV.fetch(name) }
  responses.none? { |response| secrets.any? { |value| response.body.include?(value) || response.headers.values.join.include?(value) } }
end

puts
puts "#{checker.checks} 件を確認しました（失敗 #{checker.failures} 件）"
exit(checker.failures.zero? ? 0 : 1)
