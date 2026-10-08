require "rails_helper"
require "support/api_helpers"
require "support/external_http_support"
require "support/google_oidc_support"
require "support/auth_flow_helpers"
require "support/log_capture"

# GET /api/auth/callback（src/contracts/http-api.md 3 章。issue #8。requirements.md 7.1・23.1・28.1）。
# state を bl_oauth と照合し（不一致・欠落・期限切れ・error パラメータは 302 /?login_error=oauth_failed）、コードをトークンへ交換して
# ID トークンを検証し、sub でアカウントを特定（無ければ作成）→ 既存のセッションを破棄して新しいセッションを発行（固定化の防止）→
# 最終ログイン時刻を更新 → 302 /studio。bl_oauth は、成功・失敗のどちらでも失効させる。再登録の保留中は 302 /?login_error=registration_held。
# リダイレクト先は、常に公開オリジン（PublicOrigin。X-Forwarded-Host から作る。バックエンドのホストを使わない）。
RSpec.describe "GET /api/auth/callback", type: :request do
  include ApiHelpers
  include AuthFlowHelpers
  include GoogleOidcSupport
  include ActiveSupport::Testing::TimeHelpers
  include_context "API の環境"

  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:clock) { { now: now } }
  let!(:limiter) { fresh_rate_limiter(clock) }
  let(:origin) { ApiHelpers::PUBLIC_ORIGIN }
  let(:callback_url) { "#{origin}/api/auth/callback" }
  let(:oauth_failed) { "#{origin}/?login_error=oauth_failed" }
  let(:registration_held) { "#{origin}/?login_error=registration_held" }

  # 時刻を now に固定する。別の時刻の確認は、travel_to（ブロックなし）で動かす（ブロックの入れ子は、Rails が拒否する）
  before { travel_to(now) }
  after { travel_back }

  # --- 疑似の Google の流れの部品 ---

  # 開始 → 疑似の認可画面 → アカウントの選択。コールバックの要求（パスとクエリ）と、bl_oauth の値を返す
  def begin_fake_login(account: "dev-user-1")
    login_start
    authorization_url = json_body.fetch("authorization_url")
    oauth_cookie = cookie_value(OAuthStateCookie::NAME)
    api_get authorize_path_of(authorization_url), headers: no_cookies
    link = account_links.fetch(account)
    query = Rack::Utils.parse_query(URI.parse(link).query)
    { code: query.fetch("code"), state: query.fetch("state"), oauth_cookie: oauth_cookie, authorization_url: authorization_url }
  end

  def expect_oauth_failure
    expect(response).to have_http_status(:found)
    expect(response.headers["Location"]).to eq(oauth_failed)
    expect(expired_cookie?(OAuthStateCookie::NAME)).to be(true)
    expect(cookie_line(SessionCookie::NAME)).to be_nil
    expect(UsageEvent.where(event_type: "login_completed")).to be_empty
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  describe "成功（疑似の Google）" do
    let(:flow) { begin_fake_login }

    it "302 /studio（公開オリジンの絶対 URL）。bl_oauth を失効させ、bl_session を発行する" do
      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie])

      expect(response).to have_http_status(:found)
      expect(response.headers["Location"]).to eq("#{origin}/studio")
      expect(expired_cookie?(OAuthStateCookie::NAME)).to be(true)
      expect(cookie_value(SessionCookie::NAME)).to match(/\A[A-Za-z0-9_-]{43}\z/)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.body).to be_empty
    end

    it "bl_session の属性: HttpOnly・SameSite=Lax・Path=/・有効期限の属性なし（ブラウザのセッション Cookie）。開発・テストの http では Secure を付けない" do
      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie])

      line = cookie_line(SessionCookie::NAME).downcase
      expect(line).to include("httponly", "samesite=lax", "path=/")
      expect(line).not_to include("max-age")
      expect(line).not_to include("expires")
      expect(line).not_to include("secure")
    end

    it "アカウントが作られる（sub のみ）。サーバー側のセッションは、要約値だけを保存し、最終利用から 30 日で失効する" do
      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie])

      user = User.sole
      session = Session.sole
      token = cookie_value(SessionCookie::NAME)
      expect(user.google_sub).to eq("dev-user-1")
      expect(user.last_login_at).to eq(now)
      expect(session.user_id).to eq(user.id)
      expect(session.token_digest).to eq(Digest::SHA256.hexdigest(token))
      expect(session.token_digest).not_to eq(token)
      expect(session.last_used_at).to eq(now)
      expect(session.expires_at).to eq(now + 30.days)
    end

    it "測定イベント login_completed を、内部のアカウント識別子に紐づけて記録する（IP・sub を含めない）" do
      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie])

      event = UsageEvent.where(event_type: "login_completed").sole
      expect(event.user_id).to eq(User.sole.id)
      expect(event.occurred_at).to eq(now)
      expect(event.attributes.slice("reason_code", "bucket", "browser_class").values.compact).to be_empty
      expect(event.attributes.values.map(&:to_s).join(" ")).not_to include("dev-user-1")
      expect(event.attributes.values.map(&:to_s).join(" ")).not_to include(ApiHelpers::CLIENT_IP)
    end

    it "発行されたセッションで、ログインが必要な API を呼べる（CSRF トークンは、セッションの識別子から導出）" do
      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie])
      token = cookie_value(SessionCookie::NAME)
      signed_in = ApiHelpers::SignedIn.new(user: User.sole, token: token, session: Session.sole, csrf_token: csrf_token_for(token))

      api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in

      expect(response).to have_http_status(204)
    end

    it "登録済みのアカウント: 同じアカウントでログインし、最終ログイン時刻を更新する。アカウントを増やさない" do
      existing = create(:user, google_sub: "dev-user-1", last_login_at: now - 10.days)

      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie])

      expect(response.headers["Location"]).to eq("#{origin}/studio")
      expect(User.count).to eq(1)
      expect(User.find(existing.id).last_login_at).to eq(now)
      expect(Session.sole.user_id).to eq(existing.id)
    end

    it "3 つのアカウントを、それぞれ別のアカウントとして扱う" do
      %w[ dev-user-1 dev-user-2 dev-user-3 ].each do |account|
        fresh = begin_fake_login(account: account)
        callback(code: fresh[:code], state: fresh[:state], oauth_cookie: fresh[:oauth_cookie])
        expect(response.headers["Location"]).to eq("#{origin}/studio")
      end

      expect(User.pluck(:google_sub)).to match_array(%w[ dev-user-1 dev-user-2 dev-user-3 ])
    end

    it "GET なので、X-BL-Client・X-CSRF-Token は要らない（CSRF の対象外。state と PKCE で守る）" do
      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie], headers: { "X-BL-Client" => nil })

      expect(response.headers["Location"]).to eq("#{origin}/studio")
    end
  end

  describe "失敗は 302 /?login_error=oauth_failed（bl_oauth は失効、セッションは発行しない、アカウントを作らない）" do
    it "bl_oauth が無い" do
      flow = begin_fake_login

      callback(code: flow[:code], state: flow[:state])

      expect_oauth_failure
      expect(User.count).to eq(0)
    end

    it "bl_oauth が改ざんされている" do
      flow = begin_fake_login
      tampered = flow[:oauth_cookie].sub(/.\z/) { |char| char == "A" ? "B" : "A" }

      callback(code: flow[:code], state: flow[:state], oauth_cookie: tampered)

      expect_oauth_failure
      expect(User.count).to eq(0)
    end

    it "bl_oauth が期限切れ（開始から 10 分以上）" do
      flow = begin_fake_login

      travel_to(now + 601.seconds)
      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie])

      expect_oauth_failure
      expect(User.count).to eq(0)
    end

    it "bl_oauth が、ほかの秘密値で暗号化されたもの" do
      flow = begin_fake_login
      forged = OAuthStateCookie.new(secret: "dummy-another-secret-key-base-0002").seal(
        state: flow[:state], nonce: "dummy-nonce", code_verifier: "dummy-verifier", purpose: "login", now: now
      )

      callback(code: flow[:code], state: flow[:state], oauth_cookie: forged)

      expect_oauth_failure
    end

    it "bl_oauth の用途が connect（YouTube 接続の途中の状態を、ログインに使えない）" do
      flow = begin_fake_login
      connect = OAuthStateCookie.new(secret: Rails.application.secret_key_base).seal(
        state: flow[:state], nonce: "dummy-nonce", code_verifier: "dummy-verifier", purpose: "connect",
        user_id: "7c9d1e2f-3a4b-4c5d-8e6f-0a1b2c3d4e5f", now: now
      )

      callback(code: flow[:code], state: flow[:state], oauth_cookie: connect)

      expect_oauth_failure
    end

    it "bl_oauth がでたらめな値" do
      flow = begin_fake_login

      callback(code: flow[:code], state: flow[:state], oauth_cookie: "garbage")

      expect_oauth_failure
    end

    it "state が違う（別のブラウザ・別の開始の state）" do
      flow = begin_fake_login
      other = begin_fake_login

      callback(code: flow[:code], state: other[:state], oauth_cookie: flow[:oauth_cookie])

      expect_oauth_failure
      expect(User.count).to eq(0)
    end

    it "state が無い" do
      flow = begin_fake_login

      callback(code: flow[:code], oauth_cookie: flow[:oauth_cookie])

      expect_oauth_failure
    end

    it "state が配列・ハッシュ（state[]=x）" do
      flow = begin_fake_login

      api_get "/api/auth/callback?code=#{CGI.escape(flow[:code])}&state[]=#{flow[:state]}", headers: { "Cookie" => cookie_header_of(flow[:oauth_cookie], nil) }
      expect_oauth_failure

      api_get "/api/auth/callback?code=#{CGI.escape(flow[:code])}&state[a]=#{flow[:state]}", headers: { "Cookie" => cookie_header_of(flow[:oauth_cookie], nil) }
      expect_oauth_failure
    end

    it "error パラメータ（利用者が認可を拒否した・Google のエラー）。state が正しくても失敗" do
      flow = begin_fake_login

      callback(state: flow[:state], error: "access_denied", oauth_cookie: flow[:oauth_cookie])

      expect_oauth_failure
      expect(User.count).to eq(0)
    end

    it "error パラメータと正しいコードが同時にあっても、失敗（コードを交換しない）" do
      flow = begin_fake_login

      callback(code: flow[:code], state: flow[:state], error: "access_denied", oauth_cookie: flow[:oauth_cookie])

      expect_oauth_failure
      expect(User.count).to eq(0)
    end

    it "コードが無い" do
      flow = begin_fake_login

      callback(state: flow[:state], oauth_cookie: flow[:oauth_cookie])

      expect_oauth_failure
    end

    it "コードが空・配列" do
      flow = begin_fake_login

      callback(code: "", state: flow[:state], oauth_cookie: flow[:oauth_cookie])
      expect_oauth_failure

      api_get "/api/auth/callback?code[]=x&state=#{flow[:state]}", headers: { "Cookie" => cookie_header_of(flow[:oauth_cookie], nil) }
      expect_oauth_failure
    end

    it "コードが長すぎる" do
      flow = begin_fake_login

      callback(code: "a" * 5000, state: flow[:state], oauth_cookie: flow[:oauth_cookie])

      expect_oauth_failure
    end

    it "コードが書き換えられている（疑似のコードの認証）" do
      flow = begin_fake_login
      tampered = flow[:code].sub(/.\z/) { |char| char == "A" ? "B" : "A" }

      callback(code: tampered, state: flow[:state], oauth_cookie: flow[:oauth_cookie])

      expect_oauth_failure
    end

    it "コードが期限切れ（疑似のコードは 300 秒。bl_oauth の 600 秒より短い）" do
      flow = begin_fake_login

      travel_to(now + 301.seconds)
      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie])

      expect_oauth_failure
    end

    it "失敗の応答は、アカウント・セッション・測定イベント login_completed を作らない" do
      flow = begin_fake_login

      expect { callback(code: flow[:code], state: "dummy-other-state", oauth_cookie: flow[:oauth_cookie]) }
        .not_to change { [ User.count, Session.count, UsageEvent.where(event_type: "login_completed").count ] }
    end

    it "失敗の理由は、ログに符号で出る（state・コードの値は出ない）" do
      flow = begin_fake_login

      output = capture_logs { callback(code: flow[:code], state: "dummy-other-state", oauth_cookie: flow[:oauth_cookie]) }

      expect(output).to include("[login] failed reason=state_mismatch")
      expect(output).not_to include(flow[:code])
      expect(output).not_to include(flow[:state])
      expect(output).not_to include("dummy-other-state")
    end
  end

  describe "再登録の保留中（削除から間もない Google アカウント）" do
    it "302 /?login_error=registration_held。アカウントを作らない・セッションを発行しない・bl_oauth は失効" do
      AccountRegistry.new.record_hold(google_sub: "dev-user-1", now: now - 1.hour)
      flow = begin_fake_login

      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie])

      expect(response).to have_http_status(:found)
      expect(response.headers["Location"]).to eq(registration_held)
      expect(expired_cookie?(OAuthStateCookie::NAME)).to be(true)
      expect(cookie_line(SessionCookie::NAME)).to be_nil
      expect(User.count).to eq(0)
      expect(UsageEvent.where(event_type: "login_completed")).to be_empty
    end

    it "保留が明ける（削除時点の利用日の終わり = 次の JST 03:00）まで。02:59 は保留、03:00 は可" do
      registry = AccountRegistry.new
      registry.record_hold(google_sub: "dev-user-1", now: Time.utc(2026, 10, 7, 4, 0, 0)) # JST 2026-10-07 13:00

      travel_to(Time.utc(2026, 10, 7, 17, 59, 0)) # JST 02:59
      flow = begin_fake_login
      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie])
      expect(response.headers["Location"]).to eq(registration_held)

      travel_to(Time.utc(2026, 10, 7, 18, 0, 0)) # JST 03:00
      flow = begin_fake_login
      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie])
      expect(response.headers["Location"]).to eq("#{origin}/studio")
    end

    it "保留中の別の Google アカウントは、ログインできる" do
      AccountRegistry.new.record_hold(google_sub: "dev-user-1", now: now - 1.hour)
      flow = begin_fake_login(account: "dev-user-2")

      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie])

      expect(response.headers["Location"]).to eq("#{origin}/studio")
    end
  end

  describe "セッション固定化の防止（ログイン前後でセッション識別子が変わる）" do
    it "既存のセッション（別のアカウントのもの）を破棄して、新しいセッションを発行する" do
      old = sign_in(create(:user, google_sub: "dummy-other-user"))
      flow = begin_fake_login

      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie], session_token: old.token)

      new_token = cookie_value(SessionCookie::NAME)
      expect(new_token).to be_present
      expect(new_token).not_to eq(old.token)
      expect(Session.exists?(old.session.id)).to be(false)
      expect(Session.sole.token_digest).to eq(Digest::SHA256.hexdigest(new_token))
      expect(Session.sole.user.google_sub).to eq("dev-user-1")
    end

    it "同じアカウントで再ログインしても、識別子は変わる。古い識別子は使えない（401）" do
      user = create(:user, google_sub: "dev-user-1")
      old = sign_in(user)
      flow = begin_fake_login

      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie], session_token: old.token)
      new_token = cookie_value(SessionCookie::NAME)

      expect(new_token).not_to eq(old.token)
      expect(Session.where(user_id: user.id).count).to eq(1)
      api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: old
      expect(response).to have_http_status(401)
    end

    it "攻撃者が植え付けたセッションの識別子（未登録の値）は、受け入れず、新しいものを発行する" do
      flow = begin_fake_login
      planted = SecureRandom.urlsafe_base64(32)

      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie], session_token: planted)

      expect(cookie_value(SessionCookie::NAME)).not_to eq(planted)
      expect(Session.sole.token_digest).not_to eq(Digest::SHA256.hexdigest(planted))
    end

    it "ほかのアカウントのセッションは、破棄しない" do
      bystander = sign_in(create(:user, google_sub: "dummy-bystander"))
      old = sign_in(create(:user, google_sub: "dummy-other-user"))
      flow = begin_fake_login

      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie], session_token: old.token)

      expect(Session.exists?(bystander.session.id)).to be(true)
      expect(Session.count).to eq(2)
    end

    it "失敗したログインは、既存のセッションを壊さない（ログイン中の利用者が、不正なコールバックで追い出されない）" do
      old = sign_in
      flow = begin_fake_login

      callback(code: flow[:code], state: "dummy-other-state", oauth_cookie: flow[:oauth_cookie], session_token: old.token)

      expect_oauth_failure
      expect(Session.exists?(old.session.id)).to be(true)
    end
  end

  describe "リダイレクト先は、常に公開オリジン（PublicOrigin。X-Forwarded-Host から作る）" do
    let(:railway_host) { "backend-production-1234.up.railway.app" }

    it "バックエンドのホスト（Host）がどれでも、成功・失敗・保留の Location は、フロントエンドのホスト" do
      flow = begin_fake_login
      outcomes = {}

      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie], headers: { "Host" => railway_host })
      outcomes[:success] = response.headers["Location"]

      callback(state: flow[:state], error: "access_denied", oauth_cookie: flow[:oauth_cookie], headers: { "Host" => railway_host })
      outcomes[:denied] = response.headers["Location"]

      callback(code: flow[:code], state: flow[:state], headers: { "Host" => railway_host })
      outcomes[:no_cookie] = response.headers["Location"]

      expect(outcomes).to eq(success: "#{origin}/studio", denied: oauth_failed, no_cookie: oauth_failed)
      outcomes.each_value { |location| expect(location).not_to include("railway") }
    end

    it "error=access_denied のとき、Location はフロントエンドのホスト（最初のデプロイで、Railway が X-Forwarded-Host を上書きしないことを実測する前提）" do
      flow = begin_fake_login

      callback(state: flow[:state], error: "access_denied", oauth_cookie: flow[:oauth_cookie], headers: { "Host" => railway_host })

      expect(response.headers["Location"]).to eq("https://#{ApiHelpers::PUBLIC_HOST}/?login_error=oauth_failed")
      expect(URI.parse(response.headers["Location"]).host).to eq(ApiHelpers::PUBLIC_HOST)
    end

    it "Location のホストとスキームは、X-Forwarded-Host・X-Forwarded-Proto から決まる（開発: http://localhost:3000）" do
      flow = begin_fake_login

      callback(state: "dummy-other-state", oauth_cookie: flow[:oauth_cookie], headers: { "X-Forwarded-Host" => "localhost:3000", "X-Forwarded-Proto" => "http" })

      expect(response.headers["Location"]).to eq("http://localhost:3000/?login_error=oauth_failed")
    end

    it "公開オリジンが分からない（X-Forwarded-Host が無い）ときは、バックエンドのホストへ倒さず、500 internal_error（リダイレクトしない）" do
      flow = begin_fake_login

      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie], headers: { "X-Forwarded-Host" => nil })

      expect(response).to have_http_status(500)
      expect(response.headers["Location"]).to be_nil
      expect(error_code).to eq("internal_error")
    end

    it "攻撃者が選べる Host ヘッダは、リダイレクト先に影響しない" do
      flow = begin_fake_login

      callback(state: flow[:state], error: "access_denied", oauth_cookie: flow[:oauth_cookie], headers: { "Host" => "evil.example.test" })

      expect(URI.parse(response.headers["Location"]).host).to eq(ApiHelpers::PUBLIC_HOST)
    end
  end

  describe "共通の規約（#7 の基盤）" do
    it "X-BFF-Secret が無い要求は、リダイレクトせず 403 forbidden" do
      flow = begin_fake_login

      callback(code: flow[:code], state: flow[:state], oauth_cookie: flow[:oauth_cookie], headers: { "X-BFF-Secret" => nil })

      expect(response).to have_http_status(403)
      expect(error_code).to eq("forbidden")
      expect(response.headers["Location"]).to be_nil
      expect(User.count).to eq(0)
    end

    it "ログインの方針は、匿名と宣言している（Api::AuthController#callback）" do
      expect(Api::AuthController.login_policy_for("callback")).to eq(:anonymous)
    end

    it "POST は経路が無い（GET だけ）" do
      api_post "/api/auth/callback", {}

      expect(response).to have_http_status(404)
    end
  end

  describe "実物の Google ログイン（WebMock。署名にはテスト用の RSA 鍵を使う）" do
    let(:http) { ExternalHttp.new }
    let(:oidc) do
      GoogleOidcClient.new(
        client_id: client_id, client_secret: client_secret, http: http, endpoints: google_config,
        jwks_cache: GoogleJwksCache.new(http: http, jwks_uri: google_config.fetch(:jwks_uri), ttl_seconds: 3600, min_refetch_seconds: 60)
      )
    end
    let(:siteverify) { ExternalServices.config.fetch(:recaptcha).fetch(:siteverify_endpoint) }
    let(:verifier) { RecaptchaVerifier.new(secret: "dummy-recaptcha-secret-key", endpoint: siteverify, settings_source: -> { Settings.defaults }, http: http) }
    let(:email) { "dummy-person@example.test" }
    let(:display_name) { "dummy-display-name" }

    before do
      use_gateways(google_oidc: oidc, recaptcha_verifier: verifier)
      stub_request(:post, siteverify).to_return(
        status: 200,
        body: JSON.generate("success" => true, "score" => 0.9, "action" => "login", "challenge_ts" => (now - 3).iso8601, "hostname" => ApiHelpers::PUBLIC_HOST)
      )
    end

    # 開始を済ませ、認可 URL のクエリと bl_oauth の値を返す
    def begin_live_login
      login_start("dummy-recaptcha-token")
      query = Rack::Utils.parse_query(URI.parse(json_body.fetch("authorization_url")).query)
      { query: query, oauth_cookie: cookie_value(OAuthStateCookie::NAME) }
    end

    # トークンエンドポイントの応答（ID トークンは、開始で渡した nonce で署名）。PKCE の検証子が challenge と合うことも確かめる
    def arrange_exchange(flow, **claim_overrides)
      stub_jwks
      challenge = flow[:query].fetch("code_challenge")
      claims = id_token_claims(now: now, nonce: flow[:query].fetch("nonce"), "email" => email, "name" => display_name, **claim_overrides)
      stub_request(:post, google_config.fetch(:token_endpoint))
        .with { |request| s256_challenge(URI.decode_www_form(request.body).to_h.fetch("code_verifier")) == challenge }
        .to_return(status: 200, body: token_response_body(mint_id_token(claims)))
    end

    it "成功: トークンを交換して ID トークンを検証し、302 /studio。アカウントには sub だけを保存する（メール・氏名を保存しない）" do
      flow = begin_live_login
      arrange_exchange(flow)

      callback(code: "dummy-authorization-code", state: flow[:query].fetch("state"), oauth_cookie: flow[:oauth_cookie])

      expect(response.headers["Location"]).to eq("#{origin}/studio")
      expect(User.sole.google_sub).to eq(google_sub)
      expect(User.sole.attributes.keys).to match_array(%w[ id google_sub created_at last_login_at ])
      expect(Session.count).to eq(1)
    end

    it "トークンエンドポイントへ、client_secret と PKCE の検証子を送る" do
      flow = begin_live_login
      arrange_exchange(flow)

      callback(code: "dummy-authorization-code", state: flow[:query].fetch("state"), oauth_cookie: flow[:oauth_cookie])

      expect(a_request(:post, google_config.fetch(:token_endpoint)).with { |request|
        form = URI.decode_www_form(request.body).to_h
        form["client_secret"] == client_secret && form["code"] == "dummy-authorization-code" && form["redirect_uri"] == callback_url &&
          form["grant_type"] == "authorization_code" && form["client_id"] == client_id
      }).to have_been_made.once
    end

    it "メール・氏名・トークンは、DB のどの表にも保存されない（全表の全列を走査する）" do
      flow = begin_live_login
      arrange_exchange(flow)

      callback(code: "dummy-authorization-code", state: flow[:query].fetch("state"), oauth_cookie: flow[:oauth_cookie])

      connection = ActiveRecord::Base.connection
      dump = (connection.tables - %w[ schema_migrations ar_internal_metadata ]).map { |table| connection.select_all("SELECT * FROM #{connection.quote_table_name(table)}").to_a.to_s }.join("\n")
      [ email, display_name, access_token, "dummy-authorization-code", flow[:query].fetch("state"), flow[:query].fetch("nonce") ].each do |value|
        expect(dump).not_to include(value)
      end
      expect(dump).to include(google_sub) # users.google_sub だけが、sub を持つ
    end

    # ID トークンを署名してトークンエンドポイントの応答にする（claims は、開始で渡した nonce を既定にする）
    def arrange_id_token(flow, key: signing_key, **claim_overrides)
      stub_jwks
      claims = id_token_claims(now: now, **{ nonce: flow[:query].fetch("nonce") }.merge(claim_overrides))
      stub_token_endpoint(id_token: mint_id_token(claims, key: key))
    end

    {
      "署名が別の鍵" => { key: :other },
      "nonce が違う" => { nonce: "dummy-other-nonce" },
      "期限切れ" => { exp: Time.utc(2026, 10, 8, 2, 59, 59).to_i },
      "aud が違う" => { aud: "dummy-other-client" },
      "iss が違う" => { iss: "https://evil.example.test" },
      "sub が無い" => { sub: :omit }
    }.each do |label, overrides|
      it "ID トークンの検証に失敗（#{label}）: 302 oauth_failed。アカウントを作らない" do
        flow = begin_live_login
        options = overrides.dup
        key = options.delete(:key) == :other ? other_key : signing_key
        arrange_id_token(flow, key: key, **options)

        callback(code: "dummy-authorization-code", state: flow[:query].fetch("state"), oauth_cookie: flow[:oauth_cookie])

        expect_oauth_failure
        expect(User.count).to eq(0)
      end
    end

    it "トークン交換の失敗（400 invalid_grant）・通信の失敗（タイムアウト）: 302 oauth_failed。ログに状態の符号だけを出す" do
      flow = begin_live_login
      stub_request(:post, google_config.fetch(:token_endpoint)).to_return(status: 400, body: JSON.generate("error" => "invalid_grant", "error_description" => "dummy-description"))

      output = capture_logs { callback(code: "dummy-authorization-code", state: flow[:query].fetch("state"), oauth_cookie: flow[:oauth_cookie]) }
      expect_oauth_failure
      expect(output).to include("reason=token_exchange_rejected")
      expect(output).not_to include("dummy-description")
      expect(output).not_to include("dummy-authorization-code")

      flow = begin_live_login
      stub_request(:post, google_config.fetch(:token_endpoint)).to_timeout
      callback(code: "dummy-authorization-code", state: flow[:query].fetch("state"), oauth_cookie: flow[:oauth_cookie])
      expect_oauth_failure
    end

    it "公開鍵（JWKS）を取得できない: 302 oauth_failed" do
      flow = begin_live_login
      stub_request(:get, google_config.fetch(:jwks_uri)).to_raise(Errno::ECONNREFUSED)
      stub_token_endpoint(id_token: mint_id_token(id_token_claims(now: now, nonce: flow[:query].fetch("nonce"))))

      callback(code: "dummy-authorization-code", state: flow[:query].fetch("state"), oauth_cookie: flow[:oauth_cookie])

      expect_oauth_failure
    end

    it "認可コードの再利用（戻るボタンでの再送など）: Google が 2 回目の交換を拒否する → 302 oauth_failed。セッションは 1 つだけ" do
      flow = begin_live_login
      arrange_exchange(flow)
      callback(code: "dummy-authorization-code", state: flow[:query].fetch("state"), oauth_cookie: flow[:oauth_cookie])
      expect(response.headers["Location"]).to eq("#{origin}/studio")
      stub_request(:post, google_config.fetch(:token_endpoint)).to_return(status: 400, body: JSON.generate("error" => "invalid_grant"))

      callback(code: "dummy-authorization-code", state: flow[:query].fetch("state"), oauth_cookie: flow[:oauth_cookie])

      expect(response.headers["Location"]).to eq(oauth_failed)
      expect(Session.count).to eq(1)
    end

    it "error=access_denied（利用者が Google の同意画面で拒否）: コードを交換せず、302 oauth_failed。Location はフロントエンドのホスト" do
      flow = begin_live_login

      callback(state: flow[:query].fetch("state"), error: "access_denied", oauth_cookie: flow[:oauth_cookie], headers: { "Host" => "backend-production-1234.up.railway.app" })

      expect(response.headers["Location"]).to eq("https://#{ApiHelpers::PUBLIC_HOST}/?login_error=oauth_failed")
      expect(a_request(:post, google_config.fetch(:token_endpoint))).not_to have_been_made
    end

    it "全体のログに、コード・state・nonce・検証子・トークン・秘密値・sub・Cookie の値が出ない（成功・失敗の両方）" do
      output = capture_logs do
        flow = begin_live_login
        arrange_exchange(flow)
        callback(code: "dummy-authorization-code", state: flow[:query].fetch("state"), oauth_cookie: flow[:oauth_cookie])
        @token = cookie_value(SessionCookie::NAME)
        @flow = flow

        failing = begin_live_login
        callback(code: "dummy-authorization-code-2", state: "dummy-wrong-state", oauth_cookie: failing[:oauth_cookie])
      end

      secrets = [
        "dummy-authorization-code", "dummy-authorization-code-2", "dummy-wrong-state", @flow[:query].fetch("state"), @flow[:query].fetch("nonce"),
        @flow[:oauth_cookie], @token, client_secret, "dummy-recaptcha-secret-key", "dummy-recaptcha-token", access_token, google_sub, email, display_name
      ]
      secrets.each { |value| expect(output).not_to include(value) }
      expect(output).to include("[login] completed user_id=")
    end
  end
end
