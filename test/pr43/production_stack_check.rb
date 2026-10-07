# PR #43（issue #7 アプリケーション基盤）の、本番（RAILS_ENV=production）の構成の確認。
# backend コンテナの中で、`bin/rails runner -` へ標準入力から渡して実行する（check_production.sh が、必須の環境変数を与える）。
# 本番の設定（eager_load・force_ssl・assume_ssl・config.hosts）で Rails を起動し、本番と同じミドルウェアの構成へ、
# Rack の要求を直接渡す（ソケットは開かない。DB へ接続しない。外部サービスへ接続しない）。
#
# 確かめること
#   1. ミドルウェアの順: ForwardedHeaders → ListenerPort → HostAuthorization → AssumeSSL → SSL。標準の Logger の代わりに RequestLogger
#   2. config.hosts は *.up.railway.app・*.railway.internal だけ。Host が一覧に無い要求は、403 の JSON
#   3. BFF の要求（Host は Railway の公開ドメイン。X-Forwarded-Host はフロントエンドの公開ドメインで、一覧に無い）が、拒否されない。
#      （転送ヘッダを env から取り除く ForwardedHeaders が無いと、Rails の HostAuthorization が X-Forwarded-Host を検査して、
#       本番のすべての BFF の要求が 403 になる）
#   4. 内部側の口（3101）の要求: Host が *.railway.internal なら通り、/api・/up は 404。公開側の口では、/internal が 404
#   5. ヘルスチェック（/up）は、どの Host でも 200（Railway のヘルスチェックの Host を、許可の一覧へ入れない）
#   6. HTTPS 前提（assume_ssl）: Secure の Cookie が書ける。HSTS ヘッダが付く。http の要求が、リダイレクトされない（内部通信が http のため）
#   7. Cookie の属性: 本番は Secure
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
internal_env = { "bl.listener_port" => ListenerPort.internal_port }
railway_host = "backend-production-1234.up.railway.app"

def error_of(response)
  JSON.parse(response.body).dig("error", "code")
rescue JSON::ParserError
  nil
end

names = Rails.application.middleware.map { |middleware| middleware.klass.name }

checker.check("本番の環境で起動している（eager_load・force_ssl・assume_ssl）") do
  Rails.env.production? && Rails.application.config.eager_load && Rails.application.config.force_ssl && Rails.application.config.assume_ssl
end
checker.check("ミドルウェアの先頭は ForwardedHeaders、次が ListenerPort、その次が HostAuthorization・AssumeSSL・SSL") do
  names.first(5) == %w[ ForwardedHeaders ListenerPort ActionDispatch::HostAuthorization ActionDispatch::AssumeSSL ActionDispatch::SSL ]
end
checker.check("標準の Rails::Rack::Logger の代わりに RequestLogger（IP を出さない）") do
  names.include?("RequestLogger") && !names.include?("Rails::Rack::Logger")
end
checker.check("config.hosts は *.up.railway.app と *.railway.internal だけ") do
  Rails.application.config.hosts == [ ".up.railway.app", ".railway.internal" ]
end

bff_headers = {
  "HTTP_HOST" => railway_host, "HTTP_X_BFF_SECRET" => secret, "HTTP_X_FORWARDED_HOST" => "app.example.jp",
  "HTTP_X_FORWARDED_PROTO" => "https", "HTTP_X_FORWARDED_FOR" => "203.0.113.9", "HTTP_X_REAL_IP" => "198.51.100.1"
}
checker.check("BFF の要求（X-Forwarded-Host が許可の一覧に無い）は、ホストの検査で拒否されない（存在しない経路は 404 not_found）") do
  response = mock.get("/api/no-such-endpoint", public_env.merge(bff_headers))
  response.status == 404 && error_of(response) == "not_found"
end
checker.check("BFF の秘密値が無い要求は 403 forbidden（ホストは許可されている）") do
  response = mock.get("/api/no-such-endpoint", public_env.merge("HTTP_HOST" => railway_host))
  response.status == 403 && error_of(response) == "forbidden"
end
checker.check("許可されていない Host（evil.example）は 403 forbidden の JSON") do
  response = mock.get("/api/no-such-endpoint", public_env.merge(bff_headers).merge("HTTP_HOST" => "evil.example"))
  response.status == 403 && error_of(response) == "forbidden" && !response.body.include?("evil.example")
end
checker.check("公開ドメインに似せた Host（up.railway.app.evil.example）は 403") do
  mock.get("/api/no-such-endpoint", public_env.merge(bff_headers).merge("HTTP_HOST" => "up.railway.app.evil.example")).status == 403
end
checker.check("開発の Host（localhost・backend）は、本番では 403") do
  [ "localhost:3001", "backend:3001" ].all? { |host| mock.get("/api/no-such-endpoint", public_env.merge(bff_headers).merge("HTTP_HOST" => host)).status == 403 }
end
checker.check("ヘルスチェック（/up）は、どの Host でも 200（Railway のヘルスチェック・コンテナの 127.0.0.1）") do
  [ "healthcheck.railway.app", "127.0.0.1:3001", railway_host ].all? { |host| mock.get("/up", public_env.merge("HTTP_HOST" => host)).status == 200 }
end
checker.check("内部側の口: Host が *.railway.internal なら通り、/up・/api は 404（公開側の経路は、内部側で応答しない）") do
  host = "backend.railway.internal:3101"
  mock.get("/up", internal_env.merge("HTTP_HOST" => host)).status == 404 &&
    mock.get("/api/no-such-endpoint", internal_env.merge("HTTP_HOST" => host, "HTTP_X_BFF_SECRET" => secret)).status == 404
end
checker.check("内部側の口: 許可されていない Host（IP アドレス）は 403") do
  mock.get("/api/no-such-endpoint", internal_env.merge("HTTP_HOST" => "203.0.113.5:3101")).status == 403
end
checker.check("公開側の口: /internal の経路は 404") do
  mock.post("/internal/v1/verify", public_env.merge("HTTP_HOST" => railway_host)).status == 404
end
checker.check("口の番号が分からない要求（puma.socket も、明示した口の番号も無い）は、例外（公開側と見なさない）") do
  begin
    mock.get("/up", "HTTP_HOST" => railway_host)
    false
  rescue ListenerPort::UnknownPortError
    true
  end
end
checker.check("HSTS ヘッダが付く（本番は HTTPS のみ）") do
  mock.get("/api/no-such-endpoint", public_env.merge("HTTP_HOST" => railway_host, "HTTP_X_BFF_SECRET" => secret)).headers.key?("strict-transport-security")
end
checker.check("http の要求（内部通信は http）が、https へリダイレクトされない（assume_ssl）") do
  response = mock.get("/api/no-such-endpoint", public_env.merge("HTTP_HOST" => railway_host, "HTTP_X_BFF_SECRET" => secret, "rack.url_scheme" => "http"))
  response.status == 404
end
checker.check("すべての応答（403・404）に Cache-Control: no-store") do
  responses = [
    mock.get("/api/no-such-endpoint", public_env.merge("HTTP_HOST" => railway_host)),
    mock.get("/api/no-such-endpoint", public_env.merge("HTTP_HOST" => "evil.example")),
    mock.get("/up", internal_env.merge("HTTP_HOST" => "backend.railway.internal:3101"))
  ]
  responses.all? { |response| response.headers["cache-control"] == "no-store" }
end
checker.check("本番のセッション Cookie・bl_oauth には Secure が付く（開発・テストでは付かない）") do
  SessionCookie.attributes("dummy-token-0123456789")[:secure] == true &&
    OAuthStateCookie.attributes("dummy-sealed")[:secure] == true &&
    SessionCookie.attributes("dummy-token-0123456789", environment: AppEnvironment.new("development"))[:secure] == false
end
checker.check("Cookie の値（bl_session・bl_oauth）を、フィルタ設定が伏せる（env のキー HTTP_COOKIE・HTTP_AUTHORIZATION・HTTP_X_BFF_SECRET）") do
  filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
  filtered = filter.filter({ "HTTP_COOKIE" => "x", "HTTP_AUTHORIZATION" => "x", "HTTP_X_BFF_SECRET" => "x", "HTTP_X_RELAY_SECRET" => "x" })
  filtered.values.all? { |value| value == "[FILTERED]" }
end

puts "\n#{checker.checks} 件を確認しました（失敗 #{checker.failures} 件）"
exit(checker.failures.zero? ? 0 : 1)
