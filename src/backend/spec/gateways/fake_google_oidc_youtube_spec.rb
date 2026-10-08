require "rails_helper"
require "support/google_oidc_support"
require "support/log_capture"

# 疑似の Google（FakeGoogleOidc）の、YouTube 接続用のメソッド（issue #11）。開発・テストのみ。GoogleOidcClient と同じ使い方で、外部サービスを呼ばない。
#   youtube_authorization_url  本物と同じパラメータ（スコープは youtube の 1 種・PKCE・offline・consent・login_hint）。行き先だけを、疑似の同意画面
#                              （/api/dev/google/connect。redirect_uri と同じオリジン）へ差し替える
#   issue_youtube_code         疑似の同意画面が、利用者の選択（種類）に応じて発行する認可コード。PKCE の challenge・redirect_uri・期限を含む（ステートレス。認証つき）
#   exchange_youtube_code      本物と同じ検証（PKCE・redirect_uri・期限）をして、OAuthGrant を返す。種類で、付与の内容が変わる
#   revoke                     受け取ったトークンの失効（疑似は :revoked を返す）
# 本番では構築できない（FakeServices）。コード・検証子・トークンを、ログ・例外に出さない。
RSpec.describe FakeGoogleOidc, "YouTube 接続" do
  include GoogleOidcSupport

  let(:secret) { "dummy-secret-key-base-for-fake-google-0001" }
  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:clock_state) { { now: now } }
  let(:fake) { described_class.new(secret: secret, clock: -> { clock_state[:now] }) }
  let(:challenge) { s256_challenge(code_verifier) }
  let(:callback_uri) { "https://app.example.test/api/youtube/connect/callback" }
  let(:youtube_scope) { "https://www.googleapis.com/auth/youtube" }

  def issue(kind: "full", code_challenge: challenge, redirect: callback_uri, at: now)
    fake.issue_youtube_code(kind: kind, code_challenge: code_challenge, redirect_uri: redirect, now: at)
  end

  def exchange(code, verifier: code_verifier, redirect: callback_uri)
    fake.exchange_youtube_code(code: code, code_verifier: verifier, redirect_uri: redirect)
  end

  def expect_failure(reason, &block)
    expect(&block).to raise_error(GoogleOidc::AuthenticationFailed) { |error|
      expect(error.reason).to eq(reason), "期待: #{reason} 実際: #{error.reason}"
    }
  end

  describe "#youtube_scope" do
    it "設定のスコープを返す（本物と同じ）" do
      expect(fake.youtube_scope).to eq(youtube_scope)
      expect(fake.youtube_scope).to eq(ExternalServices.config.fetch(:google_oidc).fetch(:youtube_scope))
    end
  end

  describe "#youtube_authorization_url" do
    let(:url) do
      fake.youtube_authorization_url(state: "dummy-state-0001", code_challenge: challenge, redirect_uri: callback_uri, login_hint: "dev-user-1")
    end
    let(:uri) { URI.parse(url) }
    let(:query) { Rack::Utils.parse_query(uri.query) }

    it "行き先は、redirect_uri と同じオリジンの疑似の同意画面（フロントエンドのオリジン。同一オリジン中継を通る）" do
      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq("https://app.example.test/api/dev/google/connect")
      expect(described_class::CONNECT_AUTHORIZE_PATH).to eq("/api/dev/google/connect")
    end

    it "開発の redirect_uri（http・ポートつき）でも、同じオリジンの疑似の同意画面" do
      value = fake.youtube_authorization_url(
        state: "s", code_challenge: "c", redirect_uri: "http://localhost:3000/api/youtube/connect/callback", login_hint: "dev-user-1"
      )

      expect(value).to start_with("http://localhost:3000/api/dev/google/connect?")
    end

    it "パラメータは、本物と同じ（スコープは youtube の 1 種・PKCE の S256・offline・consent・login_hint）。client_id は無い" do
      expect(query).to eq(
        "response_type" => "code",
        "scope" => youtube_scope,
        "redirect_uri" => callback_uri,
        "state" => "dummy-state-0001",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "access_type" => "offline",
        "prompt" => "consent",
        "login_hint" => "dev-user-1"
      )
    end

    it "include_granted_scopes も nonce も付けない" do
      expect(query).not_to have_key("include_granted_scopes")
      expect(query).not_to have_key("nonce")
    end

    it "引数が空・文字列でないときは ArgumentError" do
      valid = { state: "s", code_challenge: "c", redirect_uri: callback_uri, login_hint: "h" }
      valid.each_key do |name|
        [ nil, "", "  ", 1 ].each do |bad|
          expect { fake.youtube_authorization_url(**valid, name => bad) }.to raise_error(ArgumentError, /#{name}/)
        end
      end
    end

    it "redirect_uri が http・https の URL でなければ ArgumentError" do
      expect do
        fake.youtube_authorization_url(state: "s", code_challenge: "c", redirect_uri: "javascript:alert(1)", login_hint: "h")
      end.to raise_error(ArgumentError, /redirect_uri/)
    end
  end

  describe "#issue_youtube_code・#exchange_youtube_code" do
    it "種類 full: 更新トークンつきで、youtube のスコープを付与する（OAuthGrant）" do
      grant = exchange(issue(kind: "full"))

      expect(grant).to be_a(OAuthGrant)
      expect(grant.scope?(youtube_scope)).to be(true)
      expect(grant.refresh_token).to be_present
      expect(grant.access_token).to be_present
      expect(grant.expires_in).to eq(3599)
    end

    it "種類 without_youtube_scope: youtube のスコープを付与しない（権限の部分拒否）" do
      grant = exchange(issue(kind: "without_youtube_scope"))

      expect(grant.scope?(youtube_scope)).to be(false)
      expect(grant.scopes).to eq([])
    end

    it "種類 without_refresh_token: スコープは付与するが、更新トークンが無い" do
      grant = exchange(issue(kind: "without_refresh_token"))

      expect(grant.scope?(youtube_scope)).to be(true)
      expect(grant.refresh_token).to be_nil
      expect(grant.access_token).to be_present
    end

    it "種類は 3 つだけ。それ以外の発行は ArgumentError" do
      expect(described_class::YOUTUBE_GRANT_KINDS).to eq(%w[ full without_youtube_scope without_refresh_token ])
      [ nil, "", "deny", "FULL", :full, 1 ].each do |kind|
        expect { issue(kind: kind) }.to raise_error(ArgumentError, /kind/)
      end
    end

    it "トークンは、コードごとに決まる（同じコードは同じトークン。別のコードは別のトークン）。更新トークンはアクセストークンと違う" do
      first = issue(code_challenge: s256_challenge("dummy-verifier-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
      second = issue(code_challenge: s256_challenge("dummy-verifier-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))

      grant = fake.exchange_youtube_code(code: first, code_verifier: "dummy-verifier-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", redirect_uri: callback_uri)
      same = fake.exchange_youtube_code(code: first, code_verifier: "dummy-verifier-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", redirect_uri: callback_uri)
      other = fake.exchange_youtube_code(code: second, code_verifier: "dummy-verifier-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", redirect_uri: callback_uri)

      expect(same.refresh_token).to eq(grant.refresh_token)
      expect(other.refresh_token).not_to eq(grant.refresh_token)
      expect(other.access_token).not_to eq(grant.access_token)
      expect(grant.refresh_token).not_to eq(grant.access_token)
    end

    it "トークンは、TokenVault#store が受け付ける形（印字できる ASCII）" do
      grant = exchange(issue)

      expect(grant.refresh_token).to match(TokenVault::REFRESH_TOKEN_PATTERN)
      expect(grant.access_token).to match(GoogleTokenClient::TOKEN_PATTERN)
    end

    it "コードの有効期間は 300 秒（設定 fake_google.code_lifetime_seconds）。299 秒後は可、300 秒後は code_expired" do
      code = issue

      clock_state[:now] = now + 299
      expect(exchange(code)).to be_a(OAuthGrant)

      clock_state[:now] = now + 300
      expect_failure(:code_expired) { exchange(code) }
    end

    it "PKCE: 検証子が違えば pkce_mismatch" do
      expect_failure(:pkce_mismatch) { exchange(issue, verifier: "dummy-other-verifier-0123456789-abcdefghijklmnopqrstuvwxyz") }
    end

    it "redirect_uri が違えば redirect_uri_mismatch" do
      expect_failure(:redirect_uri_mismatch) { exchange(issue, redirect: "https://evil.example.test/api/youtube/connect/callback") }
    end

    it "改ざんされたコード・でたらめなコード・長すぎるコードは code_invalid" do
      code = issue
      tampered = code.sub(/.\z/) { |char| char == "A" ? "B" : "A" }

      expect_failure(:code_invalid) { exchange(tampered) }
      expect_failure(:code_invalid) { exchange("garbage") }
      expect_failure(:code_invalid) { exchange("a" * 5000) }
      expect_failure(:code_invalid) { exchange("a.b") }
    end

    it "別の秘密値で発行したコードは code_invalid" do
      other = described_class.new(secret: "dummy-another-secret-key-base-0002", clock: -> { now })
      code = other.issue_youtube_code(kind: "full", code_challenge: challenge, redirect_uri: callback_uri, now: now)

      expect_failure(:code_invalid) { exchange(code) }
    end

    it "ログイン用のコード（issue_code）は、YouTube のコードとして交換できない。逆も同じ（用途の分離）" do
      login_code = fake.issue_code(sub: "dev-user-1", nonce: nonce_value, code_challenge: challenge, redirect_uri: callback_uri, now: now)
      youtube_code = issue

      expect_failure(:code_invalid) { exchange(login_code) }
      expect_failure(:code_invalid) do
        fake.authenticate(code: youtube_code, code_verifier: code_verifier, nonce: nonce_value, redirect_uri: callback_uri, now: now)
      end
    end

    it "引数が空・文字列でないときは ArgumentError" do
      valid = { code: issue, code_verifier: code_verifier, redirect_uri: callback_uri }
      valid.each_key do |name|
        [ nil, "", "  ", 1 ].each do |bad|
          expect { fake.exchange_youtube_code(**valid, name => bad) }.to raise_error(ArgumentError, /#{name}/)
        end
      end
    end

    it "発行の引数が空・文字列でないときは ArgumentError（now が Time でないときも）" do
      expect { issue(code_challenge: "") }.to raise_error(ArgumentError, /code_challenge/)
      expect { issue(redirect: "") }.to raise_error(ArgumentError, /redirect_uri/)
      expect { issue(at: 1) }.to raise_error(ArgumentError, /now/)
    end

    it "時計は注入されたものを使う（実時計に依存しない）" do
      code = issue(at: Time.utc(2000, 1, 1))

      clock_state[:now] = Time.utc(2000, 1, 1) + 1

      expect(exchange(code)).to be_a(OAuthGrant)
    end

    it "時計が Time を返さなければ ArgumentError" do
      broken = described_class.new(secret: secret, clock: -> { 123 })
      code = issue

      expect { broken.exchange_youtube_code(code: code, code_verifier: code_verifier, redirect_uri: callback_uri) }
        .to raise_error(ArgumentError, /Time/)
    end

    it "ログイン用の認証（authenticate）は、これまでどおり動く" do
      code = fake.issue_code(sub: "dev-user-1", nonce: nonce_value, code_challenge: challenge, redirect_uri: redirect_uri, now: now)

      identity = fake.authenticate(code: code, code_verifier: code_verifier, nonce: nonce_value, redirect_uri: redirect_uri, now: now)

      expect(identity.sub).to eq("dev-user-1")
    end
  end

  describe "#revoke" do
    it "疑似は、受け取ったトークンを失効させたことにする（:revoked）" do
      expect(fake.revoke(token: "dummy-refresh-token")).to eq(:revoked)
    end

    it "トークンが空・文字列でないときは ArgumentError" do
      [ nil, "", "  ", 1 ].each { |bad| expect { fake.revoke(token: bad) }.to raise_error(ArgumentError, /token/) }
    end

    it "ログに、トークンを出さない" do
      output = capture_logs { fake.revoke(token: "dummy-refresh-token-must-not-appear") }

      expect(output).not_to include("must-not-appear")
    end
  end

  describe "機密" do
    it "失敗のログと例外に、コード・検証子・トークンを出さない。理由の符号は出る" do
      code = issue
      grant = exchange(code)
      error = nil
      output = capture_logs do
        exchange(code, verifier: "dummy-other-verifier-0123456789-abcdefghijklmnopqrstuvwxyz")
      rescue GoogleOidc::AuthenticationFailed => caught
        error = caught
      end

      expect(output).to include("reason=pkce_mismatch")
      [ code, code_verifier, grant.refresh_token, grant.access_token ].each do |value|
        expect(output).not_to include(value)
        expect(error.message).not_to include(value)
      end
    end

    it "inspect に、秘密値・トークンを出さない" do
      expect(fake.inspect).to eq("#<FakeGoogleOidc>")
    end
  end

  describe "環境" do
    it "本番では構築できない（これまでどおり）" do
      expect { described_class.new(secret: secret, environment: AppEnvironment.new("production")) }
        .to raise_error(FakeServices::NotAllowedError)
    end
  end
end
