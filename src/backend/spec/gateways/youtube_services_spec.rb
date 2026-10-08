require "rails_helper"
require "support/youtube_gateway_support"

# YouTube の窓口・TokenVault の実装の選択（issue #10。CLAUDE.md「環境の判定を実装して分岐できるようにする」）。ExternalServices（#8）と同じ方式。
#   AppEnvironment#external_services が :fake（開発・テスト）なら疑似（FakeYouTubeGateway・FakeGoogleTokenClient）、:live（本番）なら実物（YouTubeGateway・GoogleTokenClient）。
#   本番は常に実物（環境変数では決めない）。資格情報（GOOGLE_CLIENT_ID・GOOGLE_CLIENT_SECRET・TOKEN_ENCRYPTION_KEY。requirements.md 29.4）が欠けていれば、疑似へ倒さず、例外にする。
#   アクセストークンのキャッシュと、疑似の YouTube の状態は、プロセスで共有する（要求ごとに作っても、重複排除と状態が続く）。
RSpec.describe YouTubeServices do
  include LedgerSupport
  include YouTubeGatewaySupport

  let(:production) { AppEnvironment.new("production") }
  let(:key) { "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
  let(:dev_env) { { "TOKEN_ENCRYPTION_KEY" => key } }
  let(:live_env) { dev_env.merge("GOOGLE_CLIENT_ID" => "dummy-client-id-0001.apps.googleusercontent.com", "GOOGLE_CLIENT_SECRET" => "dummy-google-client-secret-0001") }

  before { described_class.reset_shared! }
  after { described_class.reset_shared! }

  describe ".build（環境の判定による選択）" do
    {
      "development" => [ FakeYouTubeGateway, FakeGoogleTokenClient ],
      "test" => [ FakeYouTubeGateway, FakeGoogleTokenClient ]
    }.each do |name, (gateway_class, _)|
      it "#{name}: #{gateway_class.name}（疑似）。資格情報は、暗号鍵だけでよい" do
        services = described_class.build(AppEnvironment.new(name), env: dev_env)

        expect(services.youtube_gateway).to be_instance_of(gateway_class)
        expect(services.token_vault).to be_instance_of(TokenVault)
      end
    end

    it "production: 実物の YouTubeGateway（疑似の子クラスではない）と TokenVault" do
      services = described_class.build(production, env: live_env)

      expect(services.youtube_gateway).to be_instance_of(YouTubeGateway)
      expect(services.youtube_gateway).not_to be_a(FakeYouTubeGateway)
      expect(services.token_vault).to be_instance_of(TokenVault)
    end

    it "本番の選択は、環境変数で変えられない（疑似を指す名前の環境変数があっても、実物）" do
      env = live_env.merge("EXTERNAL_SERVICES" => "fake", "FAKE_YOUTUBE" => "1", "USE_FAKE_SERVICES" => "true", "RAILS_ENV" => "development", "RACK_ENV" => "test", "DEV_LOGIN" => "1")

      expect(described_class.build(production, env: env).youtube_gateway).to be_instance_of(YouTubeGateway)
    end

    it "本番で資格情報が欠けていても、疑似へ倒さない（例外。欠けている変数の名前だけを書く）" do
      expect { described_class.build(production, env: {}) }
        .to raise_error(ExternalServices::MissingConfiguration, "required environment variables are missing: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, TOKEN_ENCRYPTION_KEY")
    end

    it "空・空白だけの値も、欠けているとみなす。値は例外に書かない" do
      env = { "GOOGLE_CLIENT_ID" => "dummy-id-must-not-appear", "GOOGLE_CLIENT_SECRET" => "  ", "TOKEN_ENCRYPTION_KEY" => "" }

      expect { described_class.build(production, env: env) }.to raise_error(ExternalServices::MissingConfiguration) { |error|
        expect(error.names).to eq(%w[ GOOGLE_CLIENT_SECRET TOKEN_ENCRYPTION_KEY ])
        expect(error.message).not_to include("dummy-id-must-not-appear")
      }
    end

    it "開発・テストでも、暗号鍵が無ければ例外（鍵の無い疑似で、暗号化の経路を飛ばさない）。形式の誤りは InvalidKey（鍵の値を出さない）" do
      expect { described_class.build(AppEnvironment.new("test"), env: {}) }
        .to raise_error(ExternalServices::MissingConfiguration, "required environment variables are missing: TOKEN_ENCRYPTION_KEY")
      expect { described_class.build(AppEnvironment.new("test"), env: { "TOKEN_ENCRYPTION_KEY" => "too-short" }) }
        .to raise_error(TokenVault::InvalidKey) { |error| expect(error.message).not_to include("too-short") }
      expect { described_class.build(production, env: live_env.merge("TOKEN_ENCRYPTION_KEY" => "g" * 64)) }.to raise_error(TokenVault::InvalidKey)
    end

    it "選択が :live・:fake のどちらでもなければ、例外にする（既定の実装へ倒さない）" do
      odd = instance_double(AppEnvironment, external_services: :other, name: :odd)

      expect { described_class.build(odd, env: live_env) }.to raise_error(ExternalServices::UnknownSelection, /other/)
    end

    it "環境を省くと現在の環境（テストでは疑似）。env を省くと ENV" do
      stub_const("ENV", ENV.to_hash.merge("TOKEN_ENCRYPTION_KEY" => key))

      expect(described_class.current.youtube_gateway).to be_instance_of(FakeYouTubeGateway)
    end

    it "構築のたびに、新しい窓口・保管庫を返す（要求ごとに作る）。ただし共有するもの（キャッシュ・疑似の状態）は同じ" do
      first = described_class.build(AppEnvironment.new("test"), env: dev_env)
      second = described_class.build(AppEnvironment.new("test"), env: dev_env)

      expect(first.youtube_gateway).not_to equal(second.youtube_gateway)
      expect(first.token_vault).not_to equal(second.token_vault)
      expect(first.youtube_gateway.api).to equal(second.youtube_gateway.api)
    end
  end

  describe "プロセスで共有するもの" do
    it "アクセストークンのキャッシュは、実物でも疑似でも、プロセスで 1 つ（要求ごとに作る TokenVault が、同じキャッシュを使う）" do
      cache = described_class.shared_access_token_cache

      expect(described_class.shared_access_token_cache).to equal(cache)
      expect(cache).to be_a(TokenVault::AccessTokenCache)
    end

    it "実物の TokenVault を 2 つ作っても、同じキャッシュを使うので、アクセストークンの更新は 1 回（Google への通信が 1 回）" do
      user = create(:user)
      first = described_class.build(production, env: live_env)
      second = described_class.build(production, env: live_env)
      first.token_vault.store(user_id: user.id, refresh_token: "1//dummy-refresh-token", now: Time.utc(2026, 10, 8, 3, 0, 0))
      stub = stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: { "access_token" => "ya29.dummy-1", "expires_in" => 3600 }.to_json)

      tokens = [ first, second ].map { |services| services.token_vault.access_token(user_id: user.id, now: Time.utc(2026, 10, 8, 3, 0, 0)) }

      expect(tokens).to eq([ "ya29.dummy-1", "ya29.dummy-1" ])
      expect(stub).to have_been_requested.once
    end

    it "疑似の YouTube と疑似の Google は、プロセスで 1 つ（状態と注入が続く）。reset_shared! で作り直す" do
      first = described_class.build(AppEnvironment.new("test"), env: dev_env).youtube_gateway
      api = first.api

      described_class.reset_shared!
      second = described_class.build(AppEnvironment.new("test"), env: dev_env).youtube_gateway

      expect(second.api).not_to equal(api)
      expect(described_class.build(AppEnvironment.new("test"), env: dev_env).youtube_gateway.api).to equal(second.api)
    end

    it "疑似の窓口で注入した失敗が、次に作った窓口にも続く（要求ごとに作っても、注入が消えない）" do
      user = create(:user)
      services = described_class.build(AppEnvironment.new("test"), env: dev_env)
      services.token_vault.store(user_id: user.id, refresh_token: "1//dummy-refresh-token", now: Time.current)
      connection = YoutubeConnection.find_by!(user_id: user.id)
      broadcast = create_reserved_broadcast(quota_date: UsageCalendar.quota_date(Time.current), user: user)
      services.youtube_gateway.fail_next(:transient)

      next_gateway = described_class.build(AppEnvironment.new("test"), env: dev_env).youtube_gateway

      expect { next_gateway.fetch_status(connection, "fake-bc-1", broadcast: broadcast, bucket: :prep) }.to raise_error(YouTubeErrors::Transient)
    end
  end

  describe "実物の窓口の組み立て（設定ファイル config/external_services.yml）" do
    let(:user) { create(:user) }
    let(:now) { Time.current }
    let(:services) { described_class.build(production, env: live_env) }

    before do
      services.token_vault.store(user_id: user.id, refresh_token: "1//dummy-refresh-token", now: now)
      stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: { "access_token" => access_token_value, "expires_in" => 3600 }.to_json)
    end

    def prepared_broadcast
      create_reserved_broadcast(quota_date: UsageCalendar.quota_date(now), user: user)
    end

    it "YouTube の API の基底の URL は、設定の youtube.api_base。トークンの更新は、設定の google_oidc.token_endpoint。アクセストークンで Authorization を付ける" do
      connection = YoutubeConnection.find_by!(user_id: user.id)
      stub = stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including("id" => youtube_broadcast_id), headers: { "Authorization" => "Bearer #{access_token_value}" })
                                                          .to_return(list_response(broadcast_resource(life_cycle_status: "live")))

      status = services.youtube_gateway.fetch_status(connection, youtube_broadcast_id, broadcast: prepared_broadcast, bucket: :prep)

      expect(status).to be_live
      expect(stub).to have_been_requested.once
    end

    it "取り込み先は、本番の許可リスト（疑似の取り込み口を通さない）" do
      connection = YoutubeConnection.find_by!(user_id: user.id)
      stub_request(:post, api_url("liveStreams")).with(query: hash_including({})).to_return(json_response(stream_resource(rtmps: "rtmps://fake-ingest:1935/live2")))

      expect { services.youtube_gateway.ensure_stream(connection, broadcast: prepared_broadcast) }.to raise_error(IngestDestination::Invalid)
    end

    it "応答の本文の上限は、設定の youtube.max_response_bytes（既定の 1 MiB より大きい）。一覧（50 件）の長い説明文を受け取れる" do
      connection = YoutubeConnection.find_by!(user_id: user.id)
      padded = { "kind" => "youtube#liveBroadcastListResponse", "items" => [], "padding" => "x" * 1_500_000 }
      stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(json_response(padded))

      expect(services.youtube_gateway.list_unstarted_broadcasts(connection, broadcast: prepared_broadcast)).to eq([])
      expect(ExternalServices.config.fetch(:youtube).fetch(:max_response_bytes)).to be > ExternalHttp::MAX_BODY_BYTES
    end

    it "設定の上限を超える応答は UnexpectedResponse（response_too_large）" do
      connection = YoutubeConnection.find_by!(user_id: user.id)
      limit = ExternalServices.config.fetch(:youtube).fetch(:max_response_bytes)
      stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(status: 200, body: "x" * (limit + 1))

      expect { services.youtube_gateway.list_unstarted_broadcasts(connection, broadcast: prepared_broadcast) }
        .to raise_error(YouTubeErrors::UnexpectedResponse) { |error| expect(error.detail).to eq(:response_too_large) }
    end
  end

  describe "ExternalServices（#8）との関係" do
    it "ExternalServices::Gateways のメンバーを増やさない（#8 の use_gateways などの利用者を壊さない）" do
      expect(ExternalServices::Gateways.members).to eq(%i[ google_oidc recaptcha_verifier ])
    end

    it "同じ環境の判定（AppEnvironment#external_services）で選ぶ" do
      %w[ development test production ].each do |name|
        environment = AppEnvironment.new(name)
        services = described_class.build(environment, env: live_env)
        fake = services.youtube_gateway.is_a?(FakeYouTubeGateway)

        expect(fake).to eq(environment.external_services == :fake), "environment #{name}"
      end
    end
  end
end
