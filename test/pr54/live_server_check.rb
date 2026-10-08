# PR 54（issue #11 YouTube 接続）の、実サーバー（開発の backend コンテナの Puma）への確認。
# backend コンテナの中で、`bin/rails runner -` へ標準入力から渡して実行する（run_all.sh が呼ぶ）。
# Rails は、ログインの代わりのセッションの発行（SessionStore）・CSRF トークンの導出（CsrfToken）・DB の確認にだけ使う。
# 要求は、実際の HTTP で Puma（localhost:3001）へ送る。フロントエンドの BFF が付けるヘッダ（X-BFF-Secret・X-Forwarded-*）を、このスクリプトが付ける
# （開発の公開オリジンは http://localhost:3000）。
#
# 確かめること（疑似の Google・疑似の YouTube を使う、開発の環境の判定で）
#   1. connect/start: BFF の確認・ログイン・CSRF・入力の検査・bot 判定（dev-fail は 403）・認可 URL（疑似の同意画面。スコープは youtube の 1 種・offline・consent・
#      login_hint・S256。include_granted_scopes と nonce は無い）・bl_oauth の属性・測定イベント connect_started
#   2. 疑似の同意画面: 選択肢 7 つ。不正な認可の要求（スコープが openid など）は 422
#   3. 成立: 選択（allow）-> 戻り先 -> 302 /account?connect=connected（公開オリジン）。bl_oauth は失効。接続の行（暗号文だけ）・測定イベント connect_completed。
#      再確認: 200（connected・channel_title は null・can_recheck_at は JST）。直後の 2 回目は 429（retry_at）
#   4. 再接続: 暗号文が置き換わり、保存していた配信用ストリームの識別子が破棄される
#   5. 不成立（新しいアカウント）: 権限の部分拒否・更新トークンなし・チャンネルなし・確認不能・拒否（error=access_denied）。接続の行を作らない・
#      Google 側の失効（拒否以外）・測定イベント connect_failed。ライブ未有効の成立 -> 再確認で接続済み。既存の接続があれば、不成立でも変更しない（失効もしない）
#   6. コールバックの検査: state の不一致・bl_oauth なし・別のアカウントのセッションは unverifiable。測定イベントは、ログイン中のアカウントが開始した接続
#      （有効な bl_oauth）だけ記録する（匿名・bl_oauth なし・でたらめな要求を何度送っても、行が増えない）
#   7. 頻度制限: connect/start は同じ IP の 31 回目が 429。再確認はアカウントごと。接続なしは 409 not_connected、認可失効は 200 revoked
#   8. ログ（log/development.log）に、state・認可コード・bl_oauth の値・セッションの識別子・トークン・チャンネル名・利用者の IP が現れない
#
# 安全:
#   - BFF の秘密値は、コンテナの環境変数 BFF_SHARED_SECRET から読む。出力しない
#   - 対象は、開発サーバー（コンテナの中の localhost）。本番へ接続しない。実際の Google・YouTube は呼ばない（疑似）
#   - 開発 DB に作られるもの: アカウント dummy-live-check-*（この実行専用。実行のたびに新しい名前）・セッション・接続・測定イベント・台帳の明細（共通枠）。
#     この確認は、削除しません。開発 DB が膨らんだら、手動で整理してください
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
YOUTUBE_SCOPE = "https://www.googleapis.com/auth/youtube".freeze

if SECRET.empty?
  puts "FAIL コンテナの環境変数 BFF_SHARED_SECRET がありません（scripts/setup_dev_env.sh を実行してください）"
  exit 2
end
unless AppEnvironment.current.development?
  puts "FAIL 開発の環境ではありません（#{AppEnvironment.current.name}）。中止します"
  exit 2
end

# rails runner は、問い合わせのキャッシュを有効にする。別の接続（Puma）が書いた行が、同じ問い合わせの再実行で見えなくなるので、無効にする
ActiveRecord::Base.connection_pool.disable_query_cache!

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
  response = Net::HTTP.start(PUBLIC_HOST, PUBLIC_PORT, read_timeout: 30, open_timeout: 10) { |http| http.request(request) }
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

def cookie_line(response, name)
  response.cookies.find { |line| line.start_with?("#{name}=") }
end

def cookie_value(response, name)
  value = cookie_line(response, name)&.split(";")&.first&.delete_prefix("#{name}=").to_s
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
csrf_maker = CsrfToken.new(secret: Rails.application.secret_key_base)
callback_url = "#{FRONTEND_ORIGIN}/api/youtube/connect/callback"
account_url = "#{FRONTEND_ORIGIN}/account"
run_id = SecureRandom.hex(4)
secrets_seen = []

# この実行専用のアカウントとセッション（ログインの代わり。ログイン自体は、test/pr48 が確かめている）
Login = Struct.new(:user, :token, :csrf, keyword_init: true) do
  def cookie(oauth: nil)
    parts = []
    parts << "bl_oauth=#{oauth}" if oauth
    parts << "bl_session=#{token}"
    parts.join("; ")
  end
end

def login_as(label, csrf_maker)
  user = User.create!(google_sub: "dummy-live-check-#{label}-#{SecureRandom.hex(4)}", last_login_at: Time.current)
  issued = SessionStore.new.issue(user: user, now: Time.current)
  Login.new(user: user, token: issued.token, csrf: csrf_maker.derive(issued.token))
end

def post_json(path, login, body, headers, extra = {})
  call(:post, path, headers: headers.merge("Content-Type" => "application/json", "X-BL-Client" => "web", "X-CSRF-Token" => login.csrf, "Origin" => FRONTEND_ORIGIN).merge(extra),
                    body: body, cookie: login.cookie)
end

def start_connect(login, headers, token = "dev-pass")
  post_json("/api/youtube/connect/start", login, JSON.generate("recaptcha_token" => token), headers)
end

# 認可 URL の経路（パスとクエリ）
def path_of(url)
  uri = URI.parse(url)
  "#{uri.path}?#{uri.query}"
end

# 疑似の同意画面の選択肢: ラベル => リンク
def choices_of(page)
  page.body.scan(/<a href="([^"]+)">([^<]+)<\/a>/).map { |href, label| [ CGI.unescapeHTML(label), CGI.unescapeHTML(href) ] }.to_h
end

# 開始 -> 同意画面 -> 選択。戻り先の URL（コールバック）と、bl_oauth の値・コード・state を返す
def begin_connect(login, bff, scenario)
  started = start_connect(login, bff)
  authorization_url = json_of(started)&.fetch("authorization_url")
  page = call(:get, path_of(authorization_url), headers: bff)
  chosen = call(:get, choices_of(page).fetch(scenario), headers: bff)
  location = chosen.headers["location"].to_s
  query = Rack::Utils.parse_query(URI.parse(location).query.to_s)
  { oauth: cookie_value(started, "bl_oauth"), callback_path: path_of(location), code: query["code"], state: query["state"], started: started, page: page, chosen: chosen, authorization_url: authorization_url }
end

def run_callback(login, flow, bff, oauth: flow[:oauth], path: flow[:callback_path], cookie_login: login)
  call(:get, path, headers: bff, cookie: cookie_login ? cookie_login.cookie(oauth: oauth) : (oauth ? "bl_oauth=#{oauth}" : nil))
end

def connection_of(user)
  YoutubeConnection.owned_by(user).take
end

def snapshot(connection)
  connection.reload.slice(:state, :refresh_token_ciphertext, :youtube_stream_id, :stream_verified_at, :connected_at, :last_verified_at)
end

def revoke_log_count(offset)
  return 0 unless File.exist?(LOG_PATH)

  File.open(LOG_PATH, "rb") { |file| file.seek(offset) && file.read.to_s.scan("[fake_google] token revoked").size }
end

json_headers = bff.merge("Content-Type" => "application/json", "X-BL-Client" => "web")

# ------------------------------------------------------------------------------------------------------------------------------
checker.section "1. connect/start（BFF の確認・ログイン・CSRF・入力の検査・bot 判定・認可 URL・bl_oauth）"
alice = login_as("alice-#{run_id}", csrf_maker)
checker.check("X-BFF-Secret が無い要求は 403 forbidden") do
  response = call(:post, "/api/youtube/connect/start", headers: json_headers.merge("X-BFF-Secret" => nil), body: "{}", cookie: alice.cookie)
  response.status == 403 && error_code(response) == "forbidden"
end
checker.check("ログインしていなければ 401 not_logged_in") do
  response = call(:post, "/api/youtube/connect/start", headers: json_headers, body: JSON.generate("recaptcha_token" => "dev-pass"))
  response.status == 401 && error_code(response) == "not_logged_in"
end
checker.check("X-BL-Client が無ければ 403 csrf_invalid。X-CSRF-Token が違っても 403") do
  no_client = call(:post, "/api/youtube/connect/start", headers: bff.merge("Content-Type" => "application/json", "X-CSRF-Token" => alice.csrf, "Origin" => FRONTEND_ORIGIN), body: "{}", cookie: alice.cookie)
  wrong_token = call(:post, "/api/youtube/connect/start", headers: json_headers.merge("X-CSRF-Token" => "dummy-wrong-token", "Origin" => FRONTEND_ORIGIN), body: "{}", cookie: alice.cookie)
  no_client.status == 403 && error_code(no_client) == "csrf_invalid" && wrong_token.status == 403 && error_code(wrong_token) == "csrf_invalid"
end
checker.check("recaptcha_token が無ければ 422 invalid_input（fields に recaptcha_token）。Cookie を設定しない") do
  response = post_json("/api/youtube/connect/start", alice, "{}", bff)
  response.status == 422 && json_of(response) == { "error" => { "code" => "invalid_input", "details" => { "fields" => [ "recaptcha_token" ] } } } && cookie_line(response, "bl_oauth").nil?
end
checker.check("dev-fail は 403 bot_check_failed。認可 URL も bl_oauth も無い") do
  response = start_connect(alice, bff, "dev-fail")
  response.status == 403 && error_code(response) == "bot_check_failed" && cookie_line(response, "bl_oauth").nil? && !response.body.include?("authorization_url")
end
events_before = UsageEvent.where(event_type: "connect_started").count
started = start_connect(alice, bff)
authorization_url = json_of(started)&.fetch("authorization_url").to_s
query = Rack::Utils.parse_query(URI.parse(authorization_url).query.to_s)
secrets_seen.push(query["state"], cookie_value(started, "bl_oauth"), alice.token)
checker.check("dev-pass は 200 と認可 URL。行き先は、公開オリジンの疑似の同意画面（#{FRONTEND_ORIGIN}/api/dev/google/connect）") do
  started.status == 200 && authorization_url.start_with?("#{FRONTEND_ORIGIN}/api/dev/google/connect?") && started.headers["cache-control"] == "no-store"
end
checker.check("認可 URL: スコープは youtube の 1 種のみ・offline・consent・PKCE の S256・login_hint はログイン中の sub・戻り先は公開オリジンのコールバック") do
  query["scope"] == YOUTUBE_SCOPE && query["access_type"] == "offline" && query["prompt"] == "consent" && query["code_challenge_method"] == "S256" &&
    query["login_hint"] == alice.user.google_sub && query["redirect_uri"] == callback_url && query["response_type"] == "code"
end
checker.check("認可 URL に include_granted_scopes・nonce が無い。スコープに openid・email・profile が無い") do
  !query.key?("include_granted_scopes") && !query.key?("nonce") && query["scope"].split.none? { |scope| %w[ openid email profile ].include?(scope) }
end
checker.check("bl_oauth: HttpOnly・SameSite=Lax・Path=/・Max-Age=600。値に state・アカウント識別子が見えない") do
  attributes = attributes_of(cookie_line(started, "bl_oauth"))
  value = cookie_value(started, "bl_oauth").to_s
  %w[ httponly samesite=lax path=/ max-age=600 ].all? { |attribute| attributes.include?(attribute) } && !value.include?(query["state"]) && !value.include?(alice.user.id)
end
checker.check("測定イベント connect_started を、アカウントに紐づけて記録する（符号・区分を持たない）") do
  event = UsageEvent.where(event_type: "connect_started", user_id: alice.user.id).order(:occurred_at).last
  UsageEvent.where(event_type: "connect_started").count == events_before + 1 && event.reason_code.nil? && event.bucket.nil? && event.browser_class.nil?
end

# ------------------------------------------------------------------------------------------------------------------------------
checker.section "2. 疑似の同意画面（GET /api/dev/google/connect）"
page = call(:get, path_of(authorization_url), headers: bff)
choices = choices_of(page)
checker.check("200 の HTML。選択肢は 7 つ（allow・allow_live_not_enabled・allow_no_channel・allow_unverifiable・allow_without_youtube・allow_without_refresh_token・deny）") do
  page.status == 200 && page.headers["content-type"].to_s.include?("text/html") &&
    choices.keys == %w[ allow allow_live_not_enabled allow_no_channel allow_unverifiable allow_without_youtube allow_without_refresh_token deny ]
end
checker.check("各リンクは、同一オリジンの相対パス（/api/dev/google/connect/choose）") do
  choices.values.all? { |href| URI.parse(href).path == "/api/dev/google/connect/choose" && URI.parse(href).host.nil? }
end
checker.check("不正な認可の要求（スコープが openid）は 422。選択肢を出さない") do
  bad = call(:get, "/api/dev/google/connect?#{authorization_url.split('?', 2).last.sub(CGI.escape(YOUTUBE_SCOPE), 'openid')}", headers: bff)
  bad.status == 422 && !bad.body.include?("<a")
end
checker.check("include_granted_scopes が付いた認可の要求は 422（過去の付与を混ぜない）") do
  bad = call(:get, "#{path_of(authorization_url)}&include_granted_scopes=true", headers: bff)
  bad.status == 422 && json_of(bad)&.dig("error", "details", "fields") == [ "include_granted_scopes" ]
end

# ------------------------------------------------------------------------------------------------------------------------------
checker.section "3. 成立（allow）: 戻り先 -> 302 /account?connect=connected。接続の行（暗号文だけ）・測定イベント・再確認"
common_before = QuotaEntry.where(bucket: "common").count
flow = begin_connect(alice, bff, "allow")
secrets_seen.push(flow[:state], flow[:code], flow[:oauth])
checker.check("選択（allow）は 302。戻り先は公開オリジンのコールバックで、code と state を付ける") do
  flow[:chosen].status == 302 && flow[:chosen].headers["location"].to_s.start_with?("#{callback_url}?") && flow[:code].present? && flow[:state].present?
end
callback = run_callback(alice, flow, bff)
checker.check("コールバックは 302。Location は #{account_url}?connect=connected（公開オリジンの絶対 URL）") do
  callback.status == 302 && callback.headers["location"] == "#{account_url}?connect=connected" && callback.headers["cache-control"] == "no-store" && callback.body.empty?
end
checker.check("bl_oauth を失効させる。セッション（bl_session）は作り直さない") do
  expired?(callback, "bl_oauth") && cookie_line(callback, "bl_session").nil?
end
connection = connection_of(alice.user)
checker.check("接続の行: 状態 connected・接続の時刻と確認の時刻がある・配信用ストリームの識別子は無い") do
  connection && connection.state == "connected" && connection.connected_at.present? && connection.last_verified_at.present? && connection.youtube_stream_id.nil?
end
checker.check("保存されるのは暗号化した更新トークンだけ（暗号文に、疑似のトークンの平文が無い。DB のどの表にも、アクセストークン・チャンネル名が無い）") do
  database = ActiveRecord::Base.connection
  dump = (database.tables - %w[ schema_migrations ar_internal_metadata ]).map do |table|
    database.select_all("SELECT * FROM #{database.quote_table_name(table)}").to_a.to_s
  end.join("\n")
  connection.refresh_token_ciphertext.present? && !dump.match?(/fake-refresh-token-|fake-connect-access-token-|Fake Channel/)
end
checker.check("測定イベント connect_completed（符号 connected）を、アカウントに紐づけて記録する。IP・sub・チャンネル名を含めない") do
  event = UsageEvent.where(event_type: "connect_completed", user_id: alice.user.id).sole
  joined = event.attributes.values.map(&:to_s).join(" ")
  event.reason_code == "connected" && !joined.include?(probe_ip) && !joined.include?(alice.user.google_sub) && !joined.include?("Fake Channel")
end
checker.check("確認は共通枠から 2 ユニット（channels.list 1・liveBroadcasts.list 1）を記帳する") do
  QuotaEntry.where(bucket: "common").count == common_before + 2
end
recheck = post_json("/api/youtube/recheck", alice, nil, bff)
checker.check("再確認: 200。state は connected・channel_title は null・can_recheck_at は JST の ISO 8601（1 分後）") do
  body = json_of(recheck)
  body && body["youtube"].keys == %w[ state channel_title can_recheck_at ] && body["youtube"]["state"] == "connected" && body["youtube"]["channel_title"].nil? &&
    body["youtube"]["can_recheck_at"].to_s.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+09:00\z/)
end
checker.check("再確認の直後の 2 回目は 429 rate_limited（details の retry_at は JST）") do
  again = post_json("/api/youtube/recheck", alice, nil, bff)
  again.status == 429 && error_code(again) == "rate_limited" && json_of(again).dig("error", "details", "retry_at").to_s.end_with?("+09:00")
end

# ------------------------------------------------------------------------------------------------------------------------------
checker.section "4. 再接続: 暗号文の置き換えと、配信用ストリームの識別子の破棄（10.5）"
connection.update!(youtube_stream_id: "dummy-live-check-stream-#{run_id}", stream_verified_at: Time.current)
before_ciphertext = connection.reload.refresh_token_ciphertext
reconnect = begin_connect(alice, bff, "allow")
secrets_seen.push(reconnect[:state], reconnect[:code], reconnect[:oauth])
reconnect_callback = run_callback(alice, reconnect, bff)
checker.check("再接続は 302 /account?connect=connected") do
  reconnect_callback.status == 302 && reconnect_callback.headers["location"] == "#{account_url}?connect=connected"
end
checker.check("暗号文が置き換わり、保存していた配信用ストリームの識別子と最終確認の時刻が破棄される。接続の行は 1 件のまま") do
  current = connection_of(alice.user)
  current.refresh_token_ciphertext != before_ciphertext && current.youtube_stream_id.nil? && current.stream_verified_at.nil? && YoutubeConnection.owned_by(alice.user).count == 1
end

# ------------------------------------------------------------------------------------------------------------------------------
checker.section "5. 不成立（新しいアカウント。接続なし）: 接続の行を作らず、トークンを破棄し、拒否以外は Google 側で失効させる"
bob = login_as("bob-#{run_id}", csrf_maker)
{
  "allow_without_youtube" => [ "scope_denied", true ],
  "allow_without_refresh_token" => [ "no_refresh_token", true ],
  "allow_no_channel" => [ "no_channel", true ],
  "allow_unverifiable" => [ "unverifiable", true ],
  "deny" => [ "scope_denied", false ]
}.each do |scenario, (result, revokes)|
  failed_before = UsageEvent.where(event_type: "connect_failed", user_id: bob.user.id).count
  revoke_offset = File.exist?(LOG_PATH) ? File.size(LOG_PATH) : 0
  failed_flow = begin_connect(bob, bff, scenario)
  secrets_seen.push(failed_flow[:state], failed_flow[:code], failed_flow[:oauth])
  failed_callback = run_callback(bob, failed_flow, bff)
  checker.check("#{scenario}: 302 /account?connect=#{result}。bl_oauth を失効させる") do
    failed_callback.status == 302 && failed_callback.headers["location"] == "#{account_url}?connect=#{result}" && expired?(failed_callback, "bl_oauth")
  end
  checker.check("#{scenario}: 接続の行を作らない。測定イベント connect_failed（符号 #{result}）を記録する") do
    event = UsageEvent.where(event_type: "connect_failed", user_id: bob.user.id).order(:occurred_at).last
    connection_of(bob.user).nil? && UsageEvent.where(event_type: "connect_failed", user_id: bob.user.id).count == failed_before + 1 && event.reason_code == result
  end
  checker.check("#{scenario}: Google 側の失効 #{revokes ? 'を 1 回行う' : 'は行わない（コードを受け取っていない）'}") do
    revoke_log_count(revoke_offset) == (revokes ? 1 : 0)
  end
end

checker.section "5b. ライブ未有効の成立 -> 再確認で接続済み。既存の接続があれば、不成立でも変更しない"
live_flow = begin_connect(bob, bff, "allow_live_not_enabled")
secrets_seen.push(live_flow[:state], live_flow[:code], live_flow[:oauth])
live_callback = run_callback(bob, live_flow, bff)
checker.check("allow_live_not_enabled: 302 /account?connect=live_not_enabled。接続の状態は live_not_enabled（成立）。測定イベントの符号は live_not_enabled") do
  live_callback.status == 302 && live_callback.headers["location"] == "#{account_url}?connect=live_not_enabled" && connection_of(bob.user)&.state == "live_not_enabled" &&
    UsageEvent.where(event_type: "connect_completed", user_id: bob.user.id).sole.reason_code == "live_not_enabled"
end
checker.check("再確認でライブ有効: live_not_enabled -> connected（200）") do
  response = post_json("/api/youtube/recheck", bob, nil, bff)
  response.status == 200 && json_of(response).dig("youtube", "state") == "connected" && connection_of(bob.user).state == "connected"
end
protected_connection = connection_of(bob.user)
protected_connection.update!(youtube_stream_id: "dummy-live-check-protected-#{run_id}", stream_verified_at: Time.current)
before = snapshot(protected_connection)
revoke_offset = File.exist?(LOG_PATH) ? File.size(LOG_PATH) : 0
protect_flow = begin_connect(bob, bff, "allow_without_youtube")
secrets_seen.push(protect_flow[:state], protect_flow[:code], protect_flow[:oauth])
protect_callback = run_callback(bob, protect_flow, bff)
checker.check("既存の接続があるとき、不成立（scope_denied）でも、状態・暗号文・ストリームの識別子・時刻を変更しない") do
  protect_callback.headers["location"] == "#{account_url}?connect=scope_denied" && snapshot(protected_connection) == before
end
checker.check("既存の接続があるとき、Google 側で失効させない（同じ付与を共有するため）") do
  revoke_log_count(revoke_offset) == 0
end

# ------------------------------------------------------------------------------------------------------------------------------
checker.section "6. コールバックの検査（state の不一致・bl_oauth なし・別のアカウントのセッション）"
carol = login_as("carol-#{run_id}", csrf_maker)
valid_flow = begin_connect(carol, bff, "allow")
secrets_seen.push(valid_flow[:state], valid_flow[:code], valid_flow[:oauth])
checker.check("state が違うコールバック: 302 /account?connect=unverifiable。接続を作らない・bl_oauth を失効させる") do
  mismatch = run_callback(carol, valid_flow, bff, path: valid_flow[:callback_path].sub(/state=[^&]+/, "state=dummy-other-state"))
  mismatch.status == 302 && mismatch.headers["location"] == "#{account_url}?connect=unverifiable" && expired?(mismatch, "bl_oauth") && connection_of(carol.user).nil?
end
checker.check("bl_oauth が無いコールバック: unverifiable") do
  no_cookie = run_callback(carol, valid_flow, bff, oauth: nil)
  no_cookie.status == 302 && no_cookie.headers["location"] == "#{account_url}?connect=unverifiable" && connection_of(carol.user).nil?
end
checker.check("別のアカウント（dave）のセッションで、carol の bl_oauth を使う: unverifiable。どちらのアカウントにも接続を作らない") do
  dave = login_as("dave-#{run_id}", csrf_maker)
  stolen = run_callback(dave, valid_flow, bff, cookie_login: dave)
  stolen.status == 302 && stolen.headers["location"] == "#{account_url}?connect=unverifiable" && connection_of(dave.user).nil? && connection_of(carol.user).nil?
end
checker.check("ログインしていない（セッションの Cookie が無い）コールバック: JSON の 401 ではなく、302 /account?connect=unverifiable") do
  anonymous = run_callback(nil, valid_flow, bff, cookie_login: nil)
  anonymous.status == 302 && anonymous.headers["location"] == "#{account_url}?connect=unverifiable" && connection_of(carol.user).nil?
end
checker.check("測定イベントは、ログイン中のアカウントが開始した接続（有効な bl_oauth）だけ記録する: 匿名・bl_oauth が無い・でたらめな要求を何度送っても、行が増えない") do
  events_before_noise = UsageEvent.count
  20.times { run_callback(nil, valid_flow, bff, oauth: nil, cookie_login: nil) }
  5.times { run_callback(nil, valid_flow, bff, cookie_login: nil) }
  5.times { run_callback(carol, valid_flow, bff, oauth: nil) }
  5.times { run_callback(carol, valid_flow, bff, oauth: "garbage") }
  UsageEvent.count == events_before_noise
end
checker.check("開始した接続（有効な bl_oauth）の失敗は、測定イベント connect_failed（符号 unverifiable）を、そのアカウントに 1 件記録する") do
  failing = begin_connect(carol, bff, "allow")
  secrets_seen.push(failing[:state], failing[:code], failing[:oauth])
  failed_before = UsageEvent.where(event_type: "connect_failed", user_id: carol.user.id).count
  run_callback(carol, failing, bff, path: failing[:callback_path].sub(/state=[^&]+/, "state=dummy-other-state"))
  UsageEvent.where(event_type: "connect_failed", user_id: carol.user.id).count == failed_before + 1 &&
    UsageEvent.where(event_type: "connect_failed", user_id: carol.user.id).order(:occurred_at).last.reason_code == "unverifiable"
end
checker.check("error=access_denied を直接送る: scope_denied（コードを交換しない）") do
  denied = call(:get, "/api/youtube/connect/callback?error=access_denied&state=#{valid_flow[:state]}", headers: bff, cookie: carol.cookie(oauth: valid_flow[:oauth]))
  denied.status == 302 && denied.headers["location"] == "#{account_url}?connect=scope_denied" && connection_of(carol.user).nil?
end
checker.check("X-BFF-Secret が無いコールバックは 403 forbidden（リダイレクトしない）") do
  forbidden = call(:get, valid_flow[:callback_path], headers: bff.merge("X-BFF-Secret" => nil), cookie: carol.cookie(oauth: valid_flow[:oauth]))
  forbidden.status == 403 && error_code(forbidden) == "forbidden" && forbidden.headers["location"].nil?
end

# ------------------------------------------------------------------------------------------------------------------------------
checker.section "7. 頻度制限・接続なし・認可失効"
erin = login_as("erin-#{run_id}", csrf_maker)
checker.check("接続なしの再確認は 409 not_connected（details は空）") do
  response = post_json("/api/youtube/recheck", erin, nil, bff)
  response.status == 409 && json_of(response) == { "error" => { "code" => "not_connected", "details" => {} } }
end
frank = login_as("frank-#{run_id}", csrf_maker)
YoutubeConnection.create!(user_id: frank.user.id, state: "revoked", refresh_token_ciphertext: "dummy-live-check-ciphertext", connected_at: Time.current, last_verified_at: Time.current)
checker.check("認可失効の再確認は 200 で state が revoked（再確認せず、YouTube を呼ばない）") do
  entries = QuotaEntry.where(bucket: "common").count
  response = post_json("/api/youtube/recheck", frank, nil, bff)
  response.status == 200 && json_of(response).dig("youtube", "state") == "revoked" && QuotaEntry.where(bucket: "common").count == entries
end
rate_ip = "203.0.113.#{SecureRandom.random_number(200) + 20}"
rate_bff = bff_headers(rate_ip)
grace = login_as("grace-#{run_id}", csrf_maker)
checker.check("connect/start は同じ IP で 30 回までは通り、31 回目は 429 rate_limited（retry_at は JST）。429 は bl_oauth を設定しない") do
  statuses = Array.new(30) { start_connect(grace, rate_bff).status }
  limited = start_connect(grace, rate_bff)
  statuses.all? { |status| status == 200 } && limited.status == 429 && error_code(limited) == "rate_limited" &&
    json_of(limited).dig("error", "details", "retry_at").to_s.end_with?("+09:00") && cookie_line(limited, "bl_oauth").nil?
end
checker.check("別の IP からは通る（IP ごとの計数）") do
  other_ip = bff_headers("203.0.113.#{SecureRandom.random_number(200) + 20}")
  start_connect(grace, other_ip).status == 200
end

# ------------------------------------------------------------------------------------------------------------------------------
checker.section "8. ログに、機密が現れない"
log_text = File.exist?(LOG_PATH) ? File.open(LOG_PATH, "rb") { |file| file.seek(log_offset) && file.read.to_s.force_encoding("UTF-8").scrub } : ""
checker.check("ログが読めて、この実行の要求の記録がある（[youtube_connect] の行）") do
  log_text.include?("[youtube_connect] completed") && log_text.include?("[youtube_connect] failed")
end
checker.check("state・認可コード・bl_oauth の値・セッションの識別子が、ログに現れない") do
  values = secrets_seen.compact.uniq.reject(&:empty?)
  values.size >= 10 && values.none? { |value| log_text.include?(value) }
end
checker.check("疑似のトークン・チャンネル名・利用者の IP が、ログに現れない") do
  [ "fake-refresh-token-", "fake-connect-access-token-", "fake-access-token-", "Fake Channel", probe_ip, rate_ip ].none? { |value| log_text.include?(value) }
end

puts
puts "確認 #{checker.checks} 項目、失敗 #{checker.failures} 項目"
exit(checker.failures.zero? ? 0 : 1)
