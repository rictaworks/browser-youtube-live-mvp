require "rails_helper"
require "support/youtube_gateway_support"

# 疑似の YouTube の窓口（FakeYouTubeGateway。issue #10）。開発・テストのみ。YouTubeGateway と同じインターフェース・同じ経路（アクセストークンの取得 ->
# 台帳への記帳 -> HTTP（疑似の YouTube へ）-> エラーの分類・応答の解釈）で、YouTube を呼ばずに動く。
#   決定的な識別子（fake-bc-N・fake-stream-N）・取り込み先（契約 dev_ingest。疑似の取り込み口）・配信キー（fake-key-N）
#   配信の状態: created -> ready（紐づけ後）-> live（紐づけから一定時間後。既定 5 秒。時計は注入）-> complete
#   失敗の注入（次の呼び出しだけ。LiveNotEnabled・QuotaExceeded・Transient・TokenRevoked など）。テストと開発の両方から指定できる
#   疑似でも、台帳へ同じ単価で記帳する
# 本番では構築できない。
RSpec.describe FakeYouTubeGateway do
  include LedgerSupport
  include YouTubeGatewaySupport
  include LogCapture

  let(:test_environment) { AppEnvironment.new("test") }
  let(:day) { quota_day(0) }
  let(:start_time) { noon_of(day) }
  let(:time) { [ start_time ] }
  let(:clock) { -> { time.first } }
  let(:key) { "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
  let(:token_client) { FakeGoogleTokenClient.new(environment: test_environment) }
  let(:cache) { TokenVault::AccessTokenCache.new }
  let(:vault) { TokenVault.new(key: key, token_client: token_client, cache: cache) }
  let(:dev_ingest) { ExternalServices.config.fetch(:youtube).fetch(:dev_ingest) }
  let(:api) { FakeYouTubeGateway::Api.new(api_base: api_base, ingest: dev_ingest, clock: clock, live_after_seconds: 5, channel_title: "Fake Channel") }
  let(:gateway) { build_fake(api: api) }
  let(:user) { create(:user) }
  let(:connection) { vault.store(user_id: user.id, refresh_token: "1//dummy-refresh-token", now: start_time) }
  let(:broadcast) { create_reserved_broadcast(quota_date: day, user: user) }

  before do
    connection
    broadcast
  end

  def build_fake(api:, environment: test_environment, token_vault: vault)
    described_class.new(
      token_vault: token_vault, api: api, token_client: token_client, access_token_cache: cache, api_base: api_base, stream_title: "Browser Live",
      environment: environment, clock: clock, logger: Rails.logger
    )
  end

  def advance(seconds)
    time[0] = time.first + seconds
  end

  def insert(target = gateway)
    target.insert_broadcast(connection, { title: title_value, privacy_status: "unlisted", made_for_kids: false, scheduled_start_time: start_time + 60 }, broadcast: broadcast)
  end

  def status_of(id, bucket: :prep)
    gateway.fetch_status(connection, id, broadcast: broadcast, bucket: bucket)
  end

  def failure_of
    yield
    nil
  rescue YouTubeErrors::Base => e
    e
  end

  describe "構築" do
    it "development・test では構築できる。production では FakeServices::NotAllowedError（本番で疑似を使わせない）" do
      expect { build_fake(api: api, environment: AppEnvironment.new("development")) }.not_to raise_error
      expect { build_fake(api: api, environment: test_environment) }.not_to raise_error
      expect { build_fake(api: api, environment: AppEnvironment.new("production")) }.to raise_error(FakeServices::NotAllowedError, /production/)
    end

    it "api は FakeYouTubeGateway::Api。token_vault は必須（ArgumentError）" do
      expect { described_class.new(token_vault: vault, api: Object.new, api_base: api_base, stream_title: "x", environment: test_environment, clock: clock) }.to raise_error(ArgumentError, /api/)
      expect { build_fake(api: api, token_vault: nil) }.to raise_error(ArgumentError, /token_vault/)
    end

    it "YouTubeGateway の一種で、同じ公開メソッドを持つ。疑似だけの公開メソッド（失敗の注入など）が加わる" do
      real = YouTubeGateway.public_instance_methods(false)
      extras = %i[ fail_next force_life_cycle_status set_stream_health reset! api ]

      expect(described_class.superclass).to eq(YouTubeGateway)
      expect(described_class.public_instance_methods(false)).to match_array(extras)
      expect(gateway).to respond_to(*real)
    end

    it "inspect は中身を出さない" do
      expect(gateway.inspect).to eq("#<FakeYouTubeGateway>")
    end
  end

  describe "配信の準備から終了までの流れ（決定的な識別子・取り込み先・配信キー・状態の遷移）" do
    it "作成 -> ストリーム -> 紐づけ -> 5 秒後にライブ -> 完了" do
      broadcast_id = insert
      stream = gateway.ensure_stream(connection, broadcast: broadcast)

      expect(broadcast_id).to eq("fake-bc-1")
      expect(stream).to have_attributes(stream_id: "fake-stream-1", ingest_url: "rtmps://fake-ingest:1935/live2", stream_key: "fake-key-1", created: true)
      expect(status_of(broadcast_id).value).to eq("created")

      expect(gateway.bind(connection, broadcast_id, stream.stream_id, broadcast: broadcast)).to be(true)
      expect(status_of(broadcast_id).value).to eq("ready")
      advance(4)
      expect(status_of(broadcast_id).value).to eq("ready")
      advance(1)
      expect(status_of(broadcast_id)).to be_live
      expect(gateway.fetch_stream_health(connection, stream.stream_id, broadcast: broadcast)).to have_attributes(status: "good", warning?: false)

      expect(gateway.complete(connection, broadcast_id, broadcast: broadcast, bucket: :settle)).to be(true)
      expect(status_of(broadcast_id, bucket: :settle)).to be_complete
    end

    it "識別子は 1 から連番。配信キーはストリームの番号と対応する" do
      ids = Array.new(2) { insert }
      first = gateway.ensure_stream(connection, broadcast: broadcast)
      second = gateway.ensure_stream(connection, broadcast: broadcast)

      expect(ids).to eq(%w[ fake-bc-1 fake-bc-2 ])
      expect([ first.stream_id, second.stream_id ]).to eq(%w[ fake-stream-1 fake-stream-2 ])
      expect([ first.stream_key, second.stream_key ]).to eq(%w[ fake-key-1 fake-key-2 ])
    end

    it "取り込み先は、開発・テストの許可リストを通る疑似の取り込み口（契約 dev_ingest）。本番の許可リストは通さない" do
      stream = gateway.ensure_stream(connection, broadcast: broadcast)

      expect(IngestDestination.validate!(stream.ingest_url, environment: test_environment)).to eq(stream.ingest_url)
      expect { IngestDestination.validate!(stream.ingest_url, environment: AppEnvironment.new("production")) }.to raise_error(IngestDestination::Invalid)
    end

    it "保存した識別子があれば確認して再利用する（created: false）。無効な識別子なら、新しいストリームを作る" do
      first = gateway.ensure_stream(connection, broadcast: broadcast)
      connection.update!(youtube_stream_id: first.stream_id)

      reused = gateway.ensure_stream(connection, broadcast: broadcast)
      connection.update!(youtube_stream_id: "fake-stream-99")
      replaced = gateway.ensure_stream(connection, broadcast: broadcast)

      expect(reused).to have_attributes(stream_id: first.stream_id, stream_key: first.stream_key, created: false)
      expect(replaced).to have_attributes(stream_id: "fake-stream-2", created: true)
    end

    it "未開始の配信の一覧に、作成済み（created・ready）が出る。ライブ・完了は出ない。タイトルと開始予定時刻で引き継げる" do
      first = insert
      second = insert
      stream = gateway.ensure_stream(connection, broadcast: broadcast)
      gateway.bind(connection, second, stream.stream_id, broadcast: broadcast)
      advance(5)

      listed = gateway.list_unstarted_broadcasts(connection, broadcast: broadcast)

      expect(listed.map(&:youtube_broadcast_id)).to eq([ first ])
      expect(listed.first.matches?(title: title_value, scheduled_start_time: start_time + 60)).to be(true)
    end

    it "存在しない配信の状態は not_found。存在しない配信・ストリームへの紐づけは NotFound" do
      stream = gateway.ensure_stream(connection, broadcast: broadcast)
      id = insert

      expect(status_of("fake-bc-99")).to be_not_found
      expect { gateway.bind(connection, "fake-bc-99", stream.stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::NotFound)
      expect { gateway.bind(connection, id, "fake-stream-99", broadcast: broadcast) }.to raise_error(YouTubeErrors::NotFound)
    end

    it "ライブでない配信の完了は NotAllowed（invalidTransition。終端ではない）。完了済みの完了は AlreadyTerminal（redundantTransition）" do
      stream = gateway.ensure_stream(connection, broadcast: broadcast)
      id = insert
      gateway.bind(connection, id, stream.stream_id, broadcast: broadcast)

      expect { gateway.complete(connection, id, broadcast: broadcast, bucket: :prep) }.to raise_error(YouTubeErrors::NotAllowed)
      advance(5)
      gateway.complete(connection, id, broadcast: broadcast, bucket: :prep)
      expect { gateway.complete(connection, id, broadcast: broadcast, bucket: :prep) }.to raise_error(YouTubeErrors::AlreadyTerminal)
    end

    it "削除: 未開始は削除できる（以後 not_found）。ライブは削除できない（NotAllowed）。存在しない配信は NotFound" do
      stream = gateway.ensure_stream(connection, broadcast: broadcast)
      ready = insert
      live = insert
      gateway.bind(connection, ready, stream.stream_id, broadcast: broadcast)
      gateway.bind(connection, live, stream.stream_id, broadcast: broadcast)
      advance(5)
      created = insert

      expect(gateway.delete(connection, created, broadcast: broadcast, bucket: :settle)).to be(true)
      expect(status_of(created)).to be_not_found
      expect { gateway.delete(connection, live, broadcast: broadcast, bucket: :settle) }.to raise_error(YouTubeErrors::NotAllowed)
      expect { gateway.delete(connection, "fake-bc-99", broadcast: broadcast, bucket: :settle) }.to raise_error(YouTubeErrors::NotFound)
    end

    it "force_life_cycle_status: 遷移中（liveStarting）で止まった配信を作れる。完了はできず（NotAllowed）、削除はできる。存在しない配信・未知の状態は ArgumentError" do
      id = insert
      gateway.force_life_cycle_status(id, "liveStarting")

      expect(status_of(id)).to be_transitioning
      expect { gateway.complete(connection, id, broadcast: broadcast, bucket: :settle) }.to raise_error(YouTubeErrors::NotAllowed)
      expect(gateway.delete(connection, id, broadcast: broadcast, bucket: :settle)).to be(true)
      expect { gateway.force_life_cycle_status("fake-bc-99", "live") }.to raise_error(ArgumentError)
      expect { gateway.force_life_cycle_status(insert, "bogus") }.to raise_error(ArgumentError)
    end

    it "set_stream_health: 健全性を上書きできる（bad・severity が error の問題 -> 警告）" do
      stream = gateway.ensure_stream(connection, broadcast: broadcast)
      gateway.set_stream_health(stream.stream_id, status: "bad", error_types: [ "gopSizeLong" ])

      health = gateway.fetch_stream_health(connection, stream.stream_id, broadcast: broadcast)

      expect(health).to have_attributes(status: "bad", error_types: [ "gopSizeLong" ], warning?: true)
    end

    it "ストリームの健全性: 存在しないストリームは NotFound" do
      expect { gateway.fetch_stream_health(connection, "fake-stream-99", broadcast: broadcast) }.to raise_error(YouTubeErrors::NotFound)
    end
  end

  describe "接続時の確認（probe_channel）" do
    it "疑似のチャンネルがあり、ライブが有効: connected（チャンネル名 Fake Channel）。共通枠から 2 ユニット" do
      result = gateway.probe_channel(connection)

      expect(result).to have_attributes(outcome: "connected", channel_title: "Fake Channel")
      expect(ledger_entries).to contain_exactly([ "channels.list", 1, "common", "ok" ], [ "liveBroadcasts.list", 1, "common", "ok" ])
    end

    it "no_channel の注入: チャンネルが無い（no_channel）" do
      gateway.fail_next(:no_channel)

      expect(gateway.probe_channel(connection).outcome).to eq("no_channel")
    end

    it "ライブ配信の確認に live_not_enabled を注入（on: :probe_live_enabled）: live_not_enabled（チャンネル名つき）" do
      gateway.fail_next(:live_not_enabled, on: :probe_live_enabled)

      expect(gateway.probe_channel(connection)).to have_attributes(outcome: "live_not_enabled", channel_title: "Fake Channel")
    end

    it "公開メソッドの名前（probe_channel）で限ると、最初の呼び出し（チャンネルの確認）に当たる。ライブ未有効は、チャンネルの確認では例外" do
      gateway.fail_next(:live_not_enabled, on: :probe_channel)

      expect { gateway.probe_channel(connection) }.to raise_error(YouTubeErrors::LiveNotEnabled)
    end

    it "access_token を渡すと、TokenVault を使わない（接続の行が無くても確認できる）" do
      expect(gateway.probe_channel(nil, access_token: "fake-access-token-direct").outcome).to eq("connected")
    end
  end

  describe "失敗の注入（fail_next。次の呼び出しだけ）" do
    # 注入の名前 -> 例外のクラス
    {
      live_not_enabled: YouTubeErrors::LiveNotEnabled,
      live_streaming_restricted: YouTubeErrors::LiveStreamingRestricted,
      insufficient_permissions: YouTubeErrors::InsufficientPermissions,
      broadcast_limit_exceeded: YouTubeErrors::BroadcastLimitExceeded,
      quota_exceeded: YouTubeErrors::QuotaExceeded,
      rate_limited: YouTubeErrors::RateLimited,
      transient: YouTubeErrors::Transient,
      timeout: YouTubeErrors::Timeout,
      not_found: YouTubeErrors::NotFound,
      already_terminal: YouTubeErrors::AlreadyTerminal,
      not_allowed: YouTubeErrors::NotAllowed,
      no_channel: YouTubeErrors::NoChannel,
      unexpected_response: YouTubeErrors::UnexpectedResponse
    }.each do |name, error_class|
      it "#{name}: 次の呼び出しが #{error_class.name.demodulize}（窓口の分類を通る）。その次は成功する" do
        gateway.fail_next(name)

        error = failure_of { gateway.bind(connection, "fake-bc-1", "fake-stream-1", broadcast: broadcast) }

        expect(error).to be_instance_of(error_class)
        expect(error.call_kind).to eq(:bind)
        expect(insert).to eq("fake-bc-1")
      end
    end

    it "注入した失敗でも、台帳へ同じ単価で記帳する（呼び出しは、YouTube へ届いたものとして扱う）" do
      gateway.fail_next(:transient)

      failure_of { gateway.bind(connection, "fake-bc-1", "fake-stream-1", broadcast: broadcast) }

      expect(ledger_entries).to eq([ [ "liveBroadcasts.bind", 50, "prep", "ok" ] ])
    end

    it "quota_exceeded: 台帳に超過の印が付く（実物と同じ）" do
      gateway.fail_next(:quota_exceeded)

      failure_of { insert }

      expect(QuotaDay.find(day).exhausted).to be(true)
    end

    it "times: 続けて失敗させる回数" do
      gateway.fail_next(:transient, times: 2)

      errors = Array.new(3) { failure_of { status_of("fake-bc-1") } }

      expect(errors.map { |error| error&.class }).to eq([ YouTubeErrors::Transient, YouTubeErrors::Transient, nil ])
    end

    it "on: 公開メソッドの名前で限る。ほかの呼び出しは通り、注入は残る" do
      gateway.fail_next(:rate_limited, on: :bind)
      id = insert
      stream = gateway.ensure_stream(connection, broadcast: broadcast)

      error = failure_of { gateway.bind(connection, id, stream.stream_id, broadcast: broadcast) }
      bound = gateway.bind(connection, id, stream.stream_id, broadcast: broadcast)

      expect(error).to be_instance_of(YouTubeErrors::RateLimited)
      expect(bound).to be(true)
    end

    it "on: ensure_stream は、確認と作成のどちらの呼び出しにも当たる。内部の種別（create_stream）で、作成だけを限れる" do
      gateway.fail_next(:transient, on: :create_stream)
      create_error = failure_of { gateway.ensure_stream(connection, broadcast: broadcast) }

      connection.update!(youtube_stream_id: "fake-stream-99")
      gateway.fail_next(:transient, on: :ensure_stream)
      check_error = failure_of { gateway.ensure_stream(connection, broadcast: broadcast) }

      expect(create_error).to be_instance_of(YouTubeErrors::Transient).and have_attributes(call_kind: :create_stream)
      expect(check_error).to be_instance_of(YouTubeErrors::Transient).and have_attributes(call_kind: :check_stream)
    end

    it "on の未知の名前・不正な回数・未知の注入は ArgumentError（黙って無視しない）" do
      expect { gateway.fail_next(:transient, on: :unknown_call) }.to raise_error(ArgumentError, /on/)
      expect { gateway.fail_next(:transient, times: 0) }.to raise_error(ArgumentError, /times/)
      expect { gateway.fail_next(:other) }.to raise_error(ArgumentError, /error/)
    end

    describe "トークンの失敗（TokenVault を通る）" do
      it "token_revoked: 次のトークンの取得が TokenRevoked。接続状態は revoked になる（TokenVault の動作）。YouTube は呼ばれず、記帳もされない" do
        gateway.fail_next(:token_revoked)

        error = failure_of { insert }

        expect(error).to be_instance_of(YouTubeErrors::TokenRevoked)
        expect(YoutubeConnection.find(connection.id).state).to eq("revoked")
        expect(api.broadcast_ids).to be_empty
        expect(QuotaEntry.count).to eq(0)
      end

      it "token_temporarily_unavailable: TokenTemporarilyUnavailable。状態は変わらない。その次は成功する" do
        gateway.fail_next(:token_temporarily_unavailable)

        error = failure_of { insert }

        expect(error).to be_instance_of(YouTubeErrors::TokenTemporarilyUnavailable)
        expect(YoutubeConnection.find(connection.id).state).to eq("connected")
        expect(insert).to eq("fake-bc-1")
      end

      it "すでにアクセストークンがキャッシュされていても、注入は次の呼び出しで効く（キャッシュを捨てる）" do
        insert
        gateway.fail_next(:token_revoked)

        expect(failure_of { insert }).to be_instance_of(YouTubeErrors::TokenRevoked)
      end

      it "呼び出しの種別では限れない（トークンは、どの呼び出しの前にも取得する）: on を渡すと ArgumentError" do
        expect { gateway.fail_next(:token_revoked, on: :bind) }.to raise_error(ArgumentError, /on/)
      end

      it "トークンのクライアント・キャッシュを渡していなければ、トークンの失敗は注入できない（ArgumentError）" do
        bare = described_class.new(token_vault: vault, api: api, api_base: api_base, stream_title: "Browser Live", environment: test_environment, clock: clock)

        expect { bare.fail_next(:token_revoked) }.to raise_error(ArgumentError, /token_client/)
      end
    end
  end

  describe "台帳（実物と同じ経路・同じ単価）" do
    it "準備から清算までの記帳が、実物の窓口と同じ（種別・単価・枠）" do
      id = insert
      stream = gateway.ensure_stream(connection, broadcast: broadcast)
      gateway.bind(connection, id, stream.stream_id, broadcast: broadcast)
      advance(5)
      status_of(id)
      gateway.fetch_stream_health(connection, stream.stream_id, broadcast: broadcast)
      gateway.complete(connection, id, broadcast: broadcast, bucket: :settle)
      status_of(id, bucket: :settle)
      gateway.delete(connection, id, broadcast: broadcast, bucket: :settle)

      expect(ledger_entries).to contain_exactly(
        [ "liveBroadcasts.insert", 50, "prep", "ok" ], [ "liveStreams.insert", 50, "prep", "ok" ], [ "liveBroadcasts.bind", 50, "prep", "ok" ],
        [ "liveBroadcasts.list", 1, "prep", "ok" ], [ "liveStreams.list", 1, "prep", "ok" ],
        [ "liveBroadcasts.transition", 50, "settle", "ok" ], [ "liveBroadcasts.list", 1, "settle", "ok" ], [ "liveBroadcasts.delete", 50, "settle", "ok" ]
      )
      expect_whole_ledger_consistent
    end

    it "枠が足りなければ QuotaInsufficient。疑似の YouTube にも届かない（配信が作られない）" do
      QuotaLedger.spend!(broadcast, method: "liveBroadcasts.list", units: 340, bucket: :prep, result: "ok", now: start_time)

      expect { insert }.to raise_error(YouTubeErrors::QuotaInsufficient)

      expect(api.broadcast_ids).to be_empty
    end

    it "トランザクションの内側では呼べない（実物と同じ）" do
      ApplicationRecord.transaction do
        expect { insert }.to raise_error(YouTubeGateway::InsideTransaction)
      end
    end
  end

  describe "共有と初期化" do
    it "同じ Api を共有する 2 つの窓口は、同じ疑似の YouTube を見る（要求ごとに窓口を作っても、状態が続く）" do
      id = insert
      other = build_fake(api: api)

      expect(other.fetch_status(connection, id, broadcast: broadcast, bucket: :prep)).to have_attributes(value: "created")
    end

    it "reset!: 配信・ストリーム・注入・トークンの番号を初期状態へ戻す（識別子が 1 から）" do
      insert
      gateway.ensure_stream(connection, broadcast: broadcast)
      gateway.fail_next(:transient)

      gateway.reset!

      expect(api.broadcast_ids).to be_empty
      expect(api.stream_ids).to be_empty
      expect(insert).to eq("fake-bc-1")
    end

    it "api を取り出せる（テストが状態を確かめる）" do
      expect(gateway.api).to equal(api)
    end
  end

  describe "ログ" do
    it "疑似でも、失敗は窓口のログ（符号と内部の識別子）。タイトル・配信キー・トークンを出さない" do
      gateway.fail_next(:live_not_enabled)

      output = capture_logs { failure_of { insert } }

      expect(output).to include("[youtube_gateway] failed call=insert_broadcast")
      [ title_value, "fake-key-1", "fake-access-token" ].each { |secret| expect(output).not_to include(secret) }
    end
  end
end
