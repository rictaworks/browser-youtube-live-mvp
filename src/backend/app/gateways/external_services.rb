# 外部サービス（Google ログイン・bot 判定）の実装の選択と、設定の読み込み（issue #8。CLAUDE.md「環境の判定を実装して分岐できるようにする」）。
#
# 使う実装は、環境の判定（AppEnvironment#external_services）で決める。環境変数では決めない（環境変数の名前を増やさない）。
#   :fake（開発・テスト）  FakeGoogleOidc・FakeRecaptchaVerifier。実際の Google・reCAPTCHA を呼ばない。資格情報は要らない
#   :live（本番）          GoogleOidcClient・RecaptchaVerifier。常に実物。資格情報（GOOGLE_CLIENT_ID・GOOGLE_CLIENT_SECRET・
#                          RECAPTCHA_SECRET_KEY。requirements.md 29.4）が欠けていれば、疑似へ倒さず、例外にする
# 本番で疑似が使われることを、三重に防ぐ: ① この選択 ② 疑似の構築時の環境の検査（FakeServices） ③ 疑似の経路（/api/dev/）を本番で描かない
# （config/routes.rb）。
#
# URL と付随する固定値は config/external_services.yml（コードに直書きしない）。資格情報は、そこに書かない。
module ExternalServices
  CONFIG_NAME = :external_services
  # 実物に要る環境変数（requirements.md 29.4）
  LIVE_ENV_NAMES = %w[ GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET RECAPTCHA_SECRET_KEY ].freeze

  # 実物の資格情報が、環境変数に無い（欠けている・空）。メッセージは、変数の名前だけ（値を書かない）
  class MissingConfiguration < StandardError
    attr_reader :names

    def initialize(names)
      @names = names.dup.freeze
      super("required environment variables are missing: #{@names.join(', ')}")
    end
  end

  # 環境の判定が、:live・:fake のどちらでもない（既定の実装へ倒さない）
  class UnknownSelection < StandardError; end

  # 使う実装の組
  Gateways = Data.define(:google_oidc, :recaptcha_verifier)

  JWKS_LOCK = Mutex.new
  private_constant :JWKS_LOCK

  class << self
    # config/external_services.yml の shared（URL と、それに付随する固定値）。深く凍結してある
    def config
      @config ||= deep_freeze(Rails.application.config_for(CONFIG_NAME))
    end

    # 現在の環境（AppEnvironment.current）の実装。要求ごとに呼んでよい（状態を持たない。公開鍵のキャッシュだけが、プロセスで共有される）
    def current
      build(AppEnvironment.current)
    end

    # environment（AppEnvironment）の判定で、実装を選んで作る。env は環境変数（実物の資格情報を、ここから読む）
    def build(environment = AppEnvironment.current, env: ENV)
      case environment.external_services
      when :live then live(env)
      when :fake then fake
      else raise UnknownSelection, "external services selection is neither live nor fake: #{environment.external_services.inspect}"
      end
    end

    # 公開鍵（JWKS）のキャッシュ。プロセスで 1 つ（Google ログインのたびに取得し直さない）
    def shared_jwks_cache
      JWKS_LOCK.synchronize do
        @shared_jwks_cache ||= GoogleJwksCache.new(
          http: ExternalHttp.new,
          jwks_uri: google_config.fetch(:jwks_uri),
          ttl_seconds: google_config.fetch(:jwks_cache_seconds),
          min_refetch_seconds: google_config.fetch(:jwks_min_refetch_seconds)
        )
      end
    end

    private

    def google_config
      config.fetch(:google_oidc)
    end

    def live(env)
      missing = LIVE_ENV_NAMES.select { |name| env[name].to_s.strip.empty? }
      raise MissingConfiguration.new(missing) unless missing.empty?

      http = ExternalHttp.new
      Gateways.new(
        google_oidc: GoogleOidcClient.new(
          client_id: env.fetch("GOOGLE_CLIENT_ID"), client_secret: env.fetch("GOOGLE_CLIENT_SECRET"),
          http: http, endpoints: google_config, jwks_cache: shared_jwks_cache
        ),
        recaptcha_verifier: RecaptchaVerifier.new(
          secret: env.fetch("RECAPTCHA_SECRET_KEY"), endpoint: config.fetch(:recaptcha).fetch(:siteverify_endpoint),
          settings_source: SettingsStore.method(:current), http: http
        )
      )
    end

    def fake
      Gateways.new(
        google_oidc: FakeGoogleOidc.new(secret: Rails.application.secret_key_base),
        recaptcha_verifier: FakeRecaptchaVerifier.new
      )
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each_value { |item| deep_freeze(item) }
      when Array
        value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end
  end
end
