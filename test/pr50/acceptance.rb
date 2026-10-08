# frozen_string_literal: true

# 受け入れの確認（黒箱）。issue #10「YouTube 連携の窓口: TokenVault・YouTubeGateway（実物・疑似）・エラー対応・取り込み先の検証」の
# 受け入れ条件を、公開の API だけで確かめる。RSpec とは別の実行で、結果は、SQL（台帳・接続の行）と WebMock の記録で、独立に確かめる。
# 実際の Google・YouTube は呼ばない（WebMock で、すべての通信を差し替える。差し替えていない通信は、失敗にする）。
#
# 使い方（run_all.sh が実行する）: scratch の DB（bl_test_...）を相手に、backend のコンテナの中で実行する。
#   scripts/dc.sh exec -T backend bundle exec ruby - < <このディレクトリ>/acceptance.rb   （RAILS_ENV=test と DATABASE_URL は、呼び出し側が与える）
# 終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 前提を満たさない
ENV["RAILS_ENV"] = "test"
require "/app/config/environment"
require "webmock"
require "securerandom"
require "stringio"

database = ActiveRecord::Base.connection_db_config.database
unless database.match?(/\Abl_test_[a-z0-9_]+\z/)
  warn "FAIL 接続先（#{database}）が、テスト用の DB（bl_test_...）ではありません"
  exit 2
end

# 結果の記録
class Reporter
  attr_reader :failures

  def initialize
    @failures = 0
    @passes = 0
  end

  def check(label, condition, detail = nil)
    if condition
      @passes += 1
      puts "ok   #{label}"
    else
      @failures += 1
      puts "FAIL #{label}#{" (#{detail})" if detail}"
    end
  end

  def section(title)
    puts "\n-- #{title}"
  end

  # ブロックが error_class を投げること。投げた例外を返す（投げなければ nil）
  def raises(label, error_class)
    yield
    check(label, false, "no exception")
    nil
  rescue error_class => e
    check(label, true)
    e
  rescue StandardError => e
    check(label, false, "#{e.class}")
    nil
  end

  def finish
    puts "\n#{@passes} 件成功、#{@failures} 件失敗"
    @failures.zero? ? 0 : 1
  end
end

class Acceptance
  include WebMock::API

  API = "https://www.googleapis.com/youtube/v3"
  TOKEN_URL = "https://oauth2.googleapis.com/token"
  REVOKE_URL = "https://oauth2.googleapis.com/revoke"
  REFRESH_TOKEN = "1//dummy-acceptance-refresh-token-must-not-appear"
  ACCESS_TOKEN = "ya29.dummy-acceptance-access-token-must-not-appear"
  STREAM_KEY = "dummy-acceptance-stream-key-must-not-appear"
  TITLE = "dummy-acceptance-title-must-not-appear"
  BROADCAST_ID = "dummyAcceptanceBc1"
  STREAM_ID = "dummy-acceptance-stream-1"

  def initialize(reporter)
    @r = reporter
    @key = SecureRandom.hex(32)
    # 太平洋時間の正午ごろ。割り当て日は、実行ごとに変える（同じ DB で繰り返し実行しても、前回の台帳・超過の印の影響を受けないため）
    @now = Time.utc(2032, 5, 17, 19, 0, 0) + (SecureRandom.random_number(3000) * 86_400)
    @quota_date = UsageCalendar.quota_date(@now)
    @logs = StringIO.new
    Rails.logger.broadcast_to(::Logger.new(@logs, level: ::Logger::DEBUG))
  end

  def run
    WebMock.enable!
    WebMock.disable_net_connect!
    token_vault_checks
    gateway_checks
    ingest_checks
    error_classification_checks
    fake_checks
    production_checks
    secrets_in_logs_check
  end

  private

  # --- 部品 ---

  def sql(query, *binds)
    ActiveRecord::Base.connection.select_rows(ActiveRecord::Base.sanitize_sql_array([ query, *binds ]))
  end

  def new_user
    User.create!(google_sub: "dummy-acceptance-sub-#{SecureRandom.hex(8)}", last_login_at: Time.current)
  end

  def token_client
    GoogleTokenClient.new(
      client_id: "dummy-client-id.apps.googleusercontent.com", client_secret: "dummy-client-secret", http: ExternalHttp.new,
      endpoints: ExternalServices.config.fetch(:google_oidc)
    )
  end

  def vault(key: @key, cache: TokenVault::AccessTokenCache.new)
    TokenVault.new(key: key, token_client: token_client, cache: cache)
  end

  def stub_token(status: 200, body: { "access_token" => ACCESS_TOKEN, "expires_in" => 3600 })
    stub_request(:post, TOKEN_URL).to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def requests_to(method, url)
    WebMock::RequestRegistry.instance.times_executed(WebMock::RequestPattern.new(method, url))
  end

  # 台帳へ予約済みの配信（アカウントごと）
  def reserved_broadcast(user, daily_total: 10_000)
    usage = DailyUsage.create!(user: user, usage_date: @quota_date)
    broadcast = Broadcast.create!(
      user: user, daily_usage: usage, state: "reserved", usage_date: @quota_date, quota_date: @quota_date, pending_title: TITLE,
      privacy_status: "unlisted", made_for_kids: false, accepted_at: @now
    )
    raise "the reservation was refused" unless QuotaLedger.reserve!(broadcast, quota_date: @quota_date, daily_total: daily_total)

    broadcast
  end

  def connected_account
    user = new_user
    token_vault = vault
    token_vault.store(user_id: user.id, refresh_token: REFRESH_TOKEN, now: @now)
    stub_token
    [ user, YoutubeConnection.find_by!(user_id: user.id), token_vault ]
  end

  def gateway(token_vault, environment: AppEnvironment.new("production"))
    YouTubeGateway.new(
      http: ExternalHttp.new, token_vault: token_vault, api_base: API, stream_title: "Browser Live", environment: environment, clock: -> { @now }
    )
  end

  def ledger_rows(broadcast)
    sql("SELECT method, units, bucket, result FROM quota_entries WHERE broadcast_id = ? ORDER BY called_at, method", broadcast.id)
  end

  def json(body, status: 200)
    { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  def error_json(status, reason)
    json({ "error" => { "code" => status, "message" => "dummy-message-must-not-appear", "errors" => [ { "domain" => "youtube.liveBroadcast", "reason" => reason } ] } }, status: status)
  end

  def stream_resource(rtmps: "rtmps://a.rtmps.youtube.com:443/live2")
    {
      "id" => STREAM_ID,
      "cdn" => { "ingestionInfo" => { "streamName" => STREAM_KEY, "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2", "rtmpsIngestionAddress" => rtmps } },
      "status" => { "streamStatus" => "ready" }
    }
  end

  # --- TokenVault ---

  def token_vault_checks
    @r.section("TokenVault")
    user = new_user
    token_vault = vault
    record = token_vault.store(user_id: user.id, refresh_token: REFRESH_TOKEN, now: @now)

    stored = sql("SELECT refresh_token_ciphertext FROM youtube_connections WHERE user_id = ?", user.id).flatten.first
    @ciphertexts = [ stored ]
    @r.check("更新トークンは暗号文で保存される（平文を含まない。暗号文 -- IV -- 認証タグの 3 つ組）", !stored.include?(REFRESH_TOKEN) && stored.split("--").size == 3)
    @r.check("保存した接続は、接続済みで、アクセストークンの列を持たない", record.state == "connected" && YoutubeConnection.column_names.none? { |name| name.include?("access") })

    [ nil, "", "short", "a" * 63, "a" * 65, "g" * 64 ].each do |bad|
      @r.raises("暗号鍵 #{bad.inspect[0, 12]} は InvalidKey", TokenVault::InvalidKey) { vault(key: bad) }
    end
    @r.raises("鍵が違えば復号できない（Undecryptable）", TokenVault::Undecryptable) { vault(key: SecureRandom.hex(32)).access_token(user_id: user.id, now: @now) }
    other = new_user
    YoutubeConnection.create!(user: other, state: "connected", refresh_token_ciphertext: stored, connected_at: @now, last_verified_at: @now)
    @r.raises("暗号文は、アカウントに結び付く（他のアカウントの行へ写しても復号できない。Undecryptable）", TokenVault::Undecryptable) do
      token_vault.access_token(user_id: other.id, now: @now)
    end

    stub_token
    first = token_vault.access_token(user_id: user.id, now: @now)
    token_vault.access_token(user_id: user.id, now: @now + 3539)
    @r.check("有効期限内（3539 秒後）は、メモリ上で再利用する（Google への通信 1 回）", first == ACCESS_TOKEN && requests_to(:post, TOKEN_URL) == 1)
    token_vault.access_token(user_id: user.id, now: @now + 3540)
    @r.check("期限の 60 秒前（3540 秒後）に更新する（通信 2 回）", requests_to(:post, TOKEN_URL) == 2)

    WebMock.reset!
    stub_token
    shared = TokenVault::AccessTokenCache.new
    threads = Array.new(8) { Thread.new { ActiveRecord::Base.connection_pool.with_connection { vault(cache: shared).access_token(user_id: user.id, now: @now) } } }
    tokens = threads.map(&:value)
    @r.check("同時に 8 本が取得しても、Google への通信は 1 回（重複排除）", tokens.uniq.size == 1 && requests_to(:post, TOKEN_URL) == 1)

    WebMock.reset!
    stub_token(status: 503, body: { "error" => "backend_error" })
    @r.raises("一時的な失敗（503）は TokenTemporarilyUnavailable", YouTubeErrors::TokenTemporarilyUnavailable) { vault.access_token(user_id: user.id, now: @now) }
    @r.check("一時的な失敗では、接続状態を変えない", sql("SELECT state FROM youtube_connections WHERE user_id = ?", user.id).flatten.first == "connected")

    WebMock.reset!
    stub_token(status: 400, body: { "error" => "invalid_grant" })
    @r.raises("恒久的な失敗（invalid_grant）は TokenRevoked", YouTubeErrors::TokenRevoked) { vault.access_token(user_id: user.id, now: @now) }
    @r.check("恒久的な失敗では、接続状態が revoked になる", sql("SELECT state FROM youtube_connections WHERE user_id = ?", user.id).flatten.first == "revoked")
    before = requests_to(:post, TOKEN_URL)
    @r.raises("失効した接続は、Google を呼ばずに TokenRevoked", YouTubeErrors::TokenRevoked) { vault.access_token(user_id: user.id, now: @now) }
    @r.check("失効した接続の取得で、通信しない", requests_to(:post, TOKEN_URL) == before)

    WebMock.reset!
    revoke_user = new_user
    revoke_vault = vault
    revoke_vault.store(user_id: revoke_user.id, refresh_token: REFRESH_TOKEN, now: @now)
    stub_request(:post, REVOKE_URL).with(body: { "token" => REFRESH_TOKEN }).to_return(status: 200, body: "")
    result = revoke_vault.revoke(user_id: revoke_user.id)
    @r.check("失効エンドポイントへ更新トークンを送る。結果は revoked。保存したトークンを削除する",
             result.outcome == :revoked && sql("SELECT count(*) FROM youtube_connections WHERE user_id = ?", revoke_user.id).flatten.first.to_i.zero?)

    failing_user = new_user
    failing_vault = vault
    failing_vault.store(user_id: failing_user.id, refresh_token: REFRESH_TOKEN, now: @now)
    WebMock.reset!
    stub_request(:post, REVOKE_URL).to_return(status: 500, body: "")
    failed = failing_vault.revoke(user_id: failing_user.id)
    @r.check("失効の失敗でも、保存したトークンを削除し、結果（failed）を返す",
             failed.outcome == :failed && sql("SELECT count(*) FROM youtube_connections WHERE user_id = ?", failing_user.id).flatten.first.to_i.zero?)
    WebMock.reset!
  end

  # --- YouTubeGateway（実物。WebMock） ---

  def gateway_checks
    @r.section("YouTubeGateway（実物）")
    user, connection, token_vault = connected_account
    broadcast = reserved_broadcast(user)
    window = gateway(token_vault)
    captured = []

    stub_request(:post, "#{API}/liveBroadcasts").with(query: hash_including({})) { |request| captured << request }
                                                  .to_return(json({ "id" => BROADCAST_ID, "status" => { "lifeCycleStatus" => "created" } }))
    id = window.insert_broadcast(
      connection, { title: TITLE, privacy_status: "unlisted", made_for_kids: false, scheduled_start_time: YouTubeGateway.scheduled_start_time(@now) }, broadcast: broadcast
    )
    request = captured.first
    body = JSON.parse(request.body)
    @r.check("配信の作成: part=snippet,contentDetails,status", request.uri.query_values["part"] == "snippet,contentDetails,status")
    @r.check("配信の作成: 自動開始・自動停止・モニター無効・開始予定時刻（1 分後）",
             body.dig("contentDetails", "enableAutoStart") == true && body.dig("contentDetails", "enableAutoStop") == true &&
             body.dig("contentDetails", "monitorStream", "enableMonitorStream") == false && body.dig("snippet", "scheduledStartTime") == (@now + 60).utc.iso8601)
    @r.check("配信の作成: 認可ヘッダは Bearer。配信の識別子を返す", request.headers["Authorization"] == "Bearer #{ACCESS_TOKEN}" && id == BROADCAST_ID)

    stream_captured = []
    stub_request(:post, "#{API}/liveStreams").with(query: hash_including({})) { |req| stream_captured << req }.to_return(json(stream_resource))
    info = window.ensure_stream(connection, broadcast: broadcast)
    stream_body = JSON.parse(stream_captured.first.body)
    @r.check("ストリームの作成: part=snippet,cdn,contentDetails,status・rtmp・variable・再利用可能",
             stream_captured.first.uri.query_values["part"] == "snippet,cdn,contentDetails,status" && stream_body.dig("cdn", "ingestionType") == "rtmp" &&
             stream_body.dig("cdn", "resolution") == "variable" && stream_body.dig("cdn", "frameRate") == "variable" && stream_body.dig("contentDetails", "isReusable") == true)
    @r.check("取り込み先は rtmpsIngestionAddress。配信キーは inspect に出ない", info.ingest_url == "rtmps://a.rtmps.youtube.com:443/live2" && !info.inspect.include?(STREAM_KEY))

    connection.update!(youtube_stream_id: info.stream_id)
    stub_request(:get, "#{API}/liveStreams").with(query: { "part" => "id,cdn,status", "id" => STREAM_ID }).to_return(json({ "items" => [ stream_resource ] }))
    reused = window.ensure_stream(connection, broadcast: broadcast)
    @r.check("保存した識別子で確認し、有効なら作成しない（created: false）", reused.created == false)
    stub_request(:get, "#{API}/liveStreams").with(query: { "part" => "id,cdn,status", "id" => STREAM_ID }).to_return(json({ "items" => [] }))
    stub_request(:post, "#{API}/liveStreams").with(query: hash_including({})).to_return(json(stream_resource))
    @r.check("空の items も、404 も無効として扱い、作成へ進む", window.ensure_stream(connection, broadcast: broadcast).created == true)

    stub_request(:post, "#{API}/liveBroadcasts/bind").with(query: hash_including({})).to_return(json({ "id" => BROADCAST_ID }))
    stub_request(:get, "#{API}/liveBroadcasts").with(query: hash_including({})).to_return(json({ "items" => [ { "id" => BROADCAST_ID, "status" => { "lifeCycleStatus" => "live" } } ] }))
    stub_request(:post, "#{API}/liveBroadcasts/transition").with(query: hash_including({})).to_return(json({ "id" => BROADCAST_ID }))
    stub_request(:delete, "#{API}/liveBroadcasts").with(query: hash_including({})).to_return(status: 204)
    window.bind(connection, BROADCAST_ID, STREAM_ID, broadcast: broadcast)
    status = window.fetch_status(connection, BROADCAST_ID, broadcast: broadcast, bucket: :prep)
    window.complete(connection, BROADCAST_ID, broadcast: broadcast, bucket: :settle)
    window.delete(connection, BROADCAST_ID, broadcast: broadcast, bucket: :settle)
    @r.check("状態の確認は YouTubeStatus（live）", status.live?)

    rows = ledger_rows(broadcast)
    expected_units = [
      [ "liveBroadcasts.insert", 50 ], [ "liveStreams.insert", 50 ], [ "liveStreams.insert", 50 ], [ "liveStreams.list", 1 ], [ "liveStreams.list", 1 ],
      [ "liveBroadcasts.bind", 50 ], [ "liveBroadcasts.list", 1 ], [ "liveBroadcasts.transition", 50 ], [ "liveBroadcasts.delete", 50 ]
    ].sort
    @r.check("台帳の単価: 配信の作成 50・ストリームの作成 50 ×2・ストリームの確認 1 ×2・紐づけ 50・状態の確認 1・遷移 50・削除 50",
             rows.map { |api_method, units, _, _| [ api_method, units.to_i ] }.sort == expected_units,
             rows.inspect)
    @r.check("枠: 終了・清算枠は遷移と削除だけ。ほかは準備・確認枠", rows.select { |_, _, bucket, _| bucket == "settle" }.map(&:first).sort == %w[ liveBroadcasts.delete liveBroadcasts.transition ])
    totals = sql("SELECT used_units, reserved_units FROM quota_days WHERE quota_date = ?", @quota_date).first.map(&:to_i)
    @r.check("台帳の使用済みは明細の合計。予約中はその分だけ減る", totals.first == rows.sum { |_, units, _, _| units.to_i } && totals.last == 550 - totals.first)

    @r.check("明細にトークン・配信キー・タイトルを残さない", rows.flatten.none? { |value| [ ACCESS_TOKEN, STREAM_KEY, TITLE ].any? { |secret| value.to_s.include?(secret) } })

    # 枠が足りない: HTTP を呼ばない
    drain = reserved_broadcast(new_user)
    QuotaLedger.spend!(drain, method: "liveBroadcasts.list", units: 340, bucket: :prep, result: "ok", now: @now)
    token_vault.store(user_id: drain.user_id, refresh_token: REFRESH_TOKEN, now: @now)
    drain_connection = YoutubeConnection.find_by!(user_id: drain.user_id)
    bind_url = "#{API}/liveBroadcasts/bind?id=#{BROADCAST_ID}&part=id,contentDetails&streamId=#{STREAM_ID}"
    before = requests_to(:post, bind_url)
    @r.check("前提: 先の紐づけの要求が、記録の照合で見つかる（照合が空振りしていない）", before == 1, before)
    @r.raises("準備・確認枠が足りなければ、HTTP を呼ばず QuotaInsufficient", YouTubeErrors::QuotaInsufficient) do
      window.bind(drain_connection, BROADCAST_ID, STREAM_ID, broadcast: drain)
    end
    @r.check("拒否された呼び出しは、YouTube へ届いていない", requests_to(:post, bind_url) == before)

    # 割り当て超過
    stub_request(:post, "#{API}/liveBroadcasts/bind").with(query: hash_including({})).to_return(error_json(403, "quotaExceeded"))
    @r.raises("quotaExceeded は QuotaExceeded", YouTubeErrors::QuotaExceeded) { window.bind(connection, BROADCAST_ID, STREAM_ID, broadcast: broadcast) }
    @r.check("割り当て超過の印が台帳に付く（その割り当て日）", sql("SELECT exhausted FROM quota_days WHERE quota_date = ?", @quota_date).flatten.first == true)

    # トランザクションの内側
    @r.raises("呼び出し側のトランザクションの内側では呼べない（InsideTransaction）", YouTubeGateway::InsideTransaction) do
      ApplicationRecord.transaction { window.fetch_status(connection, BROADCAST_ID, broadcast: broadcast, bucket: :prep) }
    end

    # 接続時の確認
    stub_request(:get, "#{API}/channels").with(query: hash_including({})).to_return(json({ "items" => [ { "id" => "c", "snippet" => { "title" => "dummy-channel" } } ] }))
    stub_request(:get, "#{API}/liveBroadcasts").with(query: hash_including({ "mine" => "true" })).to_return(error_json(403, "liveStreamingNotEnabled"))
    probe = window.probe_channel(connection)
    @r.check("配信の一覧取得が liveStreamingNotEnabled を返せば、live_not_enabled", probe.outcome == "live_not_enabled")
    common = sql("SELECT count(*), coalesce(sum(units), 0) FROM quota_entries WHERE bucket = 'common' AND quota_date = ? AND broadcast_id IS NULL", @quota_date).first.map(&:to_i)
    @r.check("接続時の確認（チャンネルの取得・配信の一覧取得）は、配信に属さない共通枠から、各 1 ユニット（2 件・2 ユニット）", common == [ 2, 2 ], common.inspect)
    WebMock.reset!
  end

  # --- 取り込み先の検証 ---

  def ingest_checks
    @r.section("IngestDestination")
    production = AppEnvironment.new("production")
    ok = [ "rtmps://a.rtmps.youtube.com:443/live2", "rtmps://b.rtmps.youtube.com:443/live2" ]
    ng = [
      "rtmp://a.rtmps.youtube.com:443/live2", "rtmps://evil.example:443/live2", "rtmps://a.rtmps.youtube.com:1935/live2",
      "rtmps://a.rtmps.youtube.com:443/live2?backup=1", "rtmps://user:pass@a.rtmps.youtube.com:443/live2", "rtmps://fake-ingest:1935/live2",
      "rtmps://a.rtmps.youtube.com/live2", "https://a.rtmps.youtube.com:443/live2"
    ]
    @r.check("許可する取り込み先（契約 rtmps_ingest の 2 ホスト・443）", ok.all? { |url| IngestDestination.validate!(url, environment: production) == url })
    ng.each do |url|
      @r.raises("拒否する取り込み先 #{url[0, 40]}", IngestDestination::Invalid) { IngestDestination.validate!(url, environment: production) }
    end
    @r.check("開発・テストだけ、疑似の取り込み口（fake-ingest:1935）を許す",
             IngestDestination.validate!("rtmps://fake-ingest:1935/live2", environment: AppEnvironment.new("development")) == "rtmps://fake-ingest:1935/live2")
  end

  # --- エラーの分類 ---

  def error_classification_checks
    @r.section("エラーの分類（reason の表引き）")
    expected = {
      "liveStreamingNotEnabled" => YouTubeErrors::LiveNotEnabled, "livePermissionBlocked" => YouTubeErrors::LiveStreamingRestricted,
      "channelSuspended" => YouTubeErrors::LiveStreamingRestricted, "insufficientLivePermissions" => YouTubeErrors::InsufficientPermissions,
      "forbidden" => YouTubeErrors::InsufficientPermissions, "invalid_grant" => YouTubeErrors::TokenRevoked,
      "userBroadcastsExceedLimit" => YouTubeErrors::BroadcastLimitExceeded, "concurrentBroadcastsExceedLimit" => YouTubeErrors::BroadcastLimitExceeded,
      "sharedIngestionBroadcastsExceedLimit" => YouTubeErrors::BroadcastLimitExceeded, "quotaExceeded" => YouTubeErrors::QuotaExceeded,
      "rateLimitExceeded" => YouTubeErrors::RateLimited, "liveBroadcastNotFound" => YouTubeErrors::NotFound,
      "redundantTransition" => YouTubeErrors::AlreadyTerminal, "invalidTransition" => YouTubeErrors::NotAllowed,
      "liveBroadcastDeletionNotAllowed" => YouTubeErrors::NotAllowed, "channelNotFound" => YouTubeErrors::NoChannel
    }
    expected.each do |reason, error_class|
      error = YouTubeErrors.classify(status: 403, payload: { "error" => { "errors" => [ { "reason" => reason } ] } }, call_kind: :bind)
      @r.check("#{reason} -> #{error_class.name.demodulize}", error.instance_of?(error_class))
    end
    unknown = YouTubeErrors.classify(status: 403, payload: { "error" => { "errors" => [ { "reason" => "someNewReason" } ] } }, call_kind: :bind)
    @r.check("未知の reason は UnexpectedResponse（黙って成功にしない）", unknown.instance_of?(YouTubeErrors::UnexpectedResponse))
    @r.check("5xx は Transient、429 は RateLimited、404 は NotFound", [ 503, 429, 404 ].map { |status| YouTubeErrors.classify(status: status, payload: nil).class } ==
             [ YouTubeErrors::Transient, YouTubeErrors::RateLimited, YouTubeErrors::NotFound ])
    @r.check("concurrentBroadcastsExceedLimit は再試行の対象にしない", YouTubeErrors::BroadcastLimitExceeded.new.disposition.retryable == false)
    forbidden = YouTubeErrors::InsufficientPermissions.new
    @r.check("先行配信の清算での権限の応答は、認可失効にしない", forbidden.disposition.connection_state == "revoked" && forbidden.disposition(context: :prior_settlement).connection_state.nil?)
    @r.check("状態の遷移は YouTubeConnection のメソッドで行う（窓口は変えない）", YoutubeConnection.instance_methods(false).include?(:mark_revoked!) &&
             YoutubeConnection.instance_methods(false).include?(:mark_live_not_enabled!) && YoutubeConnection.instance_methods(false).include?(:discard_stream!))
  end

  # --- 疑似 ---

  def fake_checks
    @r.section("FakeYouTubeGateway（疑似）")
    YouTubeServices.reset_shared!
    environment = AppEnvironment.new("test")
    services = YouTubeServices.build(environment, env: { "TOKEN_ENCRYPTION_KEY" => @key })
    @r.check("AppEnvironment#external_services が :fake なら、疑似", services.youtube_gateway.instance_of?(FakeYouTubeGateway))

    user = new_user
    services.token_vault.store(user_id: user.id, refresh_token: REFRESH_TOKEN, now: Time.current)
    connection = YoutubeConnection.find_by!(user_id: user.id)
    now = Time.current
    usage_date = UsageCalendar.quota_date(now)
    usage = DailyUsage.create!(user: user, usage_date: usage_date)
    broadcast = Broadcast.create!(user: user, daily_usage: usage, state: "reserved", usage_date: usage_date, quota_date: usage_date, pending_title: TITLE,
                                  privacy_status: "unlisted", made_for_kids: false, accepted_at: now)
    # 同じ DB で繰り返し実行しても、前回までの予約で拒否されないよう、1 日の上限は十分に大きく与える（この確認の対象は、上限ではない）
    raise "the reservation was refused" unless QuotaLedger.reserve!(broadcast, quota_date: usage_date, daily_total: 1_000_000_000)

    fake = services.youtube_gateway

    id = fake.insert_broadcast(connection, { title: TITLE, privacy_status: "unlisted", made_for_kids: false, scheduled_start_time: now + 60 }, broadcast: broadcast)
    stream = fake.ensure_stream(connection, broadcast: broadcast)
    @r.check("決定的な識別子（fake-bc-N・fake-stream-N）・配信キー（fake-key-N）・疑似の取り込み口", [ id, stream.stream_id, stream.stream_key, stream.ingest_url ] ==
             [ "fake-bc-1", "fake-stream-1", "fake-key-1", "rtmps://fake-ingest:1935/live2" ])
    fake.bind(connection, id, stream.stream_id, broadcast: broadcast)
    @r.check("紐づけ後は ready", fake.fetch_status(connection, id, broadcast: broadcast, bucket: :prep).value == "ready")
    sleep 5.2
    @r.check("紐づけから 5 秒後に live", fake.fetch_status(connection, id, broadcast: broadcast, bucket: :prep).live?)
    fake.complete(connection, id, broadcast: broadcast, bucket: :settle)
    @r.check("完了への遷移で complete", fake.fetch_status(connection, id, broadcast: broadcast, bucket: :settle).complete?)
    rows = ledger_rows(broadcast)
    fifties = rows.select { |_, units, _, _| units.to_i == 50 }.map(&:first).sort
    singles = rows.reject { |_, units, _, _| units.to_i == 50 }
    @r.check("疑似でも、台帳へ同じ単価で記帳する（作成 50・ストリームの作成 50・紐づけ 50・遷移 50。状態の確認は一覧取得の 1）",
             fifties == %w[ liveBroadcasts.bind liveBroadcasts.insert liveBroadcasts.transition liveStreams.insert ] &&
             singles.size == 3 && singles.all? { |api_method, units, _, _| api_method == "liveBroadcasts.list" && units.to_i == 1 },
             rows.inspect)

    fake.fail_next(:live_not_enabled)
    @r.raises("失敗の注入: 次の呼び出しが LiveNotEnabled", YouTubeErrors::LiveNotEnabled) { fake.fetch_status(connection, id, broadcast: broadcast, bucket: :prep) }
    @r.check("その次は成功する", fake.fetch_status(connection, id, broadcast: broadcast, bucket: :prep).complete?)
    fake.fail_next(:token_revoked)
    @r.raises("失敗の注入: トークンの失効（TokenRevoked）", YouTubeErrors::TokenRevoked) { fake.fetch_status(connection, id, broadcast: broadcast, bucket: :prep) }
    @r.check("TokenRevoked で接続状態が revoked になる", sql("SELECT state FROM youtube_connections WHERE user_id = ?", user.id).flatten.first == "revoked")
    YouTubeServices.reset_shared!
  end

  # --- 本番での選択 ---

  def production_checks
    @r.section("本番の選択")
    production = AppEnvironment.new("production")
    live_env = { "TOKEN_ENCRYPTION_KEY" => @key, "GOOGLE_CLIENT_ID" => "dummy-id", "GOOGLE_CLIENT_SECRET" => "dummy-secret" }
    services = YouTubeServices.build(production, env: live_env)
    @r.check("本番は実物（疑似の窓口ではない）", services.youtube_gateway.instance_of?(YouTubeGateway) && !services.youtube_gateway.is_a?(FakeYouTubeGateway))
    @r.raises("本番で資格情報が欠けていれば、疑似へ倒さず例外", ExternalServices::MissingConfiguration) { YouTubeServices.build(production, env: {}) }
    @r.raises("本番では疑似の窓口を構築できない", FakeServices::NotAllowedError) do
      FakeYouTubeGateway.new(
        token_vault: services.token_vault, api: FakeYouTubeGateway::Api.new(api_base: API, ingest: ExternalServices.config.fetch(:youtube).fetch(:dev_ingest), clock: -> { @now }, live_after_seconds: 5, channel_title: "x"),
        api_base: API, stream_title: "x", environment: production
      )
    end
    @r.raises("本番では疑似の Google を構築できない", FakeServices::NotAllowedError) { FakeGoogleTokenClient.new(environment: production) }
  end

  # --- ログに機密が無い ---

  def secrets_in_logs_check
    @r.section("ログ")
    output = @logs.string
    secrets = [ REFRESH_TOKEN, ACCESS_TOKEN, STREAM_KEY, TITLE, @key, "dummy-message-must-not-appear" ] + @ciphertexts.to_a
    leaked = secrets.select { |secret| output.include?(secret) }
    @r.check("実行中のログ（SQL を含む）に、更新トークン・アクセストークン・配信キー・タイトル・暗号鍵・暗号文・応答の message が出ていない", leaked.empty?, leaked.map { |s| s[0, 12] }.join(", "))
  end
end

reporter = Reporter.new
Acceptance.new(reporter).run
exit reporter.finish
