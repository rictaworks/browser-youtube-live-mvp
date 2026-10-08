require "rails_helper"
require "support/youtube_gateway_support"

# 窓口のエラー分類（issue #10。requirements.md 10.6・10.5・10.4）。YouTube の応答のエラーを、error.errors[].reason の表引きで、
# 型付きの例外へ分類する（分類の表そのものは youtube_errors_spec.rb）。ここでは、窓口のすべての公開メソッドが、同じ経路で分類することと、
#   - 窓口は、接続の状態を変えない（変えるかどうかは、例外の disposition を見て、呼び出し側が決める）
#   - 清算の呼び出し（complete・delete）の例外から、清算の結果へ直接写せる（SettlementRules.apply_result へ渡せる）
#   - 未知の reason は UnexpectedResponse（黙って成功にしない）
#   - 例外・ログに、トークン・配信キー・タイトル・応答の message を出さない
# を確かめる。
# 台帳の枠は、配信ごとに限られる（準備・確認枠 340・終了・清算枠 210）。繰り返しの呼び出しで枠が尽きて、QuotaInsufficient になると、
# 分類を検査したことにならない。そこで、1 回の試行ごとに、新しいアカウント・接続・配信（fresh_context）を使う。
RSpec.describe YouTubeGateway do
  include LedgerSupport
  include YouTubeGatewaySupport
  include LogCapture

  let(:day) { quota_day(0) }
  let(:now) { noon_of(day) }
  let(:vault) { token_vault_double }
  let(:gateway) { build_gateway(vault: vault, now: now) }
  let(:params) { { title: title_value, privacy_status: "unlisted", made_for_kids: false, scheduled_start_time: now + 60 } }

  # 新しいアカウント・接続・配信（予約済み）。多数の配信を作るので、1 日の割り当てを大きくする（既定では 1 日に 16 本までしか予約できない）。
  # 割り当て超過（quotaExceeded）の試行は、その日に超過の印を付ける（以後の予約を断る）ので、次の配信を予約する前に、印を外す
  def fresh_context
    QuotaDay.where(quota_date: day).update_all(exhausted: false)
    _user, connection, broadcast = ledger_account(quota_date: day, daily_total: 1_000_000)
    YouTubeGatewaySupport::Account.new(connection, broadcast)
  end

  # 窓口の公開メソッド（probe_channel を除く）の呼び出し。名前 -> 呼び出し
  def invoke(name, context, target: gateway)
    connection = context.connection
    broadcast = context.broadcast
    case name
    when :insert_broadcast then target.insert_broadcast(connection, params, broadcast: broadcast)
    when :list_unstarted_broadcasts then target.list_unstarted_broadcasts(connection, broadcast: broadcast)
    when :ensure_stream then target.ensure_stream(connection, broadcast: broadcast)
    when :bind then target.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast)
    when :fetch_stream_health then target.fetch_stream_health(connection, youtube_stream_id, broadcast: broadcast)
    when :complete_settle then target.complete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle)
    when :complete_prep then target.complete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep)
    when :delete_settle then target.delete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle)
    when :delete_prep then target.delete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep)
    else raise ArgumentError, "unknown call #{name}"
    end
  end

  # 新しい文脈で呼び出し、投げられた型付きの例外を返す（投げられなければ nil）
  def raised_by(name, context = fresh_context, target: gateway)
    invoke(name, context, target: target)
    nil
  rescue YouTubeErrors::Base => e
    e
  end

  def stub_any_youtube(response)
    stub_request(:any, %r{\Ahttps://www\.googleapis\.com/youtube/v3/}).to_return(response)
  end

  # 本文を使わない成功の呼び出し（本文を解釈しない）
  body_ignored = %i[ complete_settle complete_prep delete_settle delete_prep ]
  methods_under_test = %i[ insert_broadcast list_unstarted_broadcasts ensure_stream bind fetch_stream_health complete_settle complete_prep delete_settle delete_prep ]

  # 分類の表（reason -> HTTP ステータスの例, 例外クラス）
  table = {
    "liveStreamingNotEnabled" => [ 403, YouTubeErrors::LiveNotEnabled ],
    "livePermissionBlocked" => [ 403, YouTubeErrors::LiveStreamingRestricted ],
    "channelClosed" => [ 403, YouTubeErrors::LiveStreamingRestricted ],
    "channelSuspended" => [ 403, YouTubeErrors::LiveStreamingRestricted ],
    "authenticatedUserAccountClosed" => [ 403, YouTubeErrors::LiveStreamingRestricted ],
    "authenticatedUserAccountSuspended" => [ 403, YouTubeErrors::LiveStreamingRestricted ],
    "insufficientLivePermissions" => [ 403, YouTubeErrors::InsufficientPermissions ],
    "insufficientPermissions" => [ 403, YouTubeErrors::InsufficientPermissions ],
    "forbidden" => [ 403, YouTubeErrors::InsufficientPermissions ],
    "userBroadcastsExceedLimit" => [ 403, YouTubeErrors::BroadcastLimitExceeded ],
    "concurrentBroadcastsExceedLimit" => [ 403, YouTubeErrors::BroadcastLimitExceeded ],
    "sharedIngestionBroadcastsExceedLimit" => [ 403, YouTubeErrors::BroadcastLimitExceeded ],
    "quotaExceeded" => [ 403, YouTubeErrors::QuotaExceeded ],
    "dailyLimitExceeded" => [ 403, YouTubeErrors::QuotaExceeded ],
    "userRequestsExceedRateLimit" => [ 403, YouTubeErrors::RateLimited ],
    "rateLimitExceeded" => [ 403, YouTubeErrors::RateLimited ],
    "userRateLimitExceeded" => [ 403, YouTubeErrors::RateLimited ],
    "liveBroadcastNotFound" => [ 404, YouTubeErrors::NotFound ],
    "liveStreamNotFound" => [ 404, YouTubeErrors::NotFound ],
    "redundantTransition" => [ 403, YouTubeErrors::AlreadyTerminal ],
    "invalidTransition" => [ 403, YouTubeErrors::NotAllowed ],
    "errorStreamInactive" => [ 403, YouTubeErrors::NotAllowed ],
    "liveBroadcastDeletionNotAllowed" => [ 403, YouTubeErrors::NotAllowed ],
    "liveStreamDeletionNotAllowed" => [ 403, YouTubeErrors::NotAllowed ],
    "liveBroadcastBindingNotAllowed" => [ 403, YouTubeErrors::NotAllowed ],
    "channelNotFound" => [ 403, YouTubeErrors::NoChannel ],
    "youtubeSignupRequired" => [ 401, YouTubeErrors::NoChannel ]
  }

  describe "すべての公開メソッドが、同じ分類の表を使う（reason の全種 x 9 つの呼び出し）" do
    methods_under_test.each do |name|
      describe name.to_s do
        table.each do |reason, (status, error_class)|
          it "#{reason}（HTTP #{status}）は #{error_class.name.demodulize}。reason・ステータス・呼び出しの種別を持つ" do
            stub_any_youtube(error_response(status, reason))

            error = raised_by(name)

            expect(error).to be_instance_of(error_class)
            expect(error).to have_attributes(reason: reason, status: status)
            expect(error.call_kind).to be_a(Symbol)
          end
        end

        it "未知の reason は UnexpectedResponse（reason は記録する）。5xx は Transient、429 は RateLimited、reason が無い 400 は UnexpectedResponse" do
          stub_any_youtube(error_response(403, "someNewReason"))
          expect(raised_by(name)).to be_instance_of(YouTubeErrors::UnexpectedResponse).and have_attributes(reason: "someNewReason")

          stub_any_youtube(error_response(503, "backendError"))
          expect(raised_by(name)).to be_instance_of(YouTubeErrors::Transient)

          stub_any_youtube(json_response({}, status: 429))
          expect(raised_by(name)).to be_instance_of(YouTubeErrors::RateLimited)

          stub_any_youtube(json_response({}, status: 400))
          expect(raised_by(name)).to be_instance_of(YouTubeErrors::UnexpectedResponse)
        end

        it "タイムアウトは Timeout、接続の失敗・TLS の失敗は Transient" do
          stub_request(:any, %r{\Ahttps://www\.googleapis\.com/youtube/v3/}).to_timeout
          expect(raised_by(name)).to be_instance_of(YouTubeErrors::Timeout)

          stub_request(:any, %r{\Ahttps://www\.googleapis\.com/youtube/v3/}).to_raise(Errno::ECONNREFUSED)
          expect(raised_by(name)).to be_instance_of(YouTubeErrors::Transient).and have_attributes(detail: :connection)

          stub_request(:any, %r{\Ahttps://www\.googleapis\.com/youtube/v3/}).to_raise(OpenSSL::SSL::SSLError)
          expect(raised_by(name)).to be_instance_of(YouTubeErrors::Transient).and have_attributes(detail: :tls)
        end

        it "壊れた gzip（Zlib::Error）は UnexpectedResponse（detail: invalid_encoding）。生の例外にしない" do
          stub_request(:any, %r{\Ahttps://www\.googleapis\.com/youtube/v3/}).to_raise(Zlib::GzipFile::Error)

          expect(raised_by(name)).to be_instance_of(YouTubeErrors::UnexpectedResponse).and have_attributes(detail: :invalid_encoding)
        end

        if body_ignored.include?(name)
          it "成功（2xx）の本文は使わない: JSON でない本文でも、成功（true）" do
            stub_any_youtube(status: 200, body: "<html>not json</html>")

            expect(invoke(name, fresh_context)).to be(true)
          end
        else
          it "成功（2xx）の本文が JSON でなければ UnexpectedResponse（detail: invalid_json）" do
            stub_any_youtube(status: 200, body: "<html>not json</html>")

            expect(raised_by(name)).to be_instance_of(YouTubeErrors::UnexpectedResponse).and have_attributes(detail: :invalid_json)
          end
        end

        it "応答が大きすぎる（本文の上限を超える）は UnexpectedResponse（detail: response_too_large）" do
          small = YouTubeGateway.new(
            http: ExternalHttp.new(max_body_bytes: 64), token_vault: vault, api_base: api_base, stream_title: "Browser Live",
            environment: AppEnvironment.new("production"), clock: -> { now }
          )
          stub_any_youtube(status: 200, body: "x" * 65)

          expect(raised_by(name, target: small)).to be_instance_of(YouTubeErrors::UnexpectedResponse).and have_attributes(detail: :response_too_large)
        end
      end
    end
  end

  describe "fetch_status（存在しない配信は例外にしない）" do
    it "分類の表のすべての reason: NotFound（liveBroadcastNotFound・liveStreamNotFound・404）だけは YouTubeStatus.not_found を返し、ほかは型付きの例外" do
      table.each do |reason, (status, error_class)|
        context = fresh_context
        stub_any_youtube(error_response(status, reason))

        if error_class == YouTubeErrors::NotFound
          expect(gateway.fetch_status(context.connection, youtube_broadcast_id, broadcast: context.broadcast, bucket: :prep)).to be_not_found
        else
          expect { gateway.fetch_status(context.connection, youtube_broadcast_id, broadcast: context.broadcast, bucket: :prep) }.to raise_error(error_class)
        end
      end
    end

    it "理由の符号が無い 404 も、存在しない配信" do
      context = fresh_context
      stub_any_youtube(json_response({}, status: 404))

      expect(gateway.fetch_status(context.connection, youtube_broadcast_id, broadcast: context.broadcast, bucket: :settle)).to be_not_found
    end
  end

  describe "probe_channel（接続時の確認の結果）" do
    it "チャンネルの確認に NoChannel（channelNotFound・youtubeSignupRequired）が返れば no_channel。それ以外の失敗は、型付きの例外" do
      table.each do |reason, (status, error_class)|
        connection = fresh_context.connection
        stub_any_youtube(error_response(status, reason))

        if error_class == YouTubeErrors::NoChannel
          expect(gateway.probe_channel(connection).outcome).to eq("no_channel")
        else
          expect { gateway.probe_channel(connection) }.to raise_error(error_class)
        end
      end
    end

    it "チャンネルの確認が成功したあと、配信の一覧取得が失敗したときは、ライブ未有効・制限中なら live_not_enabled、それ以外は例外" do
      stub_request(:get, api_url("channels")).with(query: hash_including({})).to_return(list_response(channel_resource))
      table.each do |reason, (status, error_class)|
        connection = fresh_context.connection
        stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(error_response(status, reason))

        if [ YouTubeErrors::LiveNotEnabled, YouTubeErrors::LiveStreamingRestricted ].include?(error_class)
          expect(gateway.probe_channel(connection).outcome).to eq("live_not_enabled")
        else
          expect { gateway.probe_channel(connection) }.to raise_error(error_class)
        end
      end
    end
  end

  describe "窓口は、接続の状態を変えない（変えるかどうかは、disposition を見て、呼び出し側が決める）" do
    it "どの reason が返っても、接続の状態は connected のまま（YouTube の呼び出しまで進んでいること = QuotaInsufficient でないことも確かめる）" do
      table.each do |reason, (status, error_class)|
        context = fresh_context
        stub_any_youtube(error_response(status, reason))

        bind_error = raised_by(:bind, context)
        context_for_settle = fresh_context
        settle_error = raised_by(:complete_settle, context_for_settle)

        expect([ bind_error, settle_error ].map(&:class)).to all(eq(error_class)), "reason #{reason}"
        expect(YoutubeConnection.find(context.connection.id).state).to eq("connected"), "reason #{reason} changed the state"
        expect(YoutubeConnection.find(context_for_settle.connection.id).state).to eq("connected"), "reason #{reason} changed the state"
      end
    end

    # 10.6 の「動作」: 接続状態の更新。disposition に従って、YouTubeConnection のメソッドで遷移させる（呼び出し側 = #13 の仕事の見本）
    it "disposition の接続状態に従って、YouTubeConnection のメソッドで遷移させる: ライブ未有効・制限中 -> live_not_enabled、権限の不足 -> revoked" do
      {
        "liveStreamingNotEnabled" => "live_not_enabled",
        "livePermissionBlocked" => "live_not_enabled",
        "channelSuspended" => "live_not_enabled",
        "insufficientLivePermissions" => "revoked",
        "forbidden" => "revoked"
      }.each do |reason, expected_state|
        context = fresh_context
        stub_any_youtube(error_response(403, reason))

        error = raised_by(:bind, context)
        case error.disposition.connection_state
        when "live_not_enabled" then context.connection.mark_live_not_enabled!
        when "revoked" then context.connection.mark_revoked!
        end

        expect(YoutubeConnection.find(context.connection.id).state).to eq(expected_state), "reason #{reason}"
      end
    end

    it "先行配信の清算（context: :prior_settlement）での権限の応答は、認可失効にしない（状態の指示が無い）" do
      stub_any_youtube(error_response(403, "forbidden"))

      error = raised_by(:complete_prep)

      expect(error.disposition.connection_state).to eq("revoked")
      expect(error.disposition(context: :prior_settlement).connection_state).to be_nil
      expect(error.disposition(context: :prior_settlement).settlement_result).to eq(:forbidden)
    end
  end

  describe "清算の呼び出し（complete・delete）の例外から、清算の結果へ直接写す（SettlementRules の表との整合）" do
    %i[ complete_settle delete_settle ].each do |name|
      it "#{name}: SettlementRules::ERROR_REASON_RESULTS の reason は、同じ清算の結果になる" do
        SettlementRules::ERROR_REASON_RESULTS.each do |reason, expected|
          stub_any_youtube(error_response(reason.end_with?("NotFound") ? 404 : 403, reason))

          error = raised_by(name)

          expect(error.disposition.settlement_result).to eq(expected), "reason #{reason}"
          expect { SettlementRules.apply_result(settlement_state: "pending", attempts: 0, result: error.disposition.settlement_result) }.not_to raise_error
        end
      end

      it "#{name}: 清算の結果を SettlementRules.apply_result へ渡すと、存在しない・すでに終端は清算済み、そのほかの失敗は未清算のまま再試行" do
        {
          [ 404, "liveBroadcastNotFound" ] => "settled",
          [ 403, "redundantTransition" ] => "settled",
          [ 403, "invalidTransition" ] => "pending",
          [ 403, "liveBroadcastDeletionNotAllowed" ] => "pending",
          [ 403, "errorStreamInactive" ] => "pending",
          [ 403, "insufficientPermissions" ] => "pending",
          [ 503, "backendError" ] => "pending",
          [ 403, "quotaExceeded" ] => "pending",
          [ 403, "someNewReason" ] => "pending"
        }.each do |(status, reason), expected_state|
          stub_any_youtube(error_response(status, reason))

          error = raised_by(name)
          outcome = SettlementRules.apply_result(settlement_state: "pending", attempts: 0, result: error.disposition.settlement_result)

          expect(outcome.settlement_state).to eq(expected_state), "reason #{reason}"
        end
      end
    end

    it "NotAllowed（invalidTransition など）は、すでに終端（AlreadyTerminal）ではない。別の型で、別の清算の結果" do
      stub_any_youtube(error_response(403, "invalidTransition"))
      not_allowed = raised_by(:complete_settle)
      stub_any_youtube(error_response(403, "redundantTransition"))
      already = raised_by(:complete_settle)

      expect(not_allowed).to be_instance_of(YouTubeErrors::NotAllowed)
      expect(already).to be_instance_of(YouTubeErrors::AlreadyTerminal)
      expect(not_allowed.disposition.settlement_result).not_to eq(already.disposition.settlement_result)
    end
  end

  describe "例外・ログに機密を出さない" do
    let(:hostile_message) { "dummy-title-must-not-appear dummy-stream-key-must-not-appear ya29.dummy-access-token-must-not-appear" }

    methods_under_test.each do |name|
      it "#{name}: 応答の message（タイトル・配信キー・トークンを含み得る）を、例外のメッセージ・inspect・フルメッセージ・ログのどれにも出さない" do
        secrets = [ title_value, stream_key_value, access_token_value ]

        table.each do |reason, (status, error_class)|
          stub_any_youtube(error_response(status, reason, message: hostile_message))
          error = nil

          output = capture_logs { error = raised_by(name) }

          expect(error).to be_instance_of(error_class), "#{name} #{reason}"
          [ output, error.message, error.inspect, error.full_message ].each do |text|
            secrets.each { |secret| expect(text).not_to include(secret), "#{name} #{reason} leaked #{secret}" }
          end
        end
      end
    end

    it "応答の本文（配信キーを含むストリームのリソース）が、想定外の形でも、本文を例外・ログに出さない" do
      stub_any_youtube(json_response(stream_resource(rtmps: "not a url", stream_key: stream_key_value)))
      error = nil

      output = capture_logs { error = raised_by(:ensure_stream) }

      expect(error).to be_a(YouTubeErrors::Base)
      [ output, error.message, error.inspect ].each { |text| expect(text).not_to include(stream_key_value) }
    end

    it "失敗のログは 1 回の失敗につき、窓口の 1 行（[youtube_gateway] failed ...）。ログに出るのは符号と内部の識別子だけ" do
      stub_any_youtube(error_response(503, "backendError", message: hostile_message))

      output = capture_logs { raised_by(:bind) }

      lines = output.lines.grep(/\[youtube_gateway\] failed/)
      expect(lines.size).to eq(1)
      expect(lines.first).to match(/failed call=bind broadcast_id=\h{8}-\h{4}-\h{4}-\h{4}-\h{12} user_id=\h{8}-\h{4}-\h{4}-\h{4}-\h{12} class=Transient status=503 reason=backendError/)
    end

    it "想定した結果（存在しない配信の状態確認・チャンネルが無い）は、失敗の警告ログにしない" do
      context = fresh_context
      stub_any_youtube(error_response(404, "liveBroadcastNotFound"))

      output = capture_logs { gateway.fetch_status(context.connection, youtube_broadcast_id, broadcast: context.broadcast, bucket: :prep) }

      expect(output.lines.grep(/\[youtube_gateway\] failed/)).to be_empty
    end
  end
end
