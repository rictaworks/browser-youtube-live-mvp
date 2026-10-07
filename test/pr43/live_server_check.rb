# PR #43（issue #7 アプリケーション基盤）の、実サーバー（開発の backend コンテナの Puma）への確認。
# backend コンテナの中で実行する（run_all.sh が、標準入力から `ruby -` へ渡す）。Rails は起動しない（HTTP の要求を送るだけ）。
#
# 確かめること（受け入れ条件のうち、実際の口・実際のミドルウェアでしか確かめられないもの）
#   1. 口の分離: 公開側の口（3001）は /up・/api に応答し、/internal は 404。内部側の口（3101）は /up・/api・/admin を応答しない（404）
#   2. puma.socket から、要求を受けた口の番号を得ていること（口ごとに、応答が変わる）
#   3. BFF の確認（X-BFF-Secret）・CSRF の評価の順（403 forbidden → 403 csrf_invalid → 401 not_logged_in → 404）
#   4. エラーの形（契約の JSON・Cache-Control: no-store・Set-Cookie なし）。HTML のエラーページが出ない
#   5. ホストの許可（開発: localhost・backend）。Host が許可されていなければ 403 の JSON。/up は対象外
#   6. BFF が付ける X-Forwarded-Host（フロントエンドの公開ドメイン）が、許可の一覧に無くても、拒否されない
#   7. ログ（log/development.log）に、利用者の IP（X-Forwarded-For・Client-IP）・認可コード・state・チケット・Authorization・Cookie の値が現れない
#
# 安全:
#   - BFF の秘密値は、コンテナの環境変数 BFF_SHARED_SECRET から読む。出力しない（値も、長さも）
#   - 対象は、開発サーバー（コンテナの中の localhost・backend）。本番へ接続しない
#   - ファイルを書かない・消さない。ログは、読み取りだけ
require "json"
require "net/http"
require "securerandom"

PUBLIC_HOST = "localhost".freeze
PUBLIC_PORT = 3001
INTERNAL_HOST = "backend".freeze
INTERNAL_PORT = 3101
LOG_PATH = "/app/log/development.log".freeze

SECRET = ENV["BFF_SHARED_SECRET"].to_s
if SECRET.empty?
  puts "FAIL コンテナの環境変数 BFF_SHARED_SECRET がありません（scripts/setup_dev_env.sh を実行してください）"
  exit 2
end

Response = Struct.new(:status, :headers, :body, keyword_init: true)

# listener は :public または :internal。headers の値が nil のヘッダは付けない。:bff を値にすると、BFF の秘密値（コンテナの環境変数）を付ける
def request(listener, method, path, headers: {}, body: nil)
  host, port = listener == :public ? [ PUBLIC_HOST, PUBLIC_PORT ] : [ INTERNAL_HOST, INTERNAL_PORT ]
  klass = Net::HTTP.const_get(method.to_s.capitalize)
  http_request = klass.new(path)
  headers.each do |name, value|
    next if value.nil?

    http_request[name] = value == :bff ? SECRET : value
  end
  http_request.body = body unless body.nil?
  response = Net::HTTP.start(host, port, read_timeout: 20, open_timeout: 10) { |http| http.request(http_request) }
  Response.new(status: response.code.to_i, headers: response.to_hash.transform_values(&:first), body: response.body.to_s)
end

# 確認の記録（グローバル変数を使わず、オブジェクトに持つ）
class Checker
  attr_reader :checks, :failures

  def initialize
    @checks = 0
    @failures = 0
  end

  # ブロックが真なら ok。偽・例外なら FAIL
  def check(label)
    @checks += 1
    ok = yield
    puts(ok ? "ok   #{label}" : "FAIL #{label}")
    @failures += 1 unless ok
  rescue StandardError => e
    puts "FAIL #{label}（例外: #{e.class}）"
    @failures += 1
  end

  def section(title)
    puts "\n-- #{title}"
  end
end

def json(response)
  JSON.parse(response.body)
rescue JSON::ParserError
  nil
end

def error_code(response)
  json(response)&.dig("error", "code")
end

# 契約のエラーの形（{"error":{"code":…,"details":{…}}}）・JSON・no-store・Set-Cookie なし
def contract_error?(response, status, code)
  response.status == status &&
    json(response) == { "error" => { "code" => code, "details" => {} } } &&
    response.headers["content-type"] == "application/json; charset=utf-8" &&
    response.headers["cache-control"] == "no-store" &&
    !response.headers.key?("set-cookie") &&
    !response.body.include?("<")
end

checker = Checker.new
log_offset = File.exist?(LOG_PATH) ? File.size(LOG_PATH) : 0
probe = SecureRandom.hex(6)
probe_ip = "203.0.113.#{SecureRandom.random_number(200) + 20}"
probe_client_ip = "203.0.113.#{SecureRandom.random_number(200) + 20}"
probe_values = {
  "認可コード" => "dummy-code-#{probe}",
  "state" => "dummy-state-#{probe}",
  "チケット" => "dummy-ticket-#{probe}",
  "配信キー" => "dummy-stream-key-#{probe}",
  "Authorization" => "dummy-authorization-#{probe}",
  "Cookie" => "dummy-cookie-#{probe}",
  "BFF の秘密値（不一致）" => "dummy-wrong-bff-#{probe}",
  "X-Forwarded-For の IP" => probe_ip,
  "Client-IP の IP" => probe_client_ip
}

checker.section "1. 口の分離（puma.socket から、要求を受けた口を得る）"
checker.check("公開側の口: GET /up は 200") { request(:public, :get, "/up").status == 200 }
checker.check("内部側の口: GET /up は 404（契約の JSON）") { contract_error?(request(:internal, :get, "/up"), 404, "not_found") }
checker.check("公開側の口: POST /internal/v1/verify は 404（内部通信の経路は、公開側で応答しない）") do
  contract_error?(request(:public, :post, "/internal/v1/verify", headers: { "X-Relay-Secret" => "dummy" }, body: "{}"), 404, "not_found")
end
checker.check("公開側の口: /internal/ 配下のどの経路も 404") do
  %w[ /internal /internal/ /internal/v1/broadcasts/00000000-0000-0000-0000-000000000000/heartbeat ].all? do |path|
    request(:public, :get, path).status == 404
  end
end
checker.check("内部側の口: /api/no-such-endpoint は 404（BFF の秘密値があっても、公開側の経路に応答しない）") do
  contract_error?(request(:internal, :get, "/api/no-such-endpoint", headers: { "X-BFF-Secret" => :bff }), 404, "not_found")
end
checker.check("内部側の口: POST /api/usage-events は 404") do
  response = request(:internal, :post, "/api/usage-events", headers: { "X-BFF-Secret" => :bff, "X-BL-Client" => "web", "Content-Type" => "application/json" }, body: "{}")
  contract_error?(response, 404, "not_found")
end
checker.check("公開側・内部側の口: /admin は 404（管理画面の経路は、まだ無い。公開側の制約の中へ足す）") do
  request(:public, :get, "/admin").status == 404 && request(:internal, :get, "/admin").status == 404
end
checker.check("内部側の口へは、BFF の確認を通らなくても、同じ 404（経路の存在を明かさない）") do
  with_secret = request(:internal, :get, "/api/usage-events", headers: { "X-BFF-Secret" => :bff })
  without = request(:internal, :get, "/api/usage-events")
  [ with_secret.status, with_secret.body ] == [ without.status, without.body ]
end

checker.section "2. BFF の確認と、評価の順（BFF → X-BL-Client → ログイン → 経路）"
checker.check("X-BFF-Secret が無い: GET /api/usage-events は 403 forbidden（契約の JSON。ブラウザで開いたときの応答）") do
  contract_error?(request(:public, :get, "/api/usage-events"), 403, "forbidden")
end
checker.check("X-BFF-Secret が不一致: 403 forbidden（欠落と同じ本文。手がかりを返さない）") do
  missing = request(:public, :get, "/api/usage-events")
  wrong = request(:public, :get, "/api/usage-events", headers: { "X-BFF-Secret" => "dummy-wrong-bff-#{probe}" })
  contract_error?(wrong, 403, "forbidden") && wrong.body == missing.body
end
checker.check("X-BFF-Secret が空: 403 forbidden") do
  contract_error?(request(:public, :get, "/api/usage-events", headers: { "X-BFF-Secret" => "" }), 403, "forbidden")
end
checker.check("確認を通った GET: 存在しない /api の経路は 404 not_found（JSON）") do
  contract_error?(request(:public, :get, "/api/no-such-endpoint", headers: { "X-BFF-Secret" => :bff }), 404, "not_found")
end
checker.check("確認を通った GET /api/usage-events: 404（経路は POST だけ）") do
  contract_error?(request(:public, :get, "/api/usage-events", headers: { "X-BFF-Secret" => :bff }), 404, "not_found")
end
checker.check("POST で X-BL-Client が無い: 403 csrf_invalid（BFF の確認のあと）") do
  contract_error?(request(:public, :post, "/api/usage-events", headers: { "X-BFF-Secret" => :bff, "Content-Type" => "application/json" }, body: "{}"), 403, "csrf_invalid")
end
checker.check("POST で X-BL-Client: web・ログインなし: 401 not_logged_in") do
  response = request(:public, :post, "/api/usage-events", headers: { "X-BFF-Secret" => :bff, "X-BL-Client" => "web", "Content-Type" => "application/json" }, body: "{}")
  contract_error?(response, 401, "not_logged_in")
end
checker.check("POST で Origin が公開オリジンと違う: 403 csrf_invalid（X-Forwarded-Host から公開オリジンを作る）") do
  headers = {
    "X-BFF-Secret" => :bff, "X-BL-Client" => "web", "Content-Type" => "application/json",
    "X-Forwarded-Host" => "app.example.test", "X-Forwarded-Proto" => "https", "Origin" => "https://evil.example"
  }
  contract_error?(request(:public, :post, "/api/usage-events", headers: headers, body: "{}"), 403, "csrf_invalid")
end
checker.check("POST で Origin が公開オリジンと一致: 次の検査（ログイン）へ進む。401 not_logged_in") do
  headers = {
    "X-BFF-Secret" => :bff, "X-BL-Client" => "web", "Content-Type" => "application/json",
    "X-Forwarded-Host" => "app.example.test", "X-Forwarded-Proto" => "https", "Origin" => "https://app.example.test"
  }
  contract_error?(request(:public, :post, "/api/usage-events", headers: headers, body: "{}"), 401, "not_logged_in")
end
checker.check("壊れた JSON の本文でも、確認が先（確認なしは 403 forbidden）。HTML のエラーページにならない") do
  response = request(:public, :post, "/api/usage-events", headers: { "Content-Type" => "application/json" }, body: "{broken")
  contract_error?(response, 403, "forbidden")
end
checker.check("壊れた JSON の本文: ログインしていなければ 401（本文の不備より、認可が先）") do
  response = request(:public, :post, "/api/usage-events", headers: { "X-BFF-Secret" => :bff, "X-BL-Client" => "web", "Content-Type" => "application/json" }, body: "{broken")
  contract_error?(response, 401, "not_logged_in")
end
checker.check("DELETE・PUT・PATCH も、状態を変える要求として、X-BL-Client を要する（403 csrf_invalid）") do
  %i[ delete put patch ].all? do |verb|
    contract_error?(request(:public, verb, "/api/account", headers: { "X-BFF-Secret" => :bff }), 403, "csrf_invalid")
  end
end

checker.section "3. ホストの許可（開発: localhost・backend）と、BFF が付ける X-Forwarded-Host"
checker.check("許可されていない Host（evil.example）: 403 forbidden の JSON（HTML のデバッグ画面にならない）") do
  contract_error?(request(:public, :get, "/api/usage-events", headers: { "Host" => "evil.example", "X-BFF-Secret" => :bff }), 403, "forbidden")
end
checker.check("許可されていない Host（127.0.0.1）: 403（開発は localhost・backend だけ）") do
  request(:public, :get, "/api/usage-events", headers: { "Host" => "127.0.0.1:3001", "X-BFF-Secret" => :bff }).status == 403
end
checker.check("ヘルスチェック（/up）は、どの Host でも 200（コンテナの 127.0.0.1・Railway のヘルスチェック）") do
  [ "evil.example", "127.0.0.1:3001", "healthcheck.railway.app" ].all? { |host| request(:public, :get, "/up", headers: { "Host" => host }).status == 200 }
end
checker.check("内部側の口: Host が backend:3101 なら、経路が無いので 404。許可されていない Host なら、ホストの検査で 403（/up 以外）") do
  allowed = request(:internal, :get, "/api/no-such-endpoint", headers: { "Host" => "backend:3101" })
  blocked = request(:internal, :get, "/api/no-such-endpoint", headers: { "Host" => "203.0.113.5:3101" })
  allowed.status == 404 && blocked.status == 403
end
checker.check("BFF が付ける X-Forwarded-Host（フロントエンドの公開ドメイン。許可の一覧に無い）があっても、拒否されない") do
  headers = { "X-BFF-Secret" => :bff, "X-Forwarded-Host" => "app.example.test", "X-Forwarded-Proto" => "https", "X-Forwarded-For" => probe_ip }
  contract_error?(request(:public, :get, "/api/no-such-endpoint", headers: headers), 404, "not_found")
end

checker.section "4. 応答の共通の規約"
checker.check("すべての応答に Cache-Control: no-store（200 の /up を除く、API・404・403・401）") do
  responses = [
    request(:public, :get, "/api/usage-events"),
    request(:public, :get, "/api/no-such-endpoint", headers: { "X-BFF-Secret" => :bff }),
    request(:internal, :get, "/up"),
    request(:public, :get, "/api/usage-events", headers: { "Host" => "evil.example" })
  ]
  responses.all? { |response| response.headers["cache-control"] == "no-store" }
end
checker.check("Rails 標準のセッションの Cookie（Set-Cookie）を出さない") do
  responses = [
    request(:public, :get, "/api/usage-events"),
    request(:public, :post, "/api/usage-events", headers: { "X-BFF-Secret" => :bff, "X-BL-Client" => "web", "Content-Type" => "application/json" }, body: "{}")
  ]
  responses.none? { |response| response.headers.key?("set-cookie") }
end

checker.section "5. ログ（log/development.log）に、IP・機密が現れない"
# 機密・IP を含む要求を送る（BFF の確認を通る要求と、通らない要求の両方）
request(:public, :get, "/api/no-such-endpoint?code=#{probe_values['認可コード']}&state=#{probe_values['state']}&ticket=#{probe_values['チケット']}&stream_key=#{probe_values['配信キー']}",
        headers: { "X-BFF-Secret" => :bff, "X-Forwarded-For" => probe_ip, "Client-IP" => probe_client_ip, "Authorization" => "Bearer #{probe_values['Authorization']}", "Cookie" => "bl_session=#{probe_values['Cookie']}" })
request(:public, :get, "/api/no-such-endpoint?code=#{probe_values['認可コード']}",
        headers: { "X-BFF-Secret" => probe_values["BFF の秘密値（不一致）"], "X-Forwarded-For" => probe_ip, "Client-IP" => probe_client_ip, "Authorization" => "Bearer #{probe_values['Authorization']}", "Cookie" => "bl_session=#{probe_values['Cookie']}" })
request(:public, :post, "/api/usage-events",
        headers: { "X-BFF-Secret" => :bff, "X-BL-Client" => "web", "Content-Type" => "application/json", "X-Forwarded-For" => probe_ip },
        body: JSON.generate({ event_type: "watch_url_copied", recaptcha_token: "dummy-recaptcha-#{probe}", title: "dummy-title-#{probe}" }))
request(:internal, :get, "/up", headers: { "X-Forwarded-For" => probe_ip })
sleep 1

new_log = File.exist?(LOG_PATH) ? File.open(LOG_PATH, "rb") { |file| file.seek(log_offset); file.read.to_s.force_encoding("UTF-8").scrub } : ""
checker.check("ログが書かれている（要求の開始の行がある。検査が、空のログで通っていない）") { new_log.include?('Started GET "/api/no-such-endpoint?code=[FILTERED]') }
checker.check("要求の開始の行に IP を出さない（Started GET \"...\" at ...。\"for <IP>\" の形でない）") do
  started = new_log.lines.grep(/\AStarted /)
  !started.empty? && started.none? { |line| line.include?(" for ") }
end
probe_values.each do |label, value|
  checker.check("ログに #{label} の値が現れない") { !new_log.include?(value) }
end
checker.check("ログに、伏せ字（[FILTERED]）が出ている（クエリのパラメータは、伏せて記録される）") { new_log.include?("[FILTERED]") }
checker.check("ログに、拒否の記録（符号・理由・リクエスト ID）が出ている（原因をたどれる）") do
  new_log.match?(/\[api\] rejected code=forbidden status=403 reason=bff_secret_rejected request_id=\S+/)
end

puts "\n#{checker.checks} 件を確認しました（失敗 #{checker.failures} 件）"
exit(checker.failures.zero? ? 0 : 1)
