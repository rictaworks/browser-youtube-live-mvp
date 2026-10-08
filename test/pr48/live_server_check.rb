# PR #48（issue #8 認証）の、実サーバー（開発の backend コンテナの Puma）への確認。
# backend コンテナの中で、`bin/rails runner -` へ標準入力から渡して実行する（run_all.sh が呼ぶ）。
# Rails は、CSRF トークンの導出（アプリケーションの CsrfToken）にだけ使う。要求は、実際の HTTP で Puma（localhost:3001）へ送る。
# フロントエンドの BFF が付けるヘッダ（X-BFF-Secret・X-Forwarded-*）を、このスクリプトが付ける（開発の公開オリジンは http://localhost:3000）。
#
# 確かめること（疑似の Google を使う、開発の環境の判定で）
#   1. login/start: BFF の確認・入力の検査・bot 判定（dev-fail は 403）・認可 URL（疑似の認可画面。スコープは openid のみ・S256）・bl_oauth の属性
#   2. 疑似の認可画面: 固定の 3 アカウントのリンク（コールバックの URL へ戻る）
#   3. コールバック: state の不一致は 302 oauth_failed、正しければ 302 /studio と bl_session（HttpOnly・SameSite=Lax・有効期限の属性なし）。
#      リダイレクト先は、公開オリジン（http://localhost:3000）
#   4. 発行されたセッションで、ログインが必要な API が使える（CSRF トークンつき）。セッション固定化の防止（再ログインで識別子が変わる）
#   5. ログアウト: 204 と bl_session の失効。2 回目は 401。古い識別子は使えない
#   6. 頻度制限: 同じ IP の 31 回目は 429（retry_at は JST の ISO 8601）。bot 判定に失敗する要求で数える（DB に書かない）
#   7. ログ（log/development.log）に、state・nonce・認可コード・セッションの識別子・bl_oauth の値・利用者の IP・sub が現れない
#
# 安全:
#   - BFF の秘密値は、コンテナの環境変数 BFF_SHARED_SECRET から読む。出力しない
#   - 対象は、開発サーバー（コンテナの中の localhost）。本番へ接続しない。実際の Google・reCAPTCHA は呼ばない（疑似）
#   - 開発 DB に作られるもの: アカウント dev-user-1（疑似のアカウント。ログインの操作で、必ずできる）、測定イベント（login_started・login_completed）、
#     ログアウトで消えるセッション。ほかは書かない
require "cgi"
require "json"
require "net/http"
require "securerandom"
require "uri"

PUBLIC_HOST = "localhost".freeze
PUBLIC_PORT = 3001
FRONTEND_ORIGIN = "http://localhost:3000".freeze
LOG_PATH = "/app/log/development.log".freeze
SECRET = ENV["BFF_SHARED_SECRET"].to_s

if SECRET.empty?
  puts "FAIL コンテナの環境変数 BFF_SHARED_SECRET がありません（scripts/setup_dev_env.sh を実行してください）"
  exit 2
end

Response = Struct.new(:status, :headers, :cookies, :body, keyword_init: true)

# BFF が付けるヘッダ。ip は、この実行専用の IP（頻度制限の計数を、ほかの利用者と混ぜない）
def bff_headers(ip)
  { "X-BFF-Secret" => SECRET, "X-Forwarded-For" => ip, "X-Forwarded-Host" => "localhost:3000", "X-Forwarded-Proto" => "http" }
end

def call(method, path, headers: {}, body: nil, cookie: nil)
  klass = Net::HTTP.const_get(method.to_s.capitalize)
  request = klass.new(path)
  headers.each { |name, value| request[name] = value unless value.nil? }
  request["Cookie"] = cookie unless cookie.nil?
  request.body = body unless body.nil?
  response = Net::HTTP.start(PUBLIC_HOST, PUBLIC_PORT, read_timeout: 20, open_timeout: 10) { |http| http.request(request) }
  Response.new(
    status: response.code.to_i, headers: response.to_hash.transform_values(&:first),
    cookies: Array(response.get_fields("set-cookie")), body: response.body.to_s
  )
end

def json_of(response)
  JSON.parse(response.body)
rescue JSON::ParserError
  nil
end

def error_code(response)
  json_of(response)&.dig("error", "code")
end

# Set-Cookie の行のうち、name の行（属性は小文字にして返す）
def cookie_line(response, name)
  response.cookies.find { |line| line.start_with?("#{name}=") }
end

def cookie_value(response, name)
  line = cookie_line(response, name)
  value = line&.split(";")&.first&.delete_prefix("#{name}=").to_s
  value.empty? ? nil : value
end

def attributes_of(line)
  line.to_s.downcase.split(";").map(&:strip)
end

def expired?(response, name)
  line = cookie_line(response, name)
  !line.nil? && line.start_with?("#{name}=;") && line.downcase.include?("expires=thu, 01 jan 1970")
end

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

  def section(title)
    puts "\n-- #{title}"
  end
end

checker = Checker.new
log_offset = File.exist?(LOG_PATH) ? File.size(LOG_PATH) : 0
probe_ip = "203.0.113.#{SecureRandom.random_number(200) + 20}"
bff = bff_headers(probe_ip)
json_headers = bff.merge("Content-Type" => "application/json", "X-BL-Client" => "web")
callback_url = "#{FRONTEND_ORIGIN}/api/auth/callback"

def start_login(headers, token = "dev-pass")
  call(:post, "/api/auth/login/start", headers: headers, body: JSON.generate("recaptcha_token" => token))
end

# 開始 → 疑似の認可画面 → アカウントの選択。コールバックの要求（パスとクエリ）と、bl_oauth の値・認可 URL を返す
def begin_login(headers, bff, account)
  started = start_login(headers)
  authorization_url = json_of(started).fetch("authorization_url")
  uri = URI.parse(authorization_url)
  page = call(:get, "#{uri.path}?#{uri.query}", headers: bff)
  link = page.body.scan(/<a href="([^"]+)">([^<]+)<\/a>/).map { |href, label| [ CGI.unescapeHTML(label), CGI.unescapeHTML(href) ] }.to_h.fetch(account)
  link_uri = URI.parse(link)
  { oauth: cookie_value(started, "bl_oauth"), callback_path: "#{link_uri.path}?#{link_uri.query}", authorization_url: authorization_url, page: page, started: started }
end

checker.section "1. login/start（BFF の確認・入力の検査・bot 判定・認可 URL）"
checker.check("X-BFF-Secret が無い要求は 403 forbidden") do
  response = call(:post, "/api/auth/login/start", headers: json_headers.merge("X-BFF-Secret" => nil), body: "{}")
  response.status == 403 && error_code(response) == "forbidden"
end
checker.check("recaptcha_token が無ければ 422 invalid_input（fields に recaptcha_token）。Cookie を設定しない") do
  response = call(:post, "/api/auth/login/start", headers: json_headers, body: "{}")
  response.status == 422 && json_of(response) == { "error" => { "code" => "invalid_input", "details" => { "fields" => [ "recaptcha_token" ] } } } && response.cookies.empty?
end
checker.check("bot 判定に失敗する（dev-fail）と 403 bot_check_failed。認可 URL も Cookie も無い") do
  response = start_login(json_headers, "dev-fail")
  response.status == 403 && error_code(response) == "bot_check_failed" && response.cookies.empty? && !response.body.include?("authorization_url")
end
started = start_login(json_headers)
authorization = json_of(started)&.fetch("authorization_url", nil).to_s
query = URI.parse(authorization).query.to_s.then { |text| URI.decode_www_form(text).to_h }
checker.check("dev-pass で 200。認可 URL は、公開オリジン（フロントエンド）の疑似の認可画面 /api/dev/google/authorize") do
  started.status == 200 && authorization.start_with?("#{FRONTEND_ORIGIN}/api/dev/google/authorize?") &&
    started.headers["content-type"].to_s.start_with?("application/json") && started.headers["cache-control"] == "no-store"
end
checker.check("認可 URL のパラメータ: スコープは openid のみ・response_type=code・PKCE の S256・redirect_uri は公開オリジンの /api/auth/callback") do
  query["scope"] == "openid" && query["response_type"] == "code" && query["code_challenge_method"] == "S256" &&
    query["redirect_uri"] == callback_url && %w[ state nonce code_challenge ].all? { |name| query[name].to_s.match?(/\A[A-Za-z0-9_-]{43}\z/) }
end
checker.check("bl_oauth: HttpOnly・SameSite=Lax・Path=/・Max-Age=600（開発の http なので Secure は付けない）。値は暗号化されている") do
  attributes = attributes_of(cookie_line(started, "bl_oauth"))
  value = cookie_value(started, "bl_oauth").to_s
  %w[ httponly samesite=lax path=/ max-age=600 ].all? { |entry| attributes.include?(entry) } && !attributes.include?("secure") &&
    !value.include?(query["state"].to_s) && !value.include?(query["nonce"].to_s)
end
checker.check("bl_session は設定しない（ログイン前）") do
  cookie_line(started, "bl_session").nil?
end

checker.section "2. 疑似の認可画面（開発・テストのみ）"
flow = begin_login(json_headers, bff, "dev-user-1")
checker.check("200・text/html（UTF-8）・Cache-Control: no-store") do
  flow[:page].status == 200 && flow[:page].headers["content-type"] == "text/html; charset=utf-8" && flow[:page].headers["cache-control"] == "no-store"
end
checker.check("固定の 3 アカウント（dev-user-1〜dev-user-3）のリンクがある。フォーム・スクリプトは無い") do
  labels = flow[:page].body.scan(/<a href="[^"]+">([^<]+)<\/a>/).flatten
  labels == %w[ dev-user-1 dev-user-2 dev-user-3 ] && !flow[:page].body.match?(/<form|<script/i)
end
checker.check("リンク先は、公開オリジンのコールバック（code と state）") do
  flow[:callback_path].start_with?("/api/auth/callback?code=") && URI.decode_www_form(URI.parse("http://x#{flow[:callback_path]}").query).to_h.keys == %w[ code state ]
end
checker.check("不正な redirect_uri（別のホスト）では画面を出さない: 422 invalid_input") do
  uri = URI.parse(flow[:authorization_url])
  tampered = URI.decode_www_form(uri.query).to_h.merge("redirect_uri" => "https://evil.example.test/api/auth/callback")
  response = call(:get, "#{uri.path}?#{URI.encode_www_form(tampered)}", headers: bff)
  response.status == 422 && error_code(response) == "invalid_input" && !response.body.include?("<a")
end
checker.check("BFF の確認なしでは、画面を出さない: 403 forbidden") do
  uri = URI.parse(flow[:authorization_url])
  call(:get, "#{uri.path}?#{uri.query}", headers: bff.merge("X-BFF-Secret" => nil)).status == 403
end

checker.section "3. コールバック（state の照合・セッションの発行・公開オリジンへのリダイレクト）"
wrong_state_path = flow[:callback_path].sub(/state=[^&]+/, "state=dummy-wrong-state")
failed = call(:get, wrong_state_path, headers: bff, cookie: "bl_oauth=#{flow[:oauth]}")
checker.check("state が違えば 302 /?login_error=oauth_failed（公開オリジン）。bl_oauth は失効、bl_session は発行しない") do
  failed.status == 302 && failed.headers["location"] == "#{FRONTEND_ORIGIN}/?login_error=oauth_failed" && expired?(failed, "bl_oauth") && cookie_line(failed, "bl_session").nil?
end
checker.check("bl_oauth が無ければ 302 /?login_error=oauth_failed") do
  response = call(:get, flow[:callback_path], headers: bff)
  response.status == 302 && response.headers["location"] == "#{FRONTEND_ORIGIN}/?login_error=oauth_failed" && cookie_line(response, "bl_session").nil?
end
checker.check("認可の拒否（error=access_denied）は 302 /?login_error=oauth_failed") do
  flow_state = URI.decode_www_form(URI.parse(flow[:authorization_url]).query).to_h.fetch("state")
  response = call(:get, "/api/auth/callback?error=access_denied&state=#{flow_state}", headers: bff, cookie: "bl_oauth=#{flow[:oauth]}")
  response.status == 302 && response.headers["location"] == "#{FRONTEND_ORIGIN}/?login_error=oauth_failed" && expired?(response, "bl_oauth")
end
checker.check("X-BFF-Secret が無ければ 403 forbidden（リダイレクトしない）") do
  response = call(:get, flow[:callback_path], headers: bff.merge("X-BFF-Secret" => nil), cookie: "bl_oauth=#{flow[:oauth]}")
  response.status == 403 && response.headers["location"].nil?
end

flow = begin_login(json_headers, bff, "dev-user-1")
success = call(:get, flow[:callback_path], headers: bff, cookie: "bl_oauth=#{flow[:oauth]}")
session_token = cookie_value(success, "bl_session")
checker.check("正しい state: 302 /studio（公開オリジンの絶対 URL）。bl_oauth は失効する") do
  success.status == 302 && success.headers["location"] == "#{FRONTEND_ORIGIN}/studio" && expired?(success, "bl_oauth") && success.headers["cache-control"] == "no-store"
end
checker.check("bl_session: HttpOnly・SameSite=Lax・Path=/・有効期限の属性なし（ブラウザのセッション Cookie）。識別子は 43 文字の乱数") do
  attributes = attributes_of(cookie_line(success, "bl_session"))
  %w[ httponly samesite=lax path=/ ].all? { |entry| attributes.include?(entry) } && attributes.none? { |entry| entry.start_with?("max-age", "expires") } &&
    session_token.to_s.match?(/\A[A-Za-z0-9_-]{43}\z/)
end

checker.section "4. 発行されたセッションの利用・セッション固定化の防止"
csrf = CsrfToken.new(secret: Rails.application.secret_key_base)
usage_event = JSON.generate("event_type" => "watch_url_copied")
checker.check("発行されたセッションで、ログインが必要な API（POST /api/usage-events）が 204（CSRF トークンつき）") do
  response = call(:post, "/api/usage-events", headers: json_headers.merge("X-CSRF-Token" => csrf.derive(session_token)), body: usage_event, cookie: "bl_session=#{session_token}")
  response.status == 204
end
checker.check("セッションが無ければ 401 not_logged_in") do
  call(:post, "/api/usage-events", headers: json_headers, body: usage_event).status == 401
end
second_flow = begin_login(json_headers, bff, "dev-user-1")
relogin = call(:get, second_flow[:callback_path], headers: bff, cookie: "bl_oauth=#{second_flow[:oauth]}; bl_session=#{session_token}")
new_token = cookie_value(relogin, "bl_session")
checker.check("ログイン中の再ログインで、セッションの識別子が変わる（固定化の防止）。古い識別子は 401") do
  old = call(:post, "/api/usage-events", headers: json_headers.merge("X-CSRF-Token" => csrf.derive(session_token)), body: usage_event, cookie: "bl_session=#{session_token}")
  !new_token.nil? && new_token != session_token && old.status == 401
end
checker.check("攻撃者が植え付けた識別子（未登録の値）は受け入れず、新しい識別子を発行する") do
  third = begin_login(json_headers, bff, "dev-user-2")
  planted = SecureRandom.urlsafe_base64(32)
  response = call(:get, third[:callback_path], headers: bff, cookie: "bl_oauth=#{third[:oauth]}; bl_session=#{planted}")
  issued = cookie_value(response, "bl_session")
  logout_token = issued
  call(:post, "/api/auth/logout", headers: json_headers.merge("X-CSRF-Token" => csrf.derive(logout_token)), cookie: "bl_session=#{logout_token}")
  !issued.nil? && issued != planted
end

checker.section "5. ログアウト"
logout_headers = json_headers.merge("X-CSRF-Token" => csrf.derive(new_token.to_s))
checker.check("X-CSRF-Token が無ければ 403 csrf_invalid（セッションは残る）") do
  response = call(:post, "/api/auth/logout", headers: json_headers, cookie: "bl_session=#{new_token}")
  response.status == 403 && error_code(response) == "csrf_invalid"
end
logout = call(:post, "/api/auth/logout", headers: logout_headers, cookie: "bl_session=#{new_token}")
checker.check("ログアウトは 204。bl_session を失効させる") do
  logout.status == 204 && logout.body.empty? && expired?(logout, "bl_session")
end
checker.check("2 回目は 401 not_logged_in。古い識別子は使えない") do
  again = call(:post, "/api/auth/logout", headers: logout_headers, cookie: "bl_session=#{new_token}")
  usage = call(:post, "/api/usage-events", headers: logout_headers, body: usage_event, cookie: "bl_session=#{new_token}")
  again.status == 401 && usage.status == 401
end
checker.check("ログインしていないログアウトは 401") do
  call(:post, "/api/auth/logout", headers: json_headers).status == 401
end

checker.section "6. 頻度制限（IP 単位 30 回 / 時）"
limit_ip = "203.0.113.#{SecureRandom.random_number(200) + 20}"
limit_headers = bff_headers(limit_ip).merge("Content-Type" => "application/json", "X-BL-Client" => "web")
statuses = Array.new(30) { start_login(limit_headers, "dev-fail").status }
last = start_login(limit_headers, "dev-fail")
checker.check("30 回目までは通る（bot 判定で 403）。31 回目は 429 rate_limited") do
  statuses.uniq == [ 403 ] && last.status == 429 && error_code(last) == "rate_limited"
end
checker.check("429 の details.retry_at は、JST（+09:00）の ISO 8601") do
  json_of(last).dig("error", "details", "retry_at").to_s.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+09:00\z/)
end
checker.check("別の IP は別の計数（通る）") do
  start_login(bff_headers("203.0.113.#{SecureRandom.random_number(200) + 20}").merge("Content-Type" => "application/json", "X-BL-Client" => "web"), "dev-fail").status == 403
end

checker.section "7. ログ（log/development.log）に、機密・IP が現れない"
log_text = File.exist?(LOG_PATH) ? File.open(LOG_PATH) { |file| file.seek(log_offset) && file.read.to_s } : ""
secrets = {
  "state" => query["state"], "nonce" => query["nonce"], "bl_oauth の値" => flow[:oauth], "セッションの識別子" => session_token,
  "新しいセッションの識別子" => new_token, "この実行の IP" => probe_ip, "頻度制限用の IP" => limit_ip, "認可コード" => URI.decode_www_form(URI.parse("http://x#{flow[:callback_path]}").query).to_h["code"],
  "BFF の秘密値" => SECRET
}
checker.check("ログが出ている（空ではない）。リクエストの開始の行がある") do
  log_text.include?("Started POST \"/api/auth/login/start\"") && log_text.include?("Started GET \"/api/auth/callback?")
end
secrets.each do |label, value|
  checker.check("ログに、#{label}が現れない") { value.to_s.length >= 8 && !log_text.include?(value.to_s) }
end
checker.check("ログに、sub（dev-user-1）が現れない。ログインの完了は、内部の識別子で出る") do
  !log_text.include?("dev-user-1") && log_text.match?(/\[login\] completed user_id=\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/)
end
checker.check("ログに、失敗の理由が符号で出る（state_mismatch・authorization_denied・state_cookie_invalid）") do
  %w[ state_mismatch authorization_denied state_cookie_invalid ].all? { |reason| log_text.include?("[login] failed reason=#{reason}") }
end

puts
puts "#{checker.checks} 件を確認しました（失敗 #{checker.failures} 件）"
exit(checker.failures.zero? ? 0 : 1)
