require "rails_helper"
require "support/external_http_support"
require "support/google_oidc_support"

# 外部サービス（Google ログイン・bot 判定）の実装の選択（issue #8。CLAUDE.md「環境の判定を実装して分岐できるようにする」）。
#   AppEnvironment#external_services が :fake（開発・テスト）なら疑似、:live（本番）なら実物。
#   本番は常に実物（環境変数では決めない。環境変数の名前を増やさない）。本番で疑似が選ばれないこと・構築できないことを検査する。
RSpec.describe ExternalServices do
  include GoogleOidcSupport

  let(:production) { AppEnvironment.new("production") }
  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:live_env) do
    { "GOOGLE_CLIENT_ID" => GoogleOidcSupport::CLIENT_ID, "GOOGLE_CLIENT_SECRET" => GoogleOidcSupport::CLIENT_SECRET, "RECAPTCHA_SECRET_KEY" => "dummy-recaptcha-secret-key" }
  end

  describe ".config（config/external_services.yml）" do
    let(:config) { described_class.config }

    it "Google の OIDC・reCAPTCHA・疑似の Google の設定を持つ" do
      expect(config.keys).to match_array(%i[ google_oidc recaptcha fake_google ])
      expect(config.fetch(:google_oidc).keys).to match_array(%i[ authorization_endpoint token_endpoint jwks_uri issuers jwks_cache_seconds jwks_min_refetch_seconds ])
      expect(config.fetch(:recaptcha).keys).to eq(%i[ siteverify_endpoint ])
      expect(config.fetch(:fake_google).keys).to match_array(%i[ accounts authorize_path code_lifetime_seconds ])
    end

    it "外部サービスの URL は、すべて https で、既知のホスト" do
      urls = [
        config.fetch(:google_oidc).fetch(:authorization_endpoint), config.fetch(:google_oidc).fetch(:token_endpoint),
        config.fetch(:google_oidc).fetch(:jwks_uri), config.fetch(:recaptcha).fetch(:siteverify_endpoint)
      ]

      expect(urls.map { |url| URI.parse(url).scheme }.uniq).to eq([ "https" ])
      expect(urls.map { |url| URI.parse(url).host }).to eq(%w[ accounts.google.com oauth2.googleapis.com www.googleapis.com www.google.com ])
    end

    it "iss は 2 つの形（https://accounts.google.com・accounts.google.com）" do
      expect(config.fetch(:google_oidc).fetch(:issuers)).to eq([ "https://accounts.google.com", "accounts.google.com" ])
    end

    it "資格情報（クライアント ID・秘密値）を含まない" do
      text = Rails.root.join("config/external_services.yml").read

      expect(text).not_to match(/client_secret|client_id|secret_key|password/i)
    end

    it "凍結されている（呼び出し側が書き換えられない）" do
      expect(config).to be_frozen
      expect(config.fetch(:google_oidc)).to be_frozen
      expect(config.fetch(:google_oidc).fetch(:issuers)).to be_frozen
    end

    it "環境ごとの違いは無い（shared のみ）。開発・テスト・本番で同じ URL" do
      yaml = YAML.safe_load_file(Rails.root.join("config/external_services.yml"), permitted_classes: [], aliases: false)

      expect(yaml.keys).to eq([ "shared" ])
    end
  end

  describe ".build（環境の判定による選択）" do
    {
      "development" => [ FakeGoogleOidc, FakeRecaptchaVerifier ],
      "test" => [ FakeGoogleOidc, FakeRecaptchaVerifier ],
      "production" => [ GoogleOidcClient, RecaptchaVerifier ]
    }.each do |name, (oidc_class, recaptcha_class)|
      it "#{name}: #{oidc_class.name} と #{recaptcha_class.name}" do
        gateways = described_class.build(AppEnvironment.new(name), env: live_env)

        expect(gateways.google_oidc).to be_instance_of(oidc_class)
        expect(gateways.recaptcha_verifier).to be_instance_of(recaptcha_class)
      end
    end

    it "本番は、疑似の実装を選ばない（疑似のクラスのインスタンスではない）" do
      gateways = described_class.build(production, env: live_env)

      expect(gateways.google_oidc).not_to be_a(FakeGoogleOidc)
      expect(gateways.recaptcha_verifier).not_to be_a(FakeRecaptchaVerifier)
    end

    it "本番の選択は、環境変数で変えられない（疑似を指す名前の環境変数があっても、実物）" do
      env = live_env.merge(
        "EXTERNAL_SERVICES" => "fake", "FAKE_GOOGLE" => "1", "USE_FAKE_SERVICES" => "true", "RAILS_ENV" => "development", "RACK_ENV" => "test",
        "DEV_LOGIN" => "1"
      )

      gateways = described_class.build(production, env: env)

      expect(gateways.google_oidc).to be_instance_of(GoogleOidcClient)
      expect(gateways.recaptcha_verifier).to be_instance_of(RecaptchaVerifier)
    end

    it "本番で資格情報が欠けていても、疑似へ倒さない（例外。欠けている変数の名前だけを書く）" do
      expect { described_class.build(production, env: {}) }
        .to raise_error(ExternalServices::MissingConfiguration, "required environment variables are missing: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, RECAPTCHA_SECRET_KEY")
    end

    it "空・空白だけの値も、欠けているとみなす。値は例外に書かない" do
      env = { "GOOGLE_CLIENT_ID" => "dummy-id-must-not-appear", "GOOGLE_CLIENT_SECRET" => "  ", "RECAPTCHA_SECRET_KEY" => "" }

      expect { described_class.build(production, env: env) }.to raise_error(ExternalServices::MissingConfiguration) { |error|
        expect(error.names).to eq(%w[ GOOGLE_CLIENT_SECRET RECAPTCHA_SECRET_KEY ])
        expect(error.message).not_to include("dummy-id-must-not-appear")
      }
    end

    it "開発・テストは、資格情報が無くても構築できる（疑似を使う）" do
      %w[ development test ].each do |name|
        expect { described_class.build(AppEnvironment.new(name), env: {}) }.not_to raise_error
      end
    end

    it "選択が :live・:fake のどちらでもなければ、例外にする（既定の実装へ倒さない）" do
      odd = instance_double(AppEnvironment, external_services: :other, name: :odd)

      expect { described_class.build(odd, env: live_env) }.to raise_error(ExternalServices::UnknownSelection, /other/)
    end

    it "構築のたびに、新しい実装を返す（要求ごとに作る。状態を持たないもの）" do
      first = described_class.build(AppEnvironment.new("test"), env: {})
      second = described_class.build(AppEnvironment.new("test"), env: {})

      expect(first.google_oidc).not_to equal(second.google_oidc)
    end

    it "疑似の Google は、アプリケーションの秘密値（SESSION_SECRET = secret_key_base）から鍵を導出する" do
      gateways = described_class.build(AppEnvironment.new("test"), env: {})
      verifier = "dummy-code-verifier-0123456789-abcdefghijklmnopqrstuvwxyz"
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      redirect = "https://app.example.test/api/auth/callback"
      code = gateways.google_oidc.issue_code(sub: "dev-user-1", nonce: "n", code_challenge: challenge, redirect_uri: redirect, now: now)
      same_secret = FakeGoogleOidc.new(secret: Rails.application.secret_key_base)

      identity = same_secret.authenticate(code: code, code_verifier: verifier, nonce: "n", redirect_uri: redirect, now: now)

      expect(identity.sub).to eq("dev-user-1")
    end
  end

  describe ".current（現在の環境の実装）" do
    it "テストの環境では、疑似（開発・テストの環境の判定）" do
      gateways = described_class.current

      expect(gateways.google_oidc).to be_instance_of(FakeGoogleOidc)
      expect(gateways.recaptcha_verifier).to be_instance_of(FakeRecaptchaVerifier)
    end

    it "環境の判定（AppEnvironment.current）が本番なら、実物を返す（環境変数 ENV を読む）" do
      allow(AppEnvironment).to receive(:current).and_return(production)
      stub_const("ENV", live_env)

      gateways = described_class.current

      expect(gateways.google_oidc).to be_instance_of(GoogleOidcClient)
      expect(gateways.recaptcha_verifier).to be_instance_of(RecaptchaVerifier)
    end

    it "本番で資格情報が欠けていれば、例外（疑似へ倒さない）" do
      allow(AppEnvironment).to receive(:current).and_return(production)
      stub_const("ENV", {})

      expect { described_class.current }.to raise_error(ExternalServices::MissingConfiguration)
    end
  end

  describe "実物の部品の組み立て（本番の構成）" do
    let(:gateways) { described_class.build(production, env: live_env) }

    it "公開鍵（JWKS）のキャッシュは、プロセスで 1 つ（構築のたびに取得し直さない）" do
      first = described_class.build(production, env: live_env).google_oidc
      second = described_class.build(production, env: live_env).google_oidc

      expect(first.jwks_cache).to equal(second.jwks_cache)
      expect(first.jwks_cache).to equal(described_class.shared_jwks_cache)
    end

    it "実物の Google ログインの認可 URL は、設定ファイルの URL と、環境変数のクライアント ID" do
      client = gateways.google_oidc
      url = client.authorization_url(state: "s", nonce: "n", code_challenge: "c", redirect_uri: "https://app.example.test/api/auth/callback")

      expect(url).to start_with("#{google_config.fetch(:authorization_endpoint)}?")
      expect(url).to include("client_id=#{CGI.escape(GoogleOidcSupport::CLIENT_ID)}")
    end

    it "実物の bot 判定は、現在の設定値（system_settings の bot_score_threshold）を、判定のたびに読む" do
      endpoint = described_class.config.fetch(:recaptcha).fetch(:siteverify_endpoint)
      body = JSON.generate("success" => true, "score" => 0.7, "action" => "login", "challenge_ts" => (now - 3).iso8601, "hostname" => "app.example.test")
      stub_request(:post, endpoint).to_return(status: 200, body: body)
      verify = -> { gateways.recaptcha_verifier.verify(token: "dummy-token", expected_action: "login", hostname: "app.example.test", now: now) }

      expect(verify.call).to eq(:pass) # 既定の閾値 0.5
      SystemSetting.create!(key: "bot_score_threshold", value: "0.8")
      expect(verify.call).to eq(:fail)
      SystemSetting.find("bot_score_threshold").update!(value: "0.6")
      expect(verify.call).to eq(:pass)
    end

    it "設定値が壊れていれば、既定値で続行せず、例外（判定不能へも丸めない）" do
      endpoint = described_class.config.fetch(:recaptcha).fetch(:siteverify_endpoint)
      body = JSON.generate("success" => true, "score" => 0.7, "action" => "login", "challenge_ts" => (now - 3).iso8601, "hostname" => "app.example.test")
      stub_request(:post, endpoint).to_return(status: 200, body: body)
      SystemSetting.create!(key: "bot_score_threshold", value: "high")

      expect { gateways.recaptcha_verifier.verify(token: "dummy-token", expected_action: "login", hostname: "app.example.test", now: now) }
        .to raise_error(SettingsStore::CorruptSetting)
    end
  end
end
