# frozen_string_literal: true

# 開発環境（RAILS_ENV=development）での通しの確認。issue #10 の疑似の窓口が、開発環境で、環境の判定（AppEnvironment#external_services = :fake）
# によって選ばれ、実際の Google・YouTube を呼ばずに、配信の準備から終了までを進められることを確かめる。
#   - 要求ごとに YouTubeServices.current を呼んでも、疑似の YouTube の状態（作成した配信・ストリーム）と、注入した失敗が続く
#   - 紐づけから 5 秒後（実時計）に、配信が live になる
#   - 通信を試みない（WebMock で、すべての通信を禁止する。試みれば失敗する）
#   - 本番の許可リストは、疑似の取り込み口を通さない
#   - ログに、更新トークン・アクセストークン・配信キー・タイトル・暗号鍵が出ない
# 開発 DB（bl_development）は使わない。呼び出し側（run_all.sh）が、スキーマを読み込み済みの scratch の DB（bl_test_...）の URL を与える。
#
# 使い方（run_all.sh が実行する）:
#   scripts/dc.sh exec -T backend bundle exec ruby - < <このディレクトリ>/dev_flow_check.rb   （RAILS_ENV=development と DATABASE_URL は、呼び出し側が与える）
# 終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 前提を満たさない
ENV["RAILS_ENV"] = "development"
require "/app/config/environment"
require "webmock"
require "securerandom"
require "stringio"

database = ActiveRecord::Base.connection_db_config.database
unless Rails.env.development? && database.match?(/\Abl_test_[a-z0-9_]+\z/)
  warn "FAIL 開発環境で、scratch の DB（bl_test_...）に接続している必要があります（環境: #{Rails.env}、DB: #{database}）"
  exit 2
end
unless ENV["TOKEN_ENCRYPTION_KEY"].to_s.match?(/\A\h{64}\z/)
  warn "FAIL TOKEN_ENCRYPTION_KEY（64 文字の 16 進数）が環境にありません。scripts/setup_dev_env.sh を実行してください"
  exit 2
end

class DevFlowCheck
  REFRESH_TOKEN = "1//dummy-dev-flow-refresh-token-must-not-appear"
  TITLE = "dummy-dev-flow-title-must-not-appear"

  def initialize
    @passes = 0
    @failures = 0
    @logs = StringIO.new
    Rails.logger.broadcast_to(::Logger.new(@logs, level: ::Logger::DEBUG))
  end

  def run
    WebMock.enable!
    WebMock.disable_net_connect!
    YouTubeServices.reset_shared!

    selection
    flow
    injection
    production_allowlist
    no_network_and_no_secrets

    puts "\n#{@passes} 件成功、#{@failures} 件失敗"
    @failures.zero? ? 0 : 1
  end

  private

  def check(label, condition, detail = nil)
    if condition
      @passes += 1
      puts "ok   #{label}"
    else
      @failures += 1
      puts "FAIL #{label}#{" (#{detail})" if detail}"
    end
  end

  def raises(label, error_class)
    yield
    check(label, false, "no exception")
  rescue error_class
    check(label, true)
  rescue StandardError => e
    check(label, false, e.class.name)
  end

  def services
    YouTubeServices.current
  end

  def selection
    puts "-- 実装の選択（開発環境）"
    check("環境の判定は development、外部サービスの選択は :fake", AppEnvironment.current.development? && AppEnvironment.current.external_services == :fake)
    current = services
    check("開発環境では、疑似の窓口と TokenVault", current.youtube_gateway.instance_of?(FakeYouTubeGateway) && current.token_vault.instance_of?(TokenVault))
    check("要求ごとに作り直しても、疑似の YouTube は同じ（状態が続く）", services.youtube_gateway.api.equal?(current.youtube_gateway.api))
  end

  def flow
    puts "-- 準備から終了までの流れ（疑似の窓口。実時計）"
    now = Time.current
    usage_date = UsageCalendar.quota_date(now)
    @user = User.create!(google_sub: "dummy-dev-flow-sub-#{SecureRandom.hex(8)}", last_login_at: now)
    services.token_vault.store(user_id: @user.id, refresh_token: REFRESH_TOKEN, now: now)
    @connection = YoutubeConnection.find_by!(user_id: @user.id)
    usage = DailyUsage.create!(user: @user, usage_date: usage_date)
    @broadcast = Broadcast.create!(
      user: @user, daily_usage: usage, state: "reserved", usage_date: usage_date, quota_date: usage_date, pending_title: TITLE,
      privacy_status: "unlisted", made_for_kids: false, accepted_at: now
    )
    # 同じ DB で繰り返し実行しても、前回までの予約で拒否されないよう、1 日の上限は十分に大きく与える（この確認の対象は、上限ではない）
    raise "the reservation was refused" unless QuotaLedger.reserve!(@broadcast, quota_date: usage_date, daily_total: 1_000_000_000)

    first = services.youtube_gateway
    @id = first.insert_broadcast(@connection, { title: TITLE, privacy_status: "unlisted", made_for_kids: false, scheduled_start_time: YouTubeGateway.scheduled_start_time(now) }, broadcast: @broadcast)
    stream = services.youtube_gateway.ensure_stream(@connection, broadcast: @broadcast)
    @stream_id = stream.stream_id
    check("決定的な識別子・配信キー・疑似の取り込み口", @id.start_with?("fake-bc-") && stream.stream_id.start_with?("fake-stream-") && stream.stream_key.start_with?("fake-key-") &&
                                              stream.ingest_url == "rtmps://fake-ingest:1935/live2")
    check("取り込み先は、開発の許可リストを通る", IngestDestination.validate!(stream.ingest_url) == stream.ingest_url)

    services.youtube_gateway.bind(@connection, @id, @stream_id, broadcast: @broadcast)
    check("紐づけた直後は ready（別の窓口から見ても）", services.youtube_gateway.fetch_status(@connection, @id, broadcast: @broadcast, bucket: :prep).value == "ready")
    sleep 5.2
    check("紐づけから 5 秒後に live", services.youtube_gateway.fetch_status(@connection, @id, broadcast: @broadcast, bucket: :prep).live?)
    check("ライブ中のストリームの健全性は good（警告なし）", !services.youtube_gateway.fetch_stream_health(@connection, @stream_id, broadcast: @broadcast).warning?)
    services.youtube_gateway.complete(@connection, @id, broadcast: @broadcast, bucket: :settle)
    check("完了への遷移", services.youtube_gateway.fetch_status(@connection, @id, broadcast: @broadcast, bucket: :settle).complete?)

    rows = ActiveRecord::Base.connection.select_rows(
      ActiveRecord::Base.sanitize_sql_array([ "SELECT units, bucket FROM quota_entries WHERE broadcast_id = ?", @broadcast.id ])
    )
    check("疑似でも、台帳へ同じ単価で記帳する（準備・確認枠 50+50+50+1+1+1、終了・清算枠 50+1）",
          rows.select { |_, bucket| bucket == "prep" }.sum { |units, _| units.to_i } == 153 && rows.select { |_, bucket| bucket == "settle" }.sum { |units, _| units.to_i } == 51,
          rows.inspect)
  end

  def injection
    puts "-- 失敗の注入（同じプロセスの API）"
    services.youtube_gateway.fail_next(:live_not_enabled)
    next_gateway = services.youtube_gateway
    raises("注入した失敗が、次に作った窓口の呼び出しにも続く（LiveNotEnabled）", YouTubeErrors::LiveNotEnabled) do
      next_gateway.fetch_status(@connection, @id, broadcast: @broadcast, bucket: :settle)
    end
    check("その次は成功する", next_gateway.fetch_status(@connection, @id, broadcast: @broadcast, bucket: :settle).complete?)

    services.youtube_gateway.fail_next(:token_revoked)
    raises("トークンの失敗の注入（TokenRevoked）", YouTubeErrors::TokenRevoked) { services.youtube_gateway.fetch_status(@connection, @id, broadcast: @broadcast, bucket: :settle) }
    check("TokenRevoked で、接続状態が revoked になる", YoutubeConnection.find_by!(user_id: @user.id).state == "revoked")
  end

  def production_allowlist
    puts "-- 本番の許可リスト"
    raises("本番の許可リストは、疑似の取り込み口を通さない", IngestDestination::Invalid) do
      IngestDestination.validate!("rtmps://fake-ingest:1935/live2", environment: AppEnvironment.new("production"))
    end
    raises("本番では、疑似の窓口を構築できない", FakeServices::NotAllowedError) do
      FakeYouTubeGateway.new(
        token_vault: services.token_vault, api: services.youtube_gateway.api, api_base: ExternalServices.config.fetch(:youtube).fetch(:api_base),
        stream_title: "x", environment: AppEnvironment.new("production")
      )
    end
  end

  # 対照実験: 存在しないホスト（.invalid）へ試みた通信が、禁止され、記録に残ること。「通信 0 件」の検査が、空振りしていないことの証拠
  def network_attempt_is_detected?
    before = WebMock::RequestRegistry.instance.requested_signatures.hash.size
    begin
      Net::HTTP.get(URI("https://detector-probe.invalid/"))
      return false
    rescue WebMock::NetConnectNotAllowedError
      nil
    end
    WebMock::RequestRegistry.instance.requested_signatures.hash.size == before + 1
  end

  def no_network_and_no_secrets
    puts "-- 通信とログ"
    attempted = WebMock::RequestRegistry.instance.requested_signatures.hash.size
    check("実際の通信を、1 回も試みていない", attempted.zero?, "#{attempted} 件")
    check("対照: 通信を試みれば、禁止されて記録に残る（検出の仕組みが働いている）", network_attempt_is_detected?)
    output = @logs.string
    leaked = [ REFRESH_TOKEN, TITLE, ENV.fetch("TOKEN_ENCRYPTION_KEY"), "fake-key-", "fake-access-token-" ].select { |secret| output.include?(secret) }
    check("ログに、更新トークン・アクセストークン・配信キー・タイトル・暗号鍵が出ていない", leaked.empty?, leaked.join(", "))
  end
end

exit DevFlowCheck.new.run
