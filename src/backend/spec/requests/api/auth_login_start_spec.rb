require "rails_helper"
require "support/api_helpers"
require "support/external_http_support"
require "support/google_oidc_support"
require "support/auth_flow_helpers"
require "support/log_capture"

# POST /api/auth/login/start（src/contracts/http-api.md 3 章。issue #8。requirements.md 7.1・23.1・28.1）。
# 評価の順: 入力の検証 → 頻度制限（IP 単位 30 回 / 時）→ bot 判定（行為名 login）→ 認可 URL。
# 認可 URL はスコープ openid のみ・response_type=code・PKCE（S256）・state・nonce・redirect_uri（公開オリジンの /api/auth/callback）。
# 検証子・state・nonce は bl_oauth（暗号化・HttpOnly・SameSite=Lax・Max-Age=600）に持つ。測定イベント login_started。
RSpec.describe "POST /api/auth/login/start", type: :request do
  include ApiHelpers
  include AuthFlowHelpers
  include GoogleOidcSupport
  include ActiveSupport::Testing::TimeHelpers
  include_context "API の環境"

  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:clock) { { now: now } }
  let!(:limiter) { fresh_rate_limiter(clock) }
  let(:callback_url) { "#{ApiHelpers::PUBLIC_ORIGIN}/api/auth/callback" }

  def authorization_query
    Rack::Utils.parse_query(URI.parse(json_body.fetch("authorization_url")).query)
  end

  # bl_oauth の値から、保管された状態を取り出す
  def stored_state
    OAuthStateCookie.new(secret: Rails.application.secret_key_base).open(cookie_value(OAuthStateCookie::NAME), expected_purpose: "login", now: now)
  end

  before { travel_to(now) }
  after { travel_back }

  describe "疑似の Google（開発・テストの環境の判定）" do
    it "200 と認可 URL を返す。行き先は、公開オリジンの疑似の認可画面（フロントエンドのオリジン）" do
      login_start

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to start_with("application/json")
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(json_body.keys).to eq([ "authorization_url" ])
      uri = URI.parse(json_body.fetch("authorization_url"))
      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq("#{ApiHelpers::PUBLIC_ORIGIN}/api/dev/google/authorize")
    end

    it "認可 URL のパラメータ: スコープは openid のみ・response_type=code・PKCE の S256・state・nonce・redirect_uri（公開オリジンの /api/auth/callback）" do
      login_start

      expect(authorization_query).to include(
        "response_type" => "code", "scope" => "openid", "code_challenge_method" => "S256", "redirect_uri" => callback_url
      )
      expect(authorization_query.fetch("scope")).to eq("openid")
      %w[ state nonce code_challenge ].each { |name| expect(authorization_query.fetch(name)).to match(/\A[A-Za-z0-9_-]{43}\z/) }
    end

    it "bl_oauth: HttpOnly・SameSite=Lax・Path=/・Max-Age=600（開発・テストの http では Secure を付けない）。値は暗号化されている" do
      login_start

      line = cookie_line("bl_oauth")
      expect(line).to be_present
      expect(line.downcase).to include("httponly", "samesite=lax", "path=/", "max-age=600")
      expect(line.downcase).not_to include("secure")
      value = cookie_value("bl_oauth")
      expect(value).not_to include(authorization_query.fetch("state"))
      expect(value).not_to include(authorization_query.fetch("nonce"))
    end

    it "bl_oauth の中身（用途・state・nonce・検証子）は、認可 URL と対応する。PKCE: code_challenge は検証子の S256" do
      login_start

      state = stored_state
      expect(state.purpose).to eq("login")
      expect(state.user_id).to be_nil
      expect(state.state).to eq(authorization_query.fetch("state"))
      expect(state.nonce).to eq(authorization_query.fetch("nonce"))
      expect(authorization_query.fetch("code_challenge")).to eq(s256_challenge(state.code_verifier))
      expect(state.code_verifier).to match(/\A[A-Za-z0-9_-]{86}\z/)
    end

    it "検証子・state・nonce は、応答の本文に出ない（認可 URL の state・nonce と code_challenge だけ）" do
      login_start

      expect(response.body).not_to include(stored_state.code_verifier)
    end

    it "bl_session は設定しない（ログインしていない）" do
      login_start

      expect(cookie_line("bl_session")).to be_nil
      expect(Session.count).to eq(0)
    end

    it "呼ぶたびに、新しい state・nonce・検証子の認可 URL を作り、bl_oauth を置き換える（冪等ではない）" do
      login_start
      first_query = authorization_query
      first_cookie = cookie_value("bl_oauth")
      login_start
      second_query = authorization_query

      expect(second_query.fetch("state")).not_to eq(first_query.fetch("state"))
      expect(second_query.fetch("nonce")).not_to eq(first_query.fetch("nonce"))
      expect(second_query.fetch("code_challenge")).not_to eq(first_query.fetch("code_challenge"))
      expect(cookie_value("bl_oauth")).not_to eq(first_cookie)
    end

    it "測定イベント login_started を記録する（アカウントに紐づけない・符号や区分を持たない・IP を含めない）" do
      expect { login_start }.to change(UsageEvent, :count).by(1)

      event = UsageEvent.last
      expect(event.event_type).to eq("login_started")
      expect(event.user_id).to be_nil
      expect(event.occurred_at).to eq(now)
      expect(event.attributes.slice("reason_code", "bucket", "browser_class").values.compact).to be_empty
      expect(event.attributes.values.map(&:to_s).join(" ")).not_to include(ApiHelpers::CLIENT_IP)
    end

    it "ログイン済みのブラウザからも呼べる（新しい認可を始める）" do
      signed_in = sign_in

      login_start(signed_in: signed_in)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "入力の検証（recaptcha_token）" do
    [
      [ "無い", nil ],
      [ "空", "" ],
      [ "空白だけ", "   " ],
      [ "数値", 123 ],
      [ "配列", [ "dev-pass" ] ],
      [ "ハッシュ", { "a" => "dev-pass" } ],
      [ "null", nil ]
    ].each do |label, value|
      it "recaptcha_token が#{label}: 422 invalid_input（fields に recaptcha_token）。bl_oauth を設定しない・イベントを記録しない" do
        body = value.nil? && label == "無い" ? {} : { recaptcha_token: value }

        expect { api_post "/api/auth/login/start", body }.not_to change(UsageEvent, :count)

        expect(response).to have_http_status(422)
        expect(json_body).to eq({ "error" => { "code" => "invalid_input", "details" => { "fields" => [ "recaptcha_token" ] } } })
        expect(cookie_line("bl_oauth")).to be_nil
      end
    end

    it "recaptcha_token が長すぎる（#{RecaptchaVerifier::TOKEN_MAX_LENGTH + 1} 文字）: 422 invalid_input。検証サービスを呼ばない" do
      login_start("a" * (RecaptchaVerifier::TOKEN_MAX_LENGTH + 1))

      expect(response).to have_http_status(422)
      expect(error_code).to eq("invalid_input")
    end

    it "壊れた JSON の本文: 422 invalid_input" do
      api_post "/api/auth/login/start", raw_body: "{not json", headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(422)
      expect(error_code).to eq("invalid_input")
    end

    it "本文が空: 422 invalid_input" do
      api_post "/api/auth/login/start"

      expect(response).to have_http_status(422)
      expect(error_code).to eq("invalid_input")
    end

    it "未知のキーは無視する（契約: 要求の未知のキーは、無視する）" do
      api_post "/api/auth/login/start", { recaptcha_token: "dev-pass", unknown_key: 1, email: "dummy@example.test" }

      expect(response).to have_http_status(:ok)
    end

    it "入力の不備は、頻度制限に数えない（31 回送っても、429 にならない）" do
      31.times { api_post "/api/auth/login/start", {} }

      expect(response).to have_http_status(422)
      login_start
      expect(response).to have_http_status(:ok)
    end

    it "入力の検証が、頻度制限・bot 判定より先（検証サービスを呼ばない）" do
      verifier = instance_double(FakeRecaptchaVerifier)
      allow(verifier).to receive(:verify)
      use_gateways(google_oidc: ExternalServices.current.google_oidc, recaptcha_verifier: verifier)

      api_post "/api/auth/login/start", {}

      expect(verifier).not_to have_received(:verify)
    end
  end

  describe "頻度制限（IP 単位で 30 回 / 時）" do
    it "30 回までは通り、31 回目は 429 rate_limited（details の retry_at は、枠が空く時刻 = 最初の許可の 1 時間後。JST）" do
      30.times do
        login_start
        expect(response).to have_http_status(:ok)
      end

      login_start

      expect(response).to have_http_status(429)
      expect(json_body).to eq({ "error" => { "code" => "rate_limited", "details" => { "retry_at" => "2026-10-08T13:00:00+09:00" } } })
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "429 の応答は、bl_oauth を設定しない・イベントを記録しない・認可 URL を返さない" do
      30.times { login_start }
      events = UsageEvent.count

      login_start

      expect(response).to have_http_status(429)
      expect(cookie_line("bl_oauth")).to be_nil
      expect(UsageEvent.count).to eq(events)
      expect(response.body).not_to include("authorization_url")
    end

    it "429 の応答では、bot 判定（検証サービス）を呼ばない" do
      verifier = instance_double(FakeRecaptchaVerifier)
      allow(verifier).to receive(:verify).and_return(:pass)
      use_gateways(google_oidc: ExternalServices.current.google_oidc, recaptcha_verifier: verifier)
      30.times { login_start }

      login_start

      expect(response).to have_http_status(429)
      expect(verifier).to have_received(:verify).exactly(30).times
    end

    it "bot 判定に失敗した要求も、計数に入る（30 回の失敗のあとの 31 回目は、403 ではなく 429）" do
      30.times { login_start("dev-fail") }
      expect(response).to have_http_status(403)

      login_start("dev-fail")

      expect(response).to have_http_status(429)
    end

    it "枠が空く時刻（1 時間後）を過ぎれば、また通る" do
      30.times { login_start }
      login_start
      expect(response).to have_http_status(429)

      clock[:now] = now + 3600
      login_start

      expect(response).to have_http_status(:ok)
    end

    it "IP ごとに別の計数（X-Forwarded-For の先頭の IP）" do
      30.times { login_start }

      login_start(headers: { "X-Forwarded-For" => "203.0.113.99" })
      expect(response).to have_http_status(:ok)

      login_start(headers: { "X-Forwarded-For" => "#{ApiHelpers::CLIENT_IP}, 198.51.100.7" })
      expect(response).to have_http_status(429)
    end

    it "IP が分からない要求（X-Forwarded-For が無い・IP でない）は、不明の IP としてまとめて数える（別の値で補わない）" do
      30.times { login_start(headers: { "X-Forwarded-For" => nil }) }
      login_start(headers: { "X-Forwarded-For" => "not-an-ip" })

      expect(response).to have_http_status(429)
    end

    it "ログインの開始と YouTube 接続の開始は、別の計数（このスペックは login_start だけ）" do
      expect(RateLimitPolicy.login_start.name).to eq("login_start")
      expect(RateLimitPolicy.login_start.rules.map(&:limit)).to eq([ 30 ])
      expect(RateLimitPolicy.login_start.rules.map(&:window_seconds)).to eq([ 3600 ])
    end

    it "IP アドレスを、DB・応答・ログに出さない" do
      output = capture_logs { 31.times { login_start } }

      expect(output).not_to include(ApiHelpers::CLIENT_IP)
      expect(response.body).not_to include(ApiHelpers::CLIENT_IP)
      expect(UsageEvent.all.map(&:attributes).to_s).not_to include(ApiHelpers::CLIENT_IP)
    end
  end

  describe "bot 判定（行為名 login）" do
    it "dev-fail（不合格）: 403 bot_check_failed。bl_oauth を設定しない・認可 URL を返さない・イベントを記録しない" do
      expect { login_start("dev-fail") }.not_to change(UsageEvent, :count)

      expect(response).to have_http_status(403)
      expect(json_body).to eq({ "error" => { "code" => "bot_check_failed", "details" => {} } })
      expect(cookie_line("bl_oauth")).to be_nil
      expect(response.body).not_to include("authorization_url")
    end

    it "dev-indeterminate（判定不能）も 403 bot_check_failed（受理側へ倒さない）" do
      login_start("dev-indeterminate")

      expect(response).to have_http_status(403)
      expect(error_code).to eq("bot_check_failed")
    end

    it "疑似のトークン以外（実際のトークンの形）は不合格" do
      login_start("dummy-real-looking-recaptcha-token")

      expect(response).to have_http_status(403)
    end

    it "検証サービスへ、トークン・行為名 login・公開オリジンのホスト・現在時刻を渡す" do
      verifier = instance_double(FakeRecaptchaVerifier)
      allow(verifier).to receive(:verify).and_return(:pass)
      use_gateways(google_oidc: ExternalServices.current.google_oidc, recaptcha_verifier: verifier)

      login_start("dummy-token-0001")

      expect(verifier).to have_received(:verify).with(token: "dummy-token-0001", expected_action: "login", hostname: ApiHelpers::PUBLIC_HOST, now: now)
    end

    it "検証サービスの失敗（例外）は、握りつぶさない: 500 internal_error。受理しない" do
      verifier = instance_double(FakeRecaptchaVerifier)
      allow(verifier).to receive(:verify).and_raise(RuntimeError, "boom dummy-secret-detail")
      use_gateways(google_oidc: ExternalServices.current.google_oidc, recaptcha_verifier: verifier)

      output = capture_logs { login_start }

      expect(response).to have_http_status(500)
      expect(json_body).to eq({ "error" => { "code" => "internal_error", "details" => {} } })
      expect(cookie_line("bl_oauth")).to be_nil
      expect(output).not_to include("dummy-secret-detail")
    end

    it "bot 判定の不合格の理由は、ログに出る（判定の符号）。トークンは出ない" do
      output = capture_logs { login_start("dev-fail") }

      expect(output).to include("code=bot_check_failed")
      expect(output).to include("reason=fail")
      expect(output).not_to include("dev-fail")
    end
  end

  describe "共通の規約（#7 の基盤）" do
    it "X-BFF-Secret が無い: 403 forbidden（検証サービスも呼ばない）" do
      login_start(headers: { "X-BFF-Secret" => nil })

      expect(response).to have_http_status(403)
      expect(error_code).to eq("forbidden")
    end

    it "X-BL-Client: web が無い: 403 csrf_invalid" do
      login_start(headers: { "X-BL-Client" => nil })

      expect(response).to have_http_status(403)
      expect(error_code).to eq("csrf_invalid")
    end

    it "Origin が公開オリジンと違う: 403 csrf_invalid（ログイン前の POST にも適用される）" do
      login_start(headers: { "Origin" => "https://evil.example.test" })

      expect(response).to have_http_status(403)
      expect(error_code).to eq("csrf_invalid")
    end

    it "ログイン前の要求は、X-CSRF-Token が要らない（認可の開始は bl_oauth の state と PKCE で守る）" do
      login_start

      expect(response).to have_http_status(:ok)
    end

    it "ログイン済みで X-CSRF-Token が違う: 403 csrf_invalid（ログイン済みの POST は、トークンの検査を受ける）" do
      signed_in = sign_in

      login_start(signed_in: signed_in, headers: { "X-CSRF-Token" => "0" * 64 })

      expect(response).to have_http_status(403)
    end

    it "GET は経路が無い: 404 not_found" do
      api_get "/api/auth/login/start"

      expect(response).to have_http_status(404)
    end

    it "ログインの方針は、匿名と宣言している（Api::AuthController#login_start）" do
      expect(Api::AuthController.login_policy_for("login_start")).to eq(:anonymous)
    end
  end

  describe "実物の Google ログインと bot 判定（WebMock）" do
    let(:http) { ExternalHttp.new }
    let(:oidc) do
      GoogleOidcClient.new(
        client_id: client_id, client_secret: client_secret, http: http, endpoints: google_config,
        jwks_cache: GoogleJwksCache.new(http: http, jwks_uri: google_config.fetch(:jwks_uri), ttl_seconds: 3600, min_refetch_seconds: 60)
      )
    end
    let(:siteverify) { ExternalServices.config.fetch(:recaptcha).fetch(:siteverify_endpoint) }
    let(:verifier) { RecaptchaVerifier.new(secret: "dummy-recaptcha-secret-key", endpoint: siteverify, settings_source: -> { Settings.defaults }, http: http) }

    before { use_gateways(google_oidc: oidc, recaptcha_verifier: verifier) }

    def stub_siteverify_pass(action: "login")
      stub_request(:post, siteverify).to_return(
        status: 200,
        body: JSON.generate("success" => true, "score" => 0.9, "action" => action, "challenge_ts" => (now - 3).iso8601, "hostname" => ApiHelpers::PUBLIC_HOST)
      )
    end

    it "認可 URL は Google の認可の画面。スコープは openid のみ・PKCE の S256・client_id・redirect_uri（公開オリジンの /api/auth/callback）" do
      stub_siteverify_pass

      login_start("dummy-recaptcha-token")

      expect(response).to have_http_status(:ok)
      uri = URI.parse(json_body.fetch("authorization_url"))
      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq("https://accounts.google.com/o/oauth2/v2/auth")
      expect(authorization_query).to include(
        "client_id" => client_id, "redirect_uri" => callback_url, "response_type" => "code", "scope" => "openid", "code_challenge_method" => "S256"
      )
      expect(authorization_query.fetch("code_challenge")).to eq(s256_challenge(stored_state.code_verifier))
      expect(authorization_query.keys).to match_array(%w[ client_id redirect_uri response_type scope state nonce code_challenge code_challenge_method ])
    end

    it "siteverify へ送るのは secret と response だけ（IP アドレスを送らない）。行為名は login、ホストは公開オリジンのホストで検証する" do
      stub = stub_request(:post, siteverify)
             .with(body: { "secret" => "dummy-recaptcha-secret-key", "response" => "dummy-recaptcha-token" })
             .to_return(status: 200, body: JSON.generate("success" => true, "score" => 0.9, "action" => "login", "challenge_ts" => (now - 3).iso8601, "hostname" => ApiHelpers::PUBLIC_HOST))

      login_start("dummy-recaptcha-token")

      expect(stub).to have_been_requested.once
      expect(a_request(:post, siteverify).with { |request| request.body.include?(ApiHelpers::CLIENT_IP) }).not_to have_been_made
    end

    it "行為名が違うトークン（broadcast_start 用）は 403 bot_check_failed" do
      stub_siteverify_pass(action: "broadcast_start")

      login_start("dummy-recaptcha-token")

      expect(response).to have_http_status(403)
      expect(error_code).to eq("bot_check_failed")
    end

    it "発行元のホストが違うトークンは 403 bot_check_failed" do
      stub_request(:post, siteverify).to_return(
        status: 200,
        body: JSON.generate("success" => true, "score" => 0.9, "action" => "login", "challenge_ts" => (now - 3).iso8601, "hostname" => "evil.example.test")
      )

      login_start("dummy-recaptcha-token")

      expect(response).to have_http_status(403)
    end

    it "低スコアは 403 bot_check_failed" do
      stub_request(:post, siteverify).to_return(
        status: 200,
        body: JSON.generate("success" => true, "score" => 0.1, "action" => "login", "challenge_ts" => (now - 3).iso8601, "hostname" => ApiHelpers::PUBLIC_HOST)
      )

      login_start("dummy-recaptcha-token")

      expect(response).to have_http_status(403)
    end

    [
      [ "検証サービスに届かない（タイムアウト）", ->(stub) { stub.to_timeout } ],
      [ "検証サービスが 503", ->(stub) { stub.to_return(status: 503, body: "") } ],
      [ "解釈できない応答", ->(stub) { stub.to_return(status: 200, body: "<html>") } ],
      [ "無料枠の超過（fail open の success: true）", ->(stub) { stub.to_return(status: 200, body: JSON.generate("success" => true, "score" => 0.9, "action" => "login", "challenge_ts" => (Time.utc(2026, 10, 8, 3) - 3).iso8601, "hostname" => "app.example.test", "message" => "Over free quota.")) } ]
    ].each do |label, arrange|
      it "#{label}: 403 bot_check_failed（受理側へ倒さない）。認可 URL を返さない" do
        arrange.call(stub_request(:post, siteverify))

        login_start("dummy-recaptcha-token")

        expect(response).to have_http_status(403)
        expect(error_code).to eq("bot_check_failed")
        expect(cookie_line("bl_oauth")).to be_nil
        expect(response.body).not_to include("authorization_url")
      end
    end

    it "トークン・秘密鍵を、ログに出さない" do
      stub_siteverify_pass

      output = capture_logs { login_start("dummy-recaptcha-token") }

      expect(output).not_to include("dummy-recaptcha-token")
      expect(output).not_to include("dummy-recaptcha-secret-key")
    end
  end
end
