# YouTube の窓口・TokenVault の実装の選択と組み立て（issue #10。CLAUDE.md「環境の判定を実装して分岐できるようにする」）。
# ExternalServices（#8。Google ログイン・bot 判定）と同じ方式で、使う実装は、環境の判定（AppEnvironment#external_services）で決める。環境変数では決めない。
#   :fake（開発・テスト）  FakeYouTubeGateway・FakeGoogleTokenClient。実際の YouTube・Google を呼ばない。資格情報は要らない（暗号鍵 TOKEN_ENCRYPTION_KEY だけ）
#   :live（本番）          YouTubeGateway・GoogleTokenClient。常に実物。資格情報（GOOGLE_CLIENT_ID・GOOGLE_CLIENT_SECRET・TOKEN_ENCRYPTION_KEY。
#                          requirements.md 29.4）が欠けていれば、疑似へ倒さず、例外にする
# 本番で疑似が使われることを、二重に防ぐ: ① この選択 ② 疑似の構築時の環境の検査（FakeServices.verify_environment!）。
#
# ExternalServices::Gateways にメンバーを足さず、別のモジュールにしている（#8 の use_gateways など、Gateways を組み立てる利用者を壊さないため）。
#
# プロセスで共有するもの（要求ごとに build を呼んでもよい。状態を持つものは、ここで 1 つに保つ）
#   アクセストークンのキャッシュ（TokenVault::AccessTokenCache）  同じアカウントの更新を 1 回にまとめ、有効期限内は使い回す（7.3）
#   疑似の YouTube（FakeYouTubeGateway::Api）・疑似の Google（FakeGoogleTokenClient）  作成した配信・ストリームの状態と、失敗の注入が続く
# URL と付随する固定値は config/external_services.yml（コードに直書きしない）。資格情報は、そこに書かない。
module YouTubeServices
  # 組み立てた部品。token_vault は更新トークンの保存・アクセストークンの取得・失効、youtube_gateway は YouTube への単一の窓口
  Services = Data.define(:token_vault, :youtube_gateway)

  # 実物に要る環境変数（requirements.md 29.4）。疑似は、暗号鍵だけ
  LIVE_ENV_NAMES = %w[ GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET TOKEN_ENCRYPTION_KEY ].freeze
  FAKE_ENV_NAMES = %w[ TOKEN_ENCRYPTION_KEY ].freeze

  SHARED_LOCK = Mutex.new
  private_constant :SHARED_LOCK

  class << self
    # 現在の環境（AppEnvironment.current）の実装
    def current(env: ENV)
      build(AppEnvironment.current, env: env)
    end

    # environment（AppEnvironment）の判定で、実装を選んで作る。env は環境変数（資格情報を、ここから読む）
    def build(environment = AppEnvironment.current, env: ENV, logger: Rails.logger)
      case environment.external_services
      when :live then live(environment, env, logger)
      when :fake then fake(environment, env, logger)
      else raise ExternalServices::UnknownSelection, "external services selection is neither live nor fake: #{environment.external_services.inspect}"
      end
    end

    # アクセストークンのキャッシュ（プロセスで 1 つ）
    def shared_access_token_cache
      SHARED_LOCK.synchronize { @shared_access_token_cache ||= TokenVault::AccessTokenCache.new }
    end

    # プロセスで共有するものを、作り直す（テストが、独立した状態から始めるため）。本番のコードは呼ばない
    def reset_shared!
      SHARED_LOCK.synchronize do
        @shared_access_token_cache = nil
        @shared_fake_api = nil
        @shared_fake_token_client = nil
      end
      nil
    end

    private

    def youtube_config
      ExternalServices.config.fetch(:youtube)
    end

    def live(environment, env, logger)
      require_env!(env, LIVE_ENV_NAMES)

      token_client = GoogleTokenClient.new(
        client_id: env.fetch("GOOGLE_CLIENT_ID"), client_secret: env.fetch("GOOGLE_CLIENT_SECRET"), http: ExternalHttp.new,
        endpoints: ExternalServices.config.fetch(:google_oidc), logger: logger
      )
      vault = token_vault(env, token_client, logger)
      gateway = YouTubeGateway.new(
        http: ExternalHttp.new(max_body_bytes: youtube_config.fetch(:max_response_bytes), logger: logger), token_vault: vault,
        api_base: youtube_config.fetch(:api_base), stream_title: youtube_config.fetch(:stream_title), environment: environment, logger: logger
      )
      Services.new(token_vault: vault, youtube_gateway: gateway)
    end

    def fake(environment, env, logger)
      require_env!(env, FAKE_ENV_NAMES)

      token_client = shared_fake_token_client(environment)
      vault = token_vault(env, token_client, logger)
      gateway = FakeYouTubeGateway.new(
        token_vault: vault, api: shared_fake_api, token_client: token_client, access_token_cache: shared_access_token_cache,
        api_base: youtube_config.fetch(:api_base), stream_title: youtube_config.fetch(:stream_title), environment: environment, logger: logger
      )
      Services.new(token_vault: vault, youtube_gateway: gateway)
    end

    def token_vault(env, token_client, logger)
      TokenVault.new(key: env.fetch(TokenVault::KEY_NAME), token_client: token_client, cache: shared_access_token_cache, logger: logger)
    end

    def require_env!(env, names)
      missing = names.select { |name| env[name].to_s.strip.empty? }
      raise ExternalServices::MissingConfiguration.new(missing) unless missing.empty?
    end

    def shared_fake_token_client(environment)
      SHARED_LOCK.synchronize { @shared_fake_token_client ||= FakeGoogleTokenClient.new(environment: environment) }
    end

    # 疑似の YouTube（プロセスで 1 つ）。時計は実時計（SystemClock）。取り込み先は、設定の youtube.dev_ingest
    def shared_fake_api
      SHARED_LOCK.synchronize do
        @shared_fake_api ||= FakeYouTubeGateway::Api.new(
          api_base: youtube_config.fetch(:api_base), ingest: youtube_config.fetch(:dev_ingest), clock: SystemClock.method(:now),
          live_after_seconds: youtube_config.fetch(:fake).fetch(:live_after_seconds), channel_title: youtube_config.fetch(:fake).fetch(:channel_title)
        )
      end
    end
  end
end
