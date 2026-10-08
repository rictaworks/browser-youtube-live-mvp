require "rails_helper"
require "support/api_helpers"
require "support/auth_flow_helpers"
require "support/youtube_connect_support"

# POST /api/youtube/connect/start（src/contracts/http-api.md 3 章。issue #11。requirements.md 7.2・23.1・28.1）。
# 評価の順: 入力の検証 -> 進行中の配信（接続・再接続を受け付けない）-> 頻度制限（IP 単位 30 回 / 時）-> bot 判定（行為名 youtube_connect）-> 認可 URL。
# 認可 URL はスコープ youtube の 1 種のみ・offline・consent・login_hint（ログイン中の Google の識別子 sub）・PKCE（S256）・state。
# 検証子・state は bl_oauth（暗号化・HttpOnly・SameSite=Lax・Max-Age=600。用途 connect と内部のアカウント識別子つき）に持つ。測定イベント connect_started。
RSpec.describe "POST /api/youtube/connect/start", type: :request do
  include ApiHelpers
  include AuthFlowHelpers
  include YouTubeConnectSupport
  include ActiveSupport::Testing::TimeHelpers
  include_context "API の環境"
  include_context "YouTube 接続の環境"

  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:clock) { { now: now } }
  let!(:limiter) { fresh_rate_limiter(clock) }
  let(:user) { create(:user, google_sub: "dev-user-1") }
  let(:login) { sign_in(user, now: now) }
  let(:callback_url) { "#{ApiHelpers::PUBLIC_ORIGIN}/api/youtube/connect/callback" }

  before { travel_to(now) }
  after { travel_back }

  def connect_start(token = "dev-pass", session: login, headers: {})
    api_post "/api/youtube/connect/start", { recaptcha_token: token }, signed_in: session, headers: headers
  end

  def authorization_query
    Rack::Utils.parse_query(URI.parse(json_body.fetch("authorization_url")).query)
  end

  # bl_oauth の値から、保管された状態を取り出す
  def stored_state
    OAuthStateCookie.new(secret: Rails.application.secret_key_base).open(cookie_value(OAuthStateCookie::NAME), expected_purpose: "connect", now: now)
  end

  describe "疑似の Google（開発・テストの環境の判定）" do
    it "200 と認可 URL を返す。行き先は、公開オリジンの疑似の同意画面（フロントエンドのオリジン）" do
      connect_start

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to start_with("application/json")
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(json_body.keys).to eq([ "authorization_url" ])
      uri = URI.parse(json_body.fetch("authorization_url"))
      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq("#{ApiHelpers::PUBLIC_ORIGIN}/api/dev/google/connect")
    end

    it "認可 URL のパラメータ: スコープは youtube の 1 種のみ・offline・consent・PKCE の S256・state・redirect_uri（公開オリジンの /api/youtube/connect/callback）・login_hint（sub）" do
      connect_start

      expect(authorization_query).to include(
        "response_type" => "code", "scope" => youtube_scope, "access_type" => "offline", "prompt" => "consent",
        "code_challenge_method" => "S256", "redirect_uri" => callback_url, "login_hint" => "dev-user-1"
      )
      expect(authorization_query.fetch("scope").split).to eq([ youtube_scope ])
      expect(authorization_query.fetch("state")).to match(/\A[A-Za-z0-9_-]{43}\z/)
      expect(authorization_query.fetch("code_challenge")).to match(/\A[A-Za-z0-9_-]{43}\z/)
    end

    it "include_granted_scopes を付けない。ID トークンを使わないので nonce も付けない。メールアドレス・プロフィールのスコープを要求しない" do
      connect_start

      expect(authorization_query).not_to have_key("include_granted_scopes")
      expect(authorization_query).not_to have_key("nonce")
      expect(authorization_query.fetch("scope")).not_to match(/openid|email|profile/)
    end

    it "bl_oauth: HttpOnly・SameSite=Lax・Path=/・Max-Age=600（開発・テストの http では Secure を付けない）。値は暗号化されている" do
      connect_start

      line = cookie_line("bl_oauth")
      expect(line).to be_present
      expect(line.downcase).to include("httponly", "samesite=lax", "path=/", "max-age=600")
      expect(line.downcase).not_to include("secure")
      value = cookie_value("bl_oauth")
      expect(value).not_to include(authorization_query.fetch("state"))
      expect(value).not_to include(user.id)
    end

    it "bl_oauth の中身: 用途 connect・内部のアカウント識別子・state・検証子。code_challenge は検証子の S256" do
      connect_start

      state = stored_state
      expect(state.purpose).to eq("connect")
      expect(state.user_id).to eq(user.id)
      expect(state.state).to eq(authorization_query.fetch("state"))
      expect(authorization_query.fetch("code_challenge")).to eq(s256_challenge(state.code_verifier))
      expect(state.code_verifier).to match(/\A[A-Za-z0-9_-]{86}\z/)
    end

    it "bl_oauth は、ログイン用に使えない（用途 connect を、login として開けない）" do
      connect_start

      expect do
        OAuthStateCookie.new(secret: Rails.application.secret_key_base).open(cookie_value("bl_oauth"), expected_purpose: "login", now: now)
      end.to raise_error(OAuthStateCookie::InvalidCookie)
    end

    it "検証子・state・bl_oauth の値は、応答の本文に出ない（認可 URL の state と code_challenge だけ）" do
      connect_start

      expect(response.body).not_to include(stored_state.code_verifier)
      expect(response.body).not_to include(cookie_value("bl_oauth"))
    end

    it "bl_session を設定しない（ログイン中のセッションを、そのまま使う）" do
      connect_start

      expect(cookie_line("bl_session")).to be_nil
      expect(Session.count).to eq(1)
    end

    it "測定イベント connect_started を、内部のアカウント識別子に紐づけて記録する（符号・区分を持たない。IP・sub を含めない）" do
      expect { connect_start }.to change(UsageEvent, :count).by(1)

      event = UsageEvent.last
      expect(event.event_type).to eq("connect_started")
      expect(event.user_id).to eq(user.id)
      expect(event.occurred_at).to eq(now)
      expect(event.attributes.slice("reason_code", "bucket", "browser_class").values.compact).to be_empty
      expect(event.attributes.values.map(&:to_s).join(" ")).not_to include(ApiHelpers::CLIENT_IP)
      expect(event.attributes.values.map(&:to_s).join(" ")).not_to include("dev-user-1")
    end

    it "呼ぶたびに、新しい state・検証子の認可 URL を作り、bl_oauth を置き換える（冪等ではない）" do
      connect_start
      first = authorization_query
      first_cookie = cookie_value("bl_oauth")
      connect_start

      expect(authorization_query.fetch("state")).not_to eq(first.fetch("state"))
      expect(authorization_query.fetch("code_challenge")).not_to eq(first.fetch("code_challenge"))
      expect(cookie_value("bl_oauth")).not_to eq(first_cookie)
    end

    it "接続済みのアカウントも、再接続を始められる。既存の接続は、この時点では変えない" do
      connection = create(:youtube_connection, :with_stream, user: user)
      before = connection.reload.attributes

      connect_start

      expect(response).to have_http_status(:ok)
      expect(connection.reload.attributes).to eq(before)
    end

    it "YouTube も Google も呼ばない・台帳に記帳しない（認可 URL を作るだけ）" do
      connect_start

      expect(QuotaEntry.count).to eq(0)
      expect(YoutubeConnection.count).to eq(0)
    end

    it "ログに、state・検証子・bl_oauth の値・sub を出さない" do
      output = capture_logs { connect_start }

      expect(output).not_to include(authorization_query.fetch("state"))
      expect(output).not_to include(stored_state.code_verifier)
      expect(output).not_to include(cookie_value("bl_oauth"))
      expect(output).not_to include("dev-user-1")
      expect(output).not_to include(ApiHelpers::CLIENT_IP)
    end
  end

  describe "認可と CSRF（共通の規約）" do
    it "ログインしていない: 401 not_logged_in。bl_oauth を設定しない・イベントを記録しない" do
      expect { connect_start(session: nil) }.not_to change(UsageEvent, :count)

      expect(response).to have_http_status(401)
      expect(json_body).to eq({ "error" => { "code" => "not_logged_in", "details" => {} } })
      expect(cookie_line("bl_oauth")).to be_nil
    end

    it "X-BL-Client が無い: 403 csrf_invalid" do
      connect_start(headers: { "X-BL-Client" => nil })

      expect(response).to have_http_status(403)
      expect(error_code).to eq("csrf_invalid")
      expect(cookie_line("bl_oauth")).to be_nil
    end

    it "X-CSRF-Token が違う・無い: 403 csrf_invalid" do
      connect_start(headers: { "X-CSRF-Token" => "dummy-wrong-token" })
      expect(response).to have_http_status(403)
      expect(error_code).to eq("csrf_invalid")

      connect_start(headers: { "X-CSRF-Token" => nil })
      expect(response).to have_http_status(403)
    end

    it "X-BFF-Secret が無い: 403 forbidden" do
      connect_start(headers: { "X-BFF-Secret" => nil })

      expect(response).to have_http_status(403)
      expect(error_code).to eq("forbidden")
    end

    it "セッションの無効（破棄したセッションの Cookie）は、401" do
      revoked = login
      SessionStore.new.revoke(revoked.session)

      connect_start(session: revoked)

      expect(response).to have_http_status(401)
    end

    it "GET では呼べない（経路は POST だけ）" do
      api_get "/api/youtube/connect/start", signed_in: login

      expect(response).to have_http_status(404)
    end

    it "ログインの方針は、ログインが要る（Api::YoutubeController#connect_start）" do
      expect(Api::YoutubeController.login_policy_for("connect_start")).to eq(:login)
    end
  end

  describe "入力の検証（recaptcha_token）" do
    [
      [ "無い", nil ],
      [ "空", "" ],
      [ "空白だけ", "   " ],
      [ "数値", 123 ],
      [ "配列", [ "dev-pass" ] ],
      [ "ハッシュ", { "a" => "dev-pass" } ]
    ].each do |label, value|
      it "recaptcha_token が#{label}: 422 invalid_input（fields に recaptcha_token）。bl_oauth を設定しない・イベントを記録しない" do
        body = label == "無い" ? {} : { recaptcha_token: value }

        expect { api_post "/api/youtube/connect/start", body, signed_in: login }.not_to change(UsageEvent, :count)

        expect(response).to have_http_status(422)
        expect(json_body).to eq({ "error" => { "code" => "invalid_input", "details" => { "fields" => [ "recaptcha_token" ] } } })
        expect(cookie_line("bl_oauth")).to be_nil
      end
    end

    it "recaptcha_token が長すぎる: 422 invalid_input" do
      connect_start("a" * (RecaptchaVerifier::TOKEN_MAX_LENGTH + 1))

      expect(response).to have_http_status(422)
    end

    it "壊れた JSON の本文・本文が空: 422 invalid_input" do
      api_post "/api/youtube/connect/start", raw_body: "{not json", signed_in: login, headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(422)

      api_post "/api/youtube/connect/start", signed_in: login
      expect(response).to have_http_status(422)
    end

    it "未知のキーは無視する" do
      api_post "/api/youtube/connect/start", { recaptcha_token: "dev-pass", unknown_key: 1 }, signed_in: login

      expect(response).to have_http_status(:ok)
    end

    it "入力の不備は、頻度制限に数えない（31 回送っても 429 にならない）" do
      31.times { api_post "/api/youtube/connect/start", {}, signed_in: login }
      expect(response).to have_http_status(422)

      connect_start
      expect(response).to have_http_status(:ok)
    end
  end

  describe "進行中の配信（接続・再接続を受け付けない。7.4）" do
    %w[ reserved awaiting_media confirming live interrupted ].each do |state|
      it "状態 #{state} の配信がある: 409 broadcast_in_progress（details は空）。bl_oauth を設定しない・イベントを記録しない・bot 判定を呼ばない" do
        create(:broadcast, user: user, state: state)
        verifier = instance_double(FakeRecaptchaVerifier)
        allow(verifier).to receive(:verify).and_return(:pass)
        use_gateways(google_oidc: ExternalServices.current.google_oidc, recaptcha_verifier: verifier)

        expect { connect_start }.not_to change(UsageEvent, :count)

        expect(response).to have_http_status(409)
        expect(json_body).to eq({ "error" => { "code" => "broadcast_in_progress", "details" => {} } })
        expect(cookie_line("bl_oauth")).to be_nil
        expect(verifier).not_to have_received(:verify)
      end
    end

    it "終了した配信だけなら、受け付ける" do
      create(:broadcast, :ended, user: user)

      connect_start

      expect(response).to have_http_status(:ok)
    end

    it "他のアカウントの配信は、関係ない（所有権）" do
      create(:broadcast, user: create(:user))

      connect_start

      expect(response).to have_http_status(:ok)
    end

    it "頻度制限・bot 判定より先: 進行中の配信があれば、bot 判定が不合格でも 409" do
      create(:broadcast, user: user)

      connect_start("dev-fail")

      expect(response).to have_http_status(409)
    end

    it "進行中の配信の拒否は、頻度制限に数えない（31 回拒否されても 429 にならない。配信が終われば通る）" do
      broadcast = create(:broadcast, user: user)
      31.times { connect_start }
      expect(response).to have_http_status(409)

      broadcast.update!(state: "ended", end_reason: "user_stop", ended_at: now)
      connect_start

      expect(response).to have_http_status(:ok)
    end

    it "入力の検証より後: 進行中の配信があっても、入力の不備は 422" do
      create(:broadcast, user: user)

      api_post "/api/youtube/connect/start", {}, signed_in: login

      expect(response).to have_http_status(422)
    end
  end

  describe "頻度制限（IP 単位で 30 回 / 時。ログインの開始とは別の計数）" do
    it "30 回までは通り、31 回目は 429 rate_limited（details の retry_at は、枠が空く時刻 = 最初の許可の 1 時間後。JST）" do
      30.times do
        connect_start
        expect(response).to have_http_status(:ok)
      end

      connect_start

      expect(response).to have_http_status(429)
      expect(json_body).to eq({ "error" => { "code" => "rate_limited", "details" => { "retry_at" => "2026-10-08T13:00:00+09:00" } } })
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "429 の応答は、bl_oauth を設定しない・イベントを記録しない・bot 判定を呼ばない・認可 URL を返さない" do
      verifier = instance_double(FakeRecaptchaVerifier)
      allow(verifier).to receive(:verify).and_return(:pass)
      use_gateways(google_oidc: ExternalServices.current.google_oidc, recaptcha_verifier: verifier)
      30.times { connect_start }
      events = UsageEvent.count

      connect_start

      expect(response).to have_http_status(429)
      expect(cookie_line("bl_oauth")).to be_nil
      expect(UsageEvent.count).to eq(events)
      expect(verifier).to have_received(:verify).exactly(30).times
      expect(response.body).not_to include("authorization_url")
    end

    it "bot 判定に失敗した要求も、計数に入る（30 回の失敗のあとの 31 回目は、403 ではなく 429）" do
      30.times { connect_start("dev-fail") }
      expect(response).to have_http_status(403)

      connect_start("dev-fail")

      expect(response).to have_http_status(429)
    end

    it "枠が空く時刻（1 時間後）を過ぎれば、また通る" do
      30.times { connect_start }
      connect_start
      expect(response).to have_http_status(429)

      clock[:now] = now + 3600
      connect_start

      expect(response).to have_http_status(:ok)
    end

    it "IP ごとに別の計数（X-Forwarded-For の先頭の IP）" do
      30.times { connect_start }

      connect_start(headers: { "X-Forwarded-For" => "203.0.113.99" })
      expect(response).to have_http_status(:ok)

      connect_start(headers: { "X-Forwarded-For" => "#{ApiHelpers::CLIENT_IP}, 198.51.100.7" })
      expect(response).to have_http_status(429)
    end

    it "ログインの開始とは別の計数: ログインの開始を 30 回使っても、接続の開始は通る。逆も同じ" do
      30.times { login_start }
      login_start
      expect(response).to have_http_status(429)

      connect_start
      expect(response).to have_http_status(:ok)

      29.times { connect_start }
      connect_start
      expect(response).to have_http_status(429)
      login_start(headers: { "X-Forwarded-For" => ApiHelpers::CLIENT_IP })
      expect(response).to have_http_status(429)
    end

    it "計数は IP 単位（アカウントではない）: 別のアカウントでも、同じ IP なら同じ計数" do
      30.times { connect_start }
      other = sign_in(create(:user), now: now)

      connect_start(session: other)

      expect(response).to have_http_status(429)
    end

    it "IP アドレスを、DB・応答・ログに出さない" do
      output = capture_logs { 31.times { connect_start } }

      expect(output).not_to include(ApiHelpers::CLIENT_IP)
      expect(response.body).not_to include(ApiHelpers::CLIENT_IP)
      expect(UsageEvent.all.map(&:attributes).to_s).not_to include(ApiHelpers::CLIENT_IP)
    end
  end

  describe "bot 判定（行為名 youtube_connect）" do
    it "dev-fail（不合格）: 403 bot_check_failed。bl_oauth を設定しない・認可 URL を返さない・イベントを記録しない" do
      expect { connect_start("dev-fail") }.not_to change(UsageEvent, :count)

      expect(response).to have_http_status(403)
      expect(json_body).to eq({ "error" => { "code" => "bot_check_failed", "details" => {} } })
      expect(cookie_line("bl_oauth")).to be_nil
      expect(response.body).not_to include("authorization_url")
    end

    it "dev-indeterminate（判定不能）も 403 bot_check_failed（受理側へ倒さない）" do
      connect_start("dev-indeterminate")

      expect(response).to have_http_status(403)
      expect(error_code).to eq("bot_check_failed")
    end

    it "疑似のトークン以外は不合格" do
      connect_start("dummy-real-looking-recaptcha-token")

      expect(response).to have_http_status(403)
    end

    it "検証サービスへ、トークン・行為名 youtube_connect・公開オリジンのホスト・現在時刻を渡す" do
      verifier = instance_double(FakeRecaptchaVerifier)
      allow(verifier).to receive(:verify).and_return(:pass)
      use_gateways(google_oidc: ExternalServices.current.google_oidc, recaptcha_verifier: verifier)

      connect_start("dummy-token-0001")

      expect(verifier).to have_received(:verify).with(token: "dummy-token-0001", expected_action: "youtube_connect", hostname: ApiHelpers::PUBLIC_HOST, now: now)
    end

    it "行為名は、契約の表（1.8）と同じ youtube_connect" do
      expect(Api::YoutubeController::RECAPTCHA_ACTION).to eq("youtube_connect")
    end

    it "検証サービスの失敗（例外）は、握りつぶさない: 500 internal_error。受理しない。ログに例外の文面を出さない" do
      verifier = instance_double(FakeRecaptchaVerifier)
      allow(verifier).to receive(:verify).and_raise(RuntimeError, "boom dummy-secret-detail")
      use_gateways(google_oidc: ExternalServices.current.google_oidc, recaptcha_verifier: verifier)

      output = capture_logs { connect_start }

      expect(response).to have_http_status(500)
      expect(json_body).to eq({ "error" => { "code" => "internal_error", "details" => {} } })
      expect(cookie_line("bl_oauth")).to be_nil
      expect(output).not_to include("dummy-secret-detail")
    end
  end

  describe "公開オリジン" do
    it "認可 URL の redirect_uri は、公開オリジン（X-Forwarded-Host・X-Forwarded-Proto）から作る。バックエンドの Host を使わない" do
      connect_start(
        headers: {
          "Host" => "backend-production-1234.up.railway.app", "X-Forwarded-Host" => "localhost:3000",
          "X-Forwarded-Proto" => "http", "Origin" => "http://localhost:3000"
        }
      )

      expect(authorization_query.fetch("redirect_uri")).to eq("http://localhost:3000/api/youtube/connect/callback")
      expect(json_body.fetch("authorization_url")).to start_with("http://localhost:3000/api/dev/google/connect?")
    end

    it "公開オリジンが分からない（X-Forwarded-Host が無い）: Origin を照合できず、拒否側へ倒す（403 csrf_invalid）。認可 URL を作らない" do
      connect_start(headers: { "X-Forwarded-Host" => nil })

      expect(response).to have_http_status(403)
      expect(error_code).to eq("csrf_invalid")
      expect(cookie_line("bl_oauth")).to be_nil
    end

    it "公開オリジンと違う Origin（別のサイトからのフォームの送信）は、403 csrf_invalid" do
      connect_start(headers: { "Origin" => "https://evil.example.test" })

      expect(response).to have_http_status(403)
      expect(error_code).to eq("csrf_invalid")
    end
  end

  describe "実物の Google（WebMock。本番の環境の判定を想定した認可 URL）" do
    let(:http) { ExternalHttp.new }
    let(:real_oidc) do
      GoogleOidcClient.new(
        client_id: "dummy-client-id-0001.apps.googleusercontent.com", client_secret: "dummy-google-client-secret-0001", http: http,
        endpoints: ExternalServices.config.fetch(:google_oidc),
        jwks_cache: GoogleJwksCache.new(http: http, jwks_uri: ExternalServices.config.fetch(:google_oidc).fetch(:jwks_uri), ttl_seconds: 3600, min_refetch_seconds: 60)
      )
    end

    it "認可 URL は Google の認可の画面（https://accounts.google.com）。client_id つき・スコープは youtube の 1 種" do
      use_gateways(google_oidc: real_oidc, recaptcha_verifier: FakeRecaptchaVerifier.new)

      connect_start

      uri = URI.parse(json_body.fetch("authorization_url"))
      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq("https://accounts.google.com/o/oauth2/v2/auth")
      expect(authorization_query).to include(
        "client_id" => "dummy-client-id-0001.apps.googleusercontent.com", "scope" => youtube_scope, "access_type" => "offline",
        "prompt" => "consent", "login_hint" => "dev-user-1", "redirect_uri" => callback_url
      )
      expect(authorization_query).not_to have_key("include_granted_scopes")
    end
  end
end
