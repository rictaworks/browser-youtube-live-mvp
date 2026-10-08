# frozen_string_literal: true

# 変異テスト（issue #10 の YouTube 連携の窓口）。コンテナの /tmp に、アプリケーションの複製を 1 つ作り、実装を 1 か所ずつ壊して、
# 対応するスペックが失敗する（変異を検出する）ことを確かめる。スペックが、振る舞いの退行（記帳の順序・枠の取り違え・トークンの重複排除・
# 暗号文のアカウントへの結びつき・取り込み先の検証・分類の表・疑似の本番での構築など）を見逃さないことの確認。
# 共有の作業ツリー（/app）は書き換えない。変異は、複製の中だけに入れる。作業用の複製は、コンテナの /tmp に残す（削除しない）。
#
# 使い方（run_all.sh --with-mutation が実行する。数分かかる）:
#   scripts/dc.sh exec -T -e ISSUE10_MUTATION_DB=bl_test_... backend ruby - < <このディレクトリ>/mutate_gateway.rb
# 前提: ISSUE10_MUTATION_DB は、スキーマを読み込み済みのテスト用 DB の名前（bl_test_ で始まる）。複製のスペックは、そこへ書く
#       （同時の操作のスペックは、実際にコミットし、各例の前後で、自分の行を整理する）。
# 終了コード: 0 = すべての変異を検出 / 1 = 見逃し、または適用できない変異がある / 2 = 前提を満たさない
require "fileutils"
require "open3"

ROOT = ENV.fetch("ISSUE10_APP_ROOT", "/app")
DATABASE = ENV.fetch("ISSUE10_MUTATION_DB", "")
unless DATABASE.match?(/\Abl_test_[a-z0-9_]+\z/)
  warn "FAIL ISSUE10_MUTATION_DB（#{DATABASE.inspect}）が、テスト用の DB の名前（bl_test_...）ではありません"
  exit 2
end
base_url = ENV.fetch("DATABASE_URL", "")
unless base_url.end_with?("/bl_development")
  warn "FAIL コンテナの DATABASE_URL が、開発 DB（.../bl_development）を指していません。テスト用の URL は、これを元に組み立てます"
  exit 2
end
DATABASE_URL = "#{base_url.delete_suffix('/bl_development')}/#{DATABASE}".freeze

STAMP = Time.now.strftime("%H%M%S")
COPY = "/tmp/issue10_mut_#{STAMP}"

# 複製に含めるもの（依存の gem は、/app の Gemfile と vendor を、そのまま使う）
FileUtils.mkdir_p(COPY)
%w[ app config db lib bin spec ].each do |entry|
  source = "#{ROOT}/#{entry}"
  FileUtils.cp_r(source, "#{COPY}/") if File.exist?(source)
end
%w[ Gemfile Gemfile.lock Rakefile config.ru .rspec .rubocop.yml ].each do |name|
  FileUtils.cp("#{ROOT}/#{name}", "#{COPY}/#{name}") if File.exist?("#{ROOT}/#{name}")
end
FileUtils.mkdir_p("#{COPY}/tmp")
FileUtils.mkdir_p("#{COPY}/log")

ENVIRONMENT = { "RAILS_ENV" => "test", "DATABASE_URL" => DATABASE_URL, "BUNDLE_GEMFILE" => "#{ROOT}/Gemfile" }.freeze

def run_rspec(files)
  output, = Open3.capture2e(ENVIRONMENT, "bundle", "exec", "rspec", *files, "--no-color", "--seed", "1", chdir: COPY)
  summary = output.lines.reverse.find { |line| line.match?(/\d+ examples?, \d+ failures?/) }
  load_error = output.include?("error occurred outside of examples") || output.include?("errors occurred outside of examples")
  [ summary&.strip || "NO SUMMARY: #{output.lines.last(3).join.strip}", load_error, output ]
end

GATEWAY = "spec/gateways/youtube_gateway_spec.rb"
LEDGER = "spec/gateways/youtube_gateway_ledger_spec.rb"
COMMIT = "spec/gateways/youtube_gateway_commit_spec.rb"
ERRORS_VIA_GATEWAY = "spec/gateways/youtube_gateway_errors_spec.rb"
CALLS = "spec/gateways/youtube_gateway_calls_spec.rb"
ERRORS = "spec/gateways/youtube_errors_spec.rb"
INGEST = "spec/gateways/ingest_destination_spec.rb"
VAULT = "spec/gateways/token_vault_spec.rb"
VAULT_CONCURRENCY = "spec/gateways/token_vault_concurrency_spec.rb"
CACHE = "spec/gateways/access_token_cache_spec.rb"
TOKEN_CLIENT = "spec/gateways/google_token_client_spec.rb"
FAKE_API = "spec/gateways/fake_youtube_api_spec.rb"
FAKE_GATEWAY = "spec/gateways/fake_youtube_gateway_spec.rb"
SERVICES = "spec/gateways/youtube_services_spec.rb"
VALUES = "spec/gateways/youtube_values_spec.rb"
CONNECTION = "spec/models/youtube_connection_transitions_spec.rb"
SOURCES = "spec/sources/youtube_gateway_sources_spec.rb"

GW = "app/gateways/youtube_gateway.rb"
REQUESTS = "app/gateways/youtube_gateway/requests.rb"
RESPONSES = "app/gateways/youtube_gateway/responses.rb"
CALLS_TABLE = "app/gateways/youtube_gateway/calls.rb"
ERRORS_FILE = "app/gateways/youtube_errors.rb"
INGEST_FILE = "app/gateways/ingest_destination.rb"
VAULT_FILE = "app/gateways/token_vault.rb"
CACHE_FILE = "app/gateways/token_vault/access_token_cache.rb"
TOKEN_CLIENT_FILE = "app/gateways/google_token_client.rb"
FAKE_API_FILE = "app/gateways/fake_youtube_gateway/api.rb"
FAKE_GATEWAY_FILE = "app/gateways/fake_youtube_gateway.rb"
SERVICES_FILE = "app/gateways/youtube_services.rb"
HEALTH_FILE = "app/gateways/stream_health.rb"
CONNECTION_FILE = "app/models/youtube_connection.rb"

# [ 説明, 複製の中のファイル, 置換前, 置換後, 実行するスペック ]。置換前は、そのファイルに 1 回だけ現れること
MUTATIONS = [
  # --- 窓口の経路 ---
  [ "枠が足りなくても HTTP を送る（QuotaInsufficient を投げない）", GW,
    "    raise YouTubeErrors::QuotaInsufficient.new(call_kind: spec.kind, bucket: pool) unless granted\n", "", [ LEDGER, COMMIT ] ],
  [ "記帳を、アクセストークンの取得より前に行う（取得に失敗しても、実費でない記帳が残る）", GW,
    "    token = access_token || @token_vault.access_token(user_id: conn.user_id, now: now)\n    book!(spec, pool, broadcast, now)\n",
    "    book!(spec, pool, broadcast, now)\n    token = access_token || @token_vault.access_token(user_id: conn.user_id, now: now)\n", [ LEDGER ] ],
  [ "割り当て超過の印を付けない", GW,
    "    QuotaLedger.mark_exhausted!(quota_date: UsageCalendar.quota_date(now)) if error.is_a?(YouTubeErrors::QuotaExceeded)\n", "", [ LEDGER, FAKE_GATEWAY ] ],
  [ "割り当て超過の印を、UTC の日付に付ける（割り当て日は太平洋時間）", GW,
    "QuotaLedger.mark_exhausted!(quota_date: UsageCalendar.quota_date(now))", "QuotaLedger.mark_exhausted!(quota_date: now.utc.to_date)", [ LEDGER ] ],
  [ "共通枠の割り当て日を、UTC の日付にする", GW,
    "quota_date: UsageCalendar.quota_date(now), result: BOOKED_RESULT", "quota_date: now.utc.to_date, result: BOOKED_RESULT", [ LEDGER ] ],
  [ "ensure_stream が、保存した識別子の確認の結果を使わず、常に作成する", GW,
    "    existing || create_stream(conn, broadcast)\n", "    create_stream(conn, broadcast)\n", [ GATEWAY ] ],
  [ "ストリームの確認の NotFound を握りつぶさず、そのまま伝える（無効なら作成、にならない）", GW,
    "  rescue YouTubeErrors::NotFound\n    nil\n  end\n\n  def create_stream", "  end\n\n  def create_stream", [ GATEWAY ] ],
  [ "呼び出し側のトランザクションの内側の検査を外す", GW,
    "    raise InsideTransaction.new(kind) if inside\n", "", [ LEDGER, COMMIT ] ],
  [ "401 でも、メモリ上のアクセストークンを捨てない", GW,
    "    @token_vault.forget_access_token(user_id: conn.user_id) if response.status == UNAUTHORIZED_STATUS && conn\n", "", [ LEDGER ] ],
  [ "壊れた gzip（Zlib::Error）を受け止めない", GW,
    "  rescue Zlib::Error\n    raise YouTubeErrors::UnexpectedResponse.new(call_kind: spec.kind, detail: :invalid_encoding)\n", "", [ ERRORS_VIA_GATEWAY ] ],
  [ "タイムアウトを Transient にする", GW,
    "    when :timeout then YouTubeErrors::Timeout.new(call_kind: kind, detail: :timeout)", "    when :timeout then YouTubeErrors::Transient.new(call_kind: kind, detail: :timeout)",
    [ ERRORS_VIA_GATEWAY ] ],
  [ "接続と配信のアカウントの一致を検査しない", GW,
    "      raise ArgumentError, \"broadcast does not belong to the account of the connection\" unless broadcast.user_id == conn.user_id\n", "", [ LEDGER ] ],
  [ "リダイレクト（3xx）を成功にする", GW, "  SUCCESS_STATUSES = (200..299)", "  SUCCESS_STATUSES = (200..399)", [ GATEWAY ] ],
  [ "実時計（Time.now）を読む", GW, "    now = @clock.call\n", "    now = Time.now\n", [ SOURCES ] ],
  [ "標準出力へ書く", GW, "    raise ArgumentError, \"clock must return a Time\" unless now.is_a?(Time)\n",
    "    puts now\n    raise ArgumentError, \"clock must return a Time\" unless now.is_a?(Time)\n", [ SOURCES ] ],
  [ "ログへ、配信のタイトルを出す", GW, "      \"call=\#{kind}\",\n", "      \"call=\#{kind}\",\n      \"title=\#{broadcast.pending_title}\",\n", [ SOURCES ] ],
  [ "ログのタグに、日本語の文字列を直書きする", GW, "LOG_TAG = \"[youtube_gateway]\".freeze", "LOG_TAG = \"[YouTube窓口]\".freeze", [ SOURCES ] ],

  # --- 呼び出しの表（枠・単価） ---
  [ "状態確認が、準備・確認枠しか使えない（終了時の状態確認が、終了・清算枠から支出できない）", CALLS_TABLE,
    "kind: :fetch_status, api_method: \"liveBroadcasts.list\", cost_key: \"list\", http_method: :get, path: \"liveBroadcasts\", buckets: %i[ prep settle ]",
    "kind: :fetch_status, api_method: \"liveBroadcasts.list\", cost_key: \"list\", http_method: :get, path: \"liveBroadcasts\", buckets: %i[ prep ]", [ CALLS, GATEWAY ] ],
  [ "紐づけが、終了・清算枠からも支出できる（準備の呼び出しが、終了・清算枠を取り崩せる）", CALLS_TABLE,
    "kind: :bind, api_method: \"liveBroadcasts.bind\", cost_key: \"bind\", http_method: :post, path: \"liveBroadcasts/bind\", buckets: %i[ prep ]",
    "kind: :bind, api_method: \"liveBroadcasts.bind\", cost_key: \"bind\", http_method: :post, path: \"liveBroadcasts/bind\", buckets: %i[ prep settle ]", [ CALLS ] ],
  [ "削除の単価を、一覧取得の単価（1）にする", CALLS_TABLE, "cost_key: \"delete\"", "cost_key: \"list\"", [ CALLS, GATEWAY ] ],

  # --- 要求・応答 ---
  [ "配信の作成の part から contentDetails を落とす", REQUESTS, "    BROADCAST_PARTS = \"snippet,contentDetails,status\".freeze", "    BROADCAST_PARTS = \"snippet,status\".freeze", [ GATEWAY ] ],
  [ "自動停止を明示しない（false にする）", REQUESTS, "            \"enableAutoStop\" => true,", "            \"enableAutoStop\" => false,", [ GATEWAY ] ],
  [ "モニターストリームを有効にする", REQUESTS, "\"monitorStream\" => { \"enableMonitorStream\" => false }", "\"monitorStream\" => { \"enableMonitorStream\" => true }", [ GATEWAY ] ],
  [ "取り込み先に、平文の RTMP（ingestionAddress）を使う", RESPONSES, "        url = ingestion[\"rtmpsIngestionAddress\"]", "        url = ingestion[\"ingestionAddress\"]", [ GATEWAY ] ],
  [ "返す前の取り込み先の検証を省く", RESPONSES, "ingest_url: IngestDestination.validate!(url, environment: environment)", "ingest_url: url", [ GATEWAY, SERVICES ] ],
  [ "配信キーの形の検査を緩める（空白・改行を通す）", RESPONSES, "    STREAM_KEY_PATTERN = /\\A[\\x21-\\x7E]{1,256}\\z/", "    STREAM_KEY_PATTERN = /\\A.{1,256}\\z/m", [ GATEWAY ] ],
  [ "応答の識別子と要求の識別子の一致を検査しない", RESPONSES, "        raise unexpected(kind, :id_mismatch) unless id!(actual, kind) == requested", "        id!(actual, kind)", [ GATEWAY ] ],
  [ "ストリームの健全性: bad 以外（noData を含む）をすべて警告にする", HEALTH_FILE, "    status == BAD_STATUS || !error_types.empty?", "    status != \"good\" || !error_types.empty?", [ VALUES, GATEWAY ] ],

  # --- エラーの分類 ---
  [ "concurrentBroadcastsExceedLimit を RateLimited にする（再試行の対象にしてしまう）", ERRORS_FILE,
    "    \"concurrentBroadcastsExceedLimit\" => BroadcastLimitExceeded,", "    \"concurrentBroadcastsExceedLimit\" => RateLimited,", [ ERRORS ] ],
  [ "404 を NotFound にしない", ERRORS_FILE, "      return NotFound if status == NOT_FOUND_STATUS", "      return UnexpectedResponse if status == NOT_FOUND_STATUS", [ ERRORS ] ],
  [ "先行配信の清算でも、権限の応答を認可失効にする", ERRORS_FILE,
    "      context == :prior_settlement ? PRIOR_SETTLEMENT_DISPOSITION : DISPOSITION", "      DISPOSITION", [ ERRORS ] ],
  [ "符号の形でない reason を、そのまま記録する", ERRORS_FILE,
    "      reason.is_a?(String) && SAFE_CODE.match?(reason) ? reason : UNRECOGNIZED", "      reason", [ ERRORS ] ],
  [ "NotAllowed（invalidTransition など）を、すでに終端（清算済み）として扱う", ERRORS_FILE,
    "    DISPOSITION = Disposition.new(connection_state: nil, end_reason: ER::PREPARE_FAILED, retryable: false, settlement_result: :not_transitionable)",
    "    DISPOSITION = Disposition.new(connection_state: nil, end_reason: ER::PREPARE_FAILED, retryable: false, settlement_result: :already_terminal)", [ ERRORS ] ],

  # --- 取り込み先の検証 ---
  [ "平文の RTMP（スキーム）を拒否しない", INGEST_FILE, "      invalid!(:scheme_not_allowed) unless url.start_with?(SCHEME_PREFIX)\n", "", [ INGEST ] ],
  [ "ポートを検査しない", INGEST_FILE, "      invalid!(:port_not_allowed) unless colon == \":\" && port == target.port.to_s", "      invalid!(:port_not_allowed) unless colon == \":\"", [ INGEST ] ],
  [ "ユーザー情報を拒否しない", INGEST_FILE, "      invalid!(:userinfo_not_allowed) if authority.include?(\"@\")\n", "", [ INGEST ] ],
  [ "疑似の取り込み口を、本番でも許可する", INGEST_FILE, " if fake.fetch(:allowed_environments).include?(environment.name.to_s)", "", [ INGEST ] ],
  [ "アプリ名の形（配信キーを混ぜた形の拒否）を緩める", INGEST_FILE, "  APP_NAME = /\\A[A-Za-z0-9_-]{1,64}\\z/", "  APP_NAME = /\\A.*\\z/m", [ INGEST ] ],

  # --- TokenVault ---
  [ "アクセストークンの更新の余裕（60 秒）を 0 にする", VAULT_FILE, "  REFRESH_MARGIN_SECONDS = 60", "  REFRESH_MARGIN_SECONDS = 0", [ VAULT ] ],
  [ "待っているあいだの更新を使わない（同時の更新が重複する）", VAULT_FILE,
    "      @cache.fetch(user, now: now, margin_seconds: REFRESH_MARGIN_SECONDS) || refresh!(user, now)\n", "      refresh!(user, now)\n", [ VAULT_CONCURRENCY ] ],
  [ "アカウントごとの排他を外す（同時の更新が重複する）", VAULT_FILE,
    "    @cache.synchronize(user) do\n      # 待っているあいだに、別のスレッドが更新していれば、それを使う（Google への更新を 1 回にまとめる）\n      @cache.fetch(user, now: now, margin_seconds: REFRESH_MARGIN_SECONDS) || refresh!(user, now)\n    end\n",
    "    @cache.fetch(user, now: now, margin_seconds: REFRESH_MARGIN_SECONDS) || refresh!(user, now)\n", [ VAULT_CONCURRENCY ] ],
  [ "暗号文を、アカウントに結びつけない", VAULT_FILE, "    \"\#{PURPOSE}:\#{user}\"", "    PURPOSE", [ VAULT ] ],
  [ "暗号鍵の長さの検査を緩める", VAULT_FILE, "  KEY_FORMAT = /\\A\\h{64}\\z/", "  KEY_FORMAT = /\\A\\h+\\z/", [ VAULT, SERVICES ] ],
  [ "暗号を、認証つきでない方式（CBC）にする", VAULT_FILE, "  CIPHER = \"aes-256-gcm\".freeze", "  CIPHER = \"aes-256-cbc\".freeze", [ VAULT ] ],
  [ "恒久的な失敗で、接続状態を revoked にしない", VAULT_FILE, "    connection.mark_revoked!\n", "", [ VAULT, VAULT_CONCURRENCY ] ],
  [ "一時的な失敗でも、接続状態を revoked にする", VAULT_FILE,
    "    # 一時的な失敗・想定外の応答: 状態を変えない\n    log_failure(user, error)\n", "    connection.mark_revoked!\n    log_failure(user, error)\n", [ VAULT ] ],
  [ "失効した接続でも、Google へ更新を要求する", VAULT_FILE, "    raise revoked_connection(user) if connection.state == Contract::YoutubeConnectionState::REVOKED\n", "", [ VAULT ] ],
  [ "接続の解除で、保存したトークンを削除しない", VAULT_FILE, "        YoutubeConnection.owned_by(user).where(id: connection.id).delete_all\n", "        nil\n", [ VAULT ] ],
  [ "保存で、状態まで置き換える（接続の成立の扱いを、先取りする）", VAULT_FILE,
    "          connection.update!(refresh_token_ciphertext: ciphertext)", "          connection.update!(refresh_token_ciphertext: ciphertext, state: Contract::YoutubeConnectionState::CONNECTED)", [ VAULT ] ],
  [ "保存で、メモリ上のアクセストークンを捨てない", VAULT_FILE, "      persist!(user, encrypt(token, user), now)\n      @cache.delete(user)\n", "      persist!(user, encrypt(token, user), now)\n", [ VAULT ] ],
  [ "キャッシュの期限の境界（ちょうど 60 秒前）を、まだ有効とみなす", CACHE_FILE, "        next entry.token if now < entry.expires_at - margin_seconds", "        next entry.token if now <= entry.expires_at - margin_seconds", [ CACHE, VAULT ] ],
  [ "5xx の invalid_grant を、恒久の失効として扱う", TOKEN_CLIENT_FILE, "    error = if revoked_code && code == revoked_code && status < SERVER_ERROR_FROM", "    error = if revoked_code && code == revoked_code", [ TOKEN_CLIENT ] ],
  [ "トークンエンドポイントの壊れた gzip を受け止めない", TOKEN_CLIENT_FILE,
    "  rescue Zlib::Error\n    raise logged(YouTubeErrors::UnexpectedResponse.new(call_kind: call_kind, detail: INVALID_ENCODING))\n", "", [ TOKEN_CLIENT ] ],

  # --- 接続の状態の遷移 ---
  [ "状態の遷移が、すでにその状態でも更新済みとする", CONNECTION_FILE, "    changed = owned_row.where.not(state: target).update_all(state: target) == 1", "    changed = owned_row.update_all(state: target) == 1", [ CONNECTION ] ],
  [ "ストリームの識別子の破棄が、識別子が無くても更新済みとする", CONNECTION_FILE,
    "    discarded = owned_row.where.not(youtube_stream_id: nil).update_all(youtube_stream_id: nil, stream_verified_at: nil) == 1",
    "    discarded = owned_row.update_all(youtube_stream_id: nil, stream_verified_at: nil) == 1", [ CONNECTION ] ],

  # --- 疑似 ---
  [ "疑似の配信が、ちょうど 5 秒ではライブにならない（境界）", FAKE_API_FILE, "now >= broadcast.fetch(:bound_at) + @live_after_seconds", "now > broadcast.fetch(:bound_at) + @live_after_seconds", [ FAKE_API ] ],
  [ "疑似が、part に contentDetails が無くても自動開始を受け付ける", FAKE_API_FILE,
    "      details = parts.include?(\"contentDetails\") && json[\"contentDetails\"].is_a?(Hash) ? json[\"contentDetails\"] : {}",
    "      details = json[\"contentDetails\"].is_a?(Hash) ? json[\"contentDetails\"] : {}", [ FAKE_API ] ],
  [ "疑似が、認可ヘッダを検査しない", FAKE_API_FILE, "      value.is_a?(String) && value.start_with?(BEARER_PREFIX) && !value.delete_prefix(BEARER_PREFIX).strip.empty?", "      true", [ FAKE_API ] ],
  [ "疑似が、未知のパスを 404 にする（実装の誤りが、清算済みと取り違えられる）", FAKE_API_FILE, "      else error_response(400, \"unknownEndpoint\")", "      else error_response(404, \"unknownEndpoint\")", [ FAKE_API ] ],
  [ "注入した失敗が、消費されず続く", FAKE_API_FILE, "      injection.remaining -= 1", "      injection.remaining -= 0", [ FAKE_API ] ],
  [ "疑似の窓口が、本番でも構築できる", FAKE_GATEWAY_FILE, "    FakeServices.verify_environment!(environment)\n", "", [ FAKE_GATEWAY ] ],
  [ "本番で疑似を選ぶ", SERVICES_FILE, "      when :live then live(environment, env, logger)", "      when :live then fake(environment, env, logger)", [ SERVICES ] ]
].freeze

# 変異の前に、使うスペックが、複製（変異なし）で通ることを確かめる（通らないスペックでの「検出」は、検出ではない）
used_specs = MUTATIONS.flat_map(&:last).uniq
puts "複製: #{COPY}"
puts "基準: 変異なしの複製で、#{used_specs.size} 個のスペックのファイルを実行する"
summary, load_error, output = run_rspec(used_specs)
puts "基準: #{summary}"
if load_error || !summary.match?(/ 0 failures/)
  puts output.lines.last(40).join
  warn "FAIL 変異なしの複製で、スペックが通りません。変異の検出は、確かめられません"
  exit 1
end

detected = 0
problems = []
MUTATIONS.each_with_index do |(description, file, from, to, specs), index|
  path = File.join(COPY, file)
  original = File.read(path, encoding: "UTF-8")
  count = original.scan(from).size
  unless count == 1
    problems << "適用できない変異（置換前が #{count} 回現れる）: #{description}（#{file}）"
    puts format("%<number>2d. SKIP 適用できない（置換前が %<count>d 回）: %<text>s", number: index + 1, count: count, text: description)
    next
  end

  begin
    File.write(path, original.sub(from) { to })
    result, load_error, = run_rspec(specs)
  ensure
    File.write(path, original)
  end

  caught = load_error || !result.match?(/ 0 failures/)
  if caught
    detected += 1
    puts format("%<number>2d. 検出 %<text>s  [%<result>s]", number: index + 1, text: description, result: result)
  else
    problems << "見逃し: #{description}（#{file}。スペック: #{specs.join(', ')}）"
    puts format("%<number>2d. 見逃し %<text>s  [%<result>s]", number: index + 1, text: description, result: result)
  end
end

puts "\n変異 #{MUTATIONS.size} 件のうち、検出 #{detected} 件"
if problems.empty?
  puts "すべての変異を検出しました"
  exit 0
end
problems.each { |message| puts "FAIL #{message}" }
exit 1
