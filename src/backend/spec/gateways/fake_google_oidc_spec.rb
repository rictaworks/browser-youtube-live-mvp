require "rails_helper"
require "support/google_oidc_support"
require "support/log_capture"

# 疑似の Google ログイン FakeGoogleOidc（issue #8）。開発・テストのみ。GoogleOidcClient と同じ使い方で、外部サービスを呼ばない。
#   認可 URL の行き先だけを、自プロセスの疑似の認可画面（/api/dev/google/authorize）へ差し替える（ほかのパラメータは本物と同じ）。
#   認可コードは、sub・nonce・PKCE の challenge・redirect_uri・期限を含む（ステートレス。認証つき）。固定の 3 アカウントだけ。
#   authenticate は、本物と同じ検証（PKCE・nonce・redirect_uri・期限）を行い、Identity（sub）を返す。
# 本番では構築できない（FakeServices）。
RSpec.describe FakeGoogleOidc do
  include GoogleOidcSupport

  let(:secret) { "dummy-secret-key-base-for-fake-google-0001" }
  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:challenge) { s256_challenge(code_verifier) }
  let(:fake) { described_class.new(secret: secret) }
  let(:fake_config) { ExternalServices.config.fetch(:fake_google) }

  def issue(sub: "dev-user-1", nonce: nonce_value, code_challenge: challenge, redirect: redirect_uri, at: now)
    fake.issue_code(sub: sub, nonce: nonce, code_challenge: code_challenge, redirect_uri: redirect, now: at)
  end

  def authenticate(code, verifier: code_verifier, nonce: nonce_value, redirect: redirect_uri, at: now)
    fake.authenticate(code: code, code_verifier: verifier, nonce: nonce, redirect_uri: redirect, now: at)
  end

  def expect_failure(reason, &block)
    expect(&block).to raise_error(GoogleOidc::AuthenticationFailed) { |error|
      expect(error.reason).to eq(reason), "期待: #{reason} 実際: #{error.reason}"
    }
  end

  describe "固定のアカウント（config/external_services.yml）" do
    it "dev-user-1〜dev-user-3 の 3 つだけ" do
      expect(fake.accounts).to eq(%w[ dev-user-1 dev-user-2 dev-user-3 ])
      expect(fake_config.fetch(:accounts)).to eq(%w[ dev-user-1 dev-user-2 dev-user-3 ])
    end

    it "アカウントの一覧は凍結されている" do
      expect(fake.accounts).to be_frozen
    end
  end

  describe "#authorization_url" do
    let(:url) { fake.authorization_url(state: "dummy-state-0001", nonce: nonce_value, code_challenge: challenge, redirect_uri: redirect_uri) }
    let(:uri) { URI.parse(url) }
    let(:query) { Rack::Utils.parse_query(uri.query) }

    it "行き先は、redirect_uri と同じオリジンの疑似の認可画面（フロントエンドのオリジン。同一オリジン中継を通る）" do
      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq("https://app.example.test/api/dev/google/authorize")
    end

    it "開発の redirect_uri（http・ポートつき）でも、同じオリジンの疑似の認可画面" do
      value = fake.authorization_url(state: "s", nonce: "n", code_challenge: "c", redirect_uri: "http://localhost:3000/api/auth/callback")

      expect(value).to start_with("http://localhost:3000/api/dev/google/authorize?")
    end

    it "パラメータは、本物と同じ（response_type=code・scope=openid・PKCE の S256・state・nonce・redirect_uri）。client_id は無い" do
      expect(query).to eq(
        "response_type" => "code",
        "scope" => "openid",
        "redirect_uri" => redirect_uri,
        "state" => "dummy-state-0001",
        "nonce" => nonce_value,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      )
    end

    it "引数が空・文字列でないときは ArgumentError" do
      valid = { state: "s", nonce: "n", code_challenge: "c", redirect_uri: redirect_uri }
      valid.each_key do |name|
        [ nil, "", "  ", 1 ].each do |bad|
          expect { fake.authorization_url(**valid, name => bad) }.to raise_error(ArgumentError, /#{name}/)
        end
      end
    end

    it "redirect_uri は、オリジンを持つ http・https の URL だけ（相対・別のスキームは ArgumentError）" do
      [ "/api/auth/callback", "ftp://app.example.test/x", "javascript:alert(1)", "//app.example.test/x", "https://" ].each do |bad|
        expect { fake.authorization_url(state: "s", nonce: "n", code_challenge: "c", redirect_uri: bad) }.to raise_error(ArgumentError, /redirect_uri/)
      end
    end
  end

  describe "認可コードの発行と認証（往復）" do
    it "3 つのアカウントのどれでも、sub を持つ Identity が返る" do
      %w[ dev-user-1 dev-user-2 dev-user-3 ].each do |sub|
        identity = authenticate(issue(sub: sub))

        expect(identity).to be_a(GoogleOidc::Identity)
        expect(identity.sub).to eq(sub)
      end
    end

    it "コードは、URL に入れても壊れない文字だけ（base64url と区切りのドット）" do
      expect(issue).to match(/\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/)
    end

    it "コードは、毎回同じ入力なら同じ（ステートレス。サーバーの記憶を持たない）" do
      expect(issue).to eq(issue)
    end

    it "別のインスタンス（同じ秘密値）でも検証できる（プロセスの記憶に依らない）" do
      code = issue

      other = described_class.new(secret: secret)

      expect(other.authenticate(code: code, code_verifier: code_verifier, nonce: nonce_value, redirect_uri: redirect_uri, now: now).sub).to eq("dev-user-1")
    end

    it "固定の 3 つにない sub は、発行できない（ArgumentError）" do
      [ "dev-user-4", "", nil, "DEV-USER-1", "dev-user-1 " ].each do |sub|
        expect { issue(sub: sub) }.to raise_error(ArgumentError, /sub/)
      end
    end

    it "発行の引数の検査（nonce・code_challenge・redirect_uri・now）" do
      expect { issue(nonce: "") }.to raise_error(ArgumentError, /nonce/)
      expect { issue(code_challenge: nil) }.to raise_error(ArgumentError, /code_challenge/)
      expect { issue(redirect: "") }.to raise_error(ArgumentError, /redirect_uri/)
      expect { issue(at: "2026-10-08") }.to raise_error(ArgumentError, /now/)
    end
  end

  describe "認証の失敗（本物の GoogleOidcClient と同じ例外）" do
    it "PKCE の検証子が違う: pkce_mismatch" do
      expect_failure(:pkce_mismatch) { authenticate(issue, verifier: "dummy-other-code-verifier-0123456789-abcdefghijklmnopqrstuvwxyz") }
    end

    it "nonce が違う: nonce_mismatch" do
      expect_failure(:nonce_mismatch) { authenticate(issue, nonce: "dummy-other-nonce") }
    end

    it "redirect_uri が違う: redirect_uri_mismatch" do
      expect_failure(:redirect_uri_mismatch) { authenticate(issue, redirect: "https://evil.example.test/api/auth/callback") }
    end

    it "期限切れ（300 秒）: code_expired。ちょうど期限の時刻から無効、1 秒前は有効" do
      code = issue

      expect(authenticate(code, at: now + 299).sub).to eq("dev-user-1")
      expect_failure(:code_expired) { authenticate(code, at: now + 300) }
      expect_failure(:code_expired) { authenticate(code, at: now + 3600) }
    end

    it "コードの有効期間は、設定の値（300 秒）" do
      expect(fake_config.fetch(:code_lifetime_seconds)).to eq(300)
    end

    it "コードを書き換えた（本文の 1 文字）: code_invalid" do
      code = issue
      payload, mac = code.split(".")
      tampered = "#{payload[0..-2]}#{payload[-1] == 'A' ? 'B' : 'A'}.#{mac}"

      expect_failure(:code_invalid) { authenticate(tampered) }
    end

    it "署名の部分を書き換えた: code_invalid" do
      code = issue
      payload, mac = code.split(".")
      tampered = "#{payload}.#{mac[0..-2]}#{mac[-1] == 'A' ? 'B' : 'A'}"

      expect_failure(:code_invalid) { authenticate(tampered) }
    end

    it "別の sub を名乗る本文に差し替えた（署名はそのまま）: code_invalid" do
      code = issue
      _payload, mac = code.split(".")
      forged = Base64.urlsafe_encode64(JSON.generate("sub" => "dev-user-2", "nonce" => nonce_value, "challenge" => challenge, "redirect_uri" => redirect_uri, "exp" => now.to_i + 300), padding: false)

      expect_failure(:code_invalid) { authenticate("#{forged}.#{mac}") }
    end

    it "別の秘密値で発行したコード: code_invalid" do
      other = described_class.new(secret: "dummy-another-secret-key-base-0002")
      code = other.issue_code(sub: "dev-user-1", nonce: nonce_value, code_challenge: challenge, redirect_uri: redirect_uri, now: now)

      expect_failure(:code_invalid) { authenticate(code) }
    end

    [ "garbage", "a.b", "a.b.c", ".", "..", "x.", ".x", "%%%.%%%", "あ.い" ].each do |garbage|
      it "でたらめなコード（#{garbage.inspect}）: code_invalid" do
        expect_failure(:code_invalid) { authenticate(garbage) }
      end
    end

    it "長すぎるコード: code_invalid" do
      expect_failure(:code_invalid) { authenticate("a" * 5000) }
    end

    it "コード・検証子・nonce・redirect_uri が空・文字列でない: ArgumentError" do
      valid = { code: issue, code_verifier: code_verifier, nonce: nonce_value, redirect_uri: redirect_uri, now: now }
      %i[ code code_verifier nonce redirect_uri ].each do |name|
        [ nil, "", "  ", 1 ].each do |bad|
          expect { fake.authenticate(**valid, name => bad) }.to raise_error(ArgumentError, /#{name}/)
        end
      end
      expect { fake.authenticate(**valid, now: "2026-10-08") }.to raise_error(ArgumentError, /now/)
    end

    it "判定の時刻は、引数の now（実時計を読まない）" do
      code = issue(at: now)

      expect(authenticate(code, at: now).sub).to eq("dev-user-1")
      expect_failure(:code_expired) { authenticate(code, at: now + 1.day) }
    end
  end

  describe "秘密値・コード・sub を出さない" do
    it "例外のメッセージは、理由の符号だけ" do
      code = issue

      expect { authenticate(code, nonce: "dummy-other-nonce") }.to raise_error(GoogleOidc::AuthenticationFailed) { |error|
        expect(error.message).to eq("google authentication failed: nonce_mismatch")
        expect(error.message).not_to include(code)
      }
    end

    it "失敗のログに、理由の符号を出す。コード・検証子・sub は出さない" do
      code = issue

      output = capture_logs { expect_failure(:pkce_mismatch) { authenticate(code, verifier: "dummy-other-code-verifier-0123456789-abcdefghijklmnopqrstuvwxyz") } }

      expect(output).to include("[fake_google]")
      expect(output).to include("reason=pkce_mismatch")
      [ code, code_verifier, "dev-user-1" ].each { |value| expect(output).not_to include(value) }
    end

    it "inspect に、鍵・秘密値を出さない" do
      expect(fake.inspect).not_to include(secret)
    end
  end

  describe "本番では使えない" do
    it "本番の環境の判定では、構築できない（例外）" do
      expect { described_class.new(secret: secret, environment: AppEnvironment.new("production")) }.to raise_error(FakeServices::NotAllowedError, /production/)
    end

    %w[ development test ].each do |name|
      it "#{name} では構築できる" do
        expect { described_class.new(secret: secret, environment: AppEnvironment.new(name)) }.not_to raise_error
      end
    end

    it "既定の環境は、現在の環境（AppEnvironment.current）。本番なら構築できない" do
      allow(AppEnvironment).to receive(:current).and_return(AppEnvironment.new("production"))

      expect { described_class.new(secret: secret) }.to raise_error(FakeServices::NotAllowedError)
    end

    it "秘密値が空では構築できない（ArgumentError）" do
      [ nil, "", "  " ].each do |bad|
        expect { described_class.new(secret: bad) }.to raise_error(ArgumentError, /secret/)
      end
    end
  end
end
