require "rails_helper"
require "support/api_helpers"

# Api::BaseController が、後続の issue（#8・#11・#12・#16）の API へ提供する、共通の部品（issue #7）。
# 匿名のコントローラ（Api::BaseController の子）で、各部品を呼ぶ。経路・ミドルウェアは通らないので、
# ミドルウェアが置くもの（転送ヘッダの保管場所）は、ここで置く。ミドルウェアを通した動作は、spec/requests/api/。
RSpec.describe Api::BaseController, type: :controller do
  include ApiHelpers
  include_context "API の環境"

  let(:user) { create(:user) }
  let(:rate_clock) { { now: Time.utc(2026, 10, 7, 4, 30, 0) } }
  let(:limiter) { RateLimiter.new(clock: -> { rate_clock[:now] }) }

  controller(Api::BaseController) do
    requires_login only: %i[ members_only ]

    def public_action
      render json: { ok: true }
    end

    def members_only
      render json: { user_id: current_user.id }
    end

    def whoami
      render json: { user_id: current_user&.id, csrf_token: csrf_token }
    end

    def login_action
      issued = start_session!(User.find(params[:user_id]))
      render json: { token_length: issued.token.length }
    end

    def logout_action
      end_session!
      head :no_content
    end

    def oauth_start
      issue_oauth_cookie(purpose: params[:purpose], state: "dummy-state-0123", nonce: "dummy-nonce-0123", code_verifier: "dummy-verifier-0123456789", user_id: params[:user_id])
      head :no_content
    end

    def oauth_finish
      payload = consume_oauth_cookie(expected_purpose: params[:purpose])
      render json: { state: payload.state, purpose: payload.purpose, user_id: payload.user_id }
    rescue OAuthStateCookie::InvalidCookie
      render json: { invalid: true }, status: 400
    end

    def redirect_action
      redirect_to_public(params[:path])
    end

    def ip_action
      render json: { ip: client_ip.to_s, known: client_ip.known?, origin: public_origin.to_s }
    end

    def limited_action
      enforce_rate_limit!(RateLimitPolicy.recheck, "7c9d1e2f-3a4b-4c5d-8e6f-0a1b2c3d4e5f")
      head :no_content
    end

    def lookup_action
      current_session
      current_user
      current_session
      render json: { queries: 1 }
    end

    def not_found_action
      raise ActiveRecord::RecordNotFound
    end
  end

  before do
    routes.draw do
      get "public_action" => "api/base#public_action"
      get "members_only" => "api/base#members_only"
      get "whoami" => "api/base#whoami"
      post "login_action" => "api/base#login_action"
      post "logout_action" => "api/base#logout_action"
      post "oauth_start" => "api/base#oauth_start"
      get "oauth_finish" => "api/base#oauth_finish"
      get "redirect_action" => "api/base#redirect_action"
      get "ip_action" => "api/base#ip_action"
      get "limited_action" => "api/base#limited_action"
      get "lookup_action" => "api/base#lookup_action"
      get "not_found_action" => "api/base#not_found_action"
    end
    allow(RateLimiter).to receive(:shared).and_return(limiter)
  end

  # ミドルウェア（ForwardedHeaders）が置くものと、BFF の秘密値を、要求へ入れる
  def verified_request(forwarded_for: "203.0.113.5", forwarded_host: "app.example.test", forwarded_proto: "https", state_changing: false)
    request.headers["X-BFF-Secret"] = ApiHelpers::BFF_SECRET
    request.env[ForwardedHeaders::ENV_KEY] = ForwardedHeaders::Values.new(forwarded_for: forwarded_for, forwarded_host: forwarded_host, forwarded_proto: forwarded_proto)
    return unless state_changing

    request.headers["X-BL-Client"] = "web"
  end

  def set_cookie_headers
    Array(response.headers["Set-Cookie"]).flat_map { |value| value.to_s.split("\n") }
  end

  def cookie_header(name)
    set_cookie_headers.find { |line| line.start_with?("#{name}=") }
  end

  describe "requires_login（ログインが要る API）" do
    it "指定した動作だけが、ログインを要する（only）。ほかの動作は、ログインしていなくても通る" do
      verified_request
      get :public_action

      expect(response).to have_http_status(:ok)
    end

    it "ログインが要る動作は、セッションが無ければ 401 not_logged_in" do
      verified_request
      get :members_only

      expect(response).to have_http_status(401)
      expect(JSON.parse(response.body)).to eq({ "error" => { "code" => "not_logged_in", "details" => {} } })
    end

    it "ログインが要る動作は、有効なセッションがあれば、current_user が分かる" do
      signed_in = sign_in(user)
      verified_request
      cookies[SessionCookie::NAME] = signed_in.token
      get :members_only

      expect(JSON.parse(response.body)).to eq({ "user_id" => user.id })
    end

    it "requires_login を使わない子クラスは、すべての動作がログインを要しない" do
      expect(Api::BaseController.login_required_for?("anything")).to be(false)
    end

    it "except も指定できる" do
      klass = Class.new(Api::BaseController) { requires_login except: %i[ open ] }

      expect(klass.login_required_for?("open")).to be(false)
      expect(klass.login_required_for?("closed")).to be(true)
    end

    it "引数なしなら、すべての動作がログインを要する" do
      klass = Class.new(Api::BaseController) { requires_login }

      expect(klass.login_required_for?("anything")).to be(true)
    end

    it "継承しても、親の設定は、子の設定で変わらない（別のクラスの設定を、書き換えない）" do
      first = Class.new(Api::BaseController) { requires_login }
      second = Class.new(Api::BaseController)

      expect(first.login_required_for?("x")).to be(true)
      expect(second.login_required_for?("x")).to be(false)
      expect(Api::BaseController.login_required_for?("x")).to be(false)
    end
  end

  describe "current_user・csrf_token" do
    it "ログインしていなければ、current_user は nil・csrf_token は nil" do
      verified_request
      get :whoami

      expect(JSON.parse(response.body)).to eq({ "user_id" => nil, "csrf_token" => nil })
    end

    it "ログイン済みなら、current_user はセッションのアカウント。csrf_token は、セッションから導出した値（GET /api/state が返す値）" do
      signed_in = sign_in(user)
      verified_request
      cookies[SessionCookie::NAME] = signed_in.token
      get :whoami

      expect(JSON.parse(response.body)).to eq({ "user_id" => user.id, "csrf_token" => signed_in.csrf_token })
    end

    it "1 回の要求の中で、セッションの検索は 1 回だけ（メモ化）" do
      signed_in = sign_in(user)
      verified_request
      cookies[SessionCookie::NAME] = signed_in.token

      statements = capture_sql { get :lookup_action }

      expect(statements.grep(/FROM "sessions"/).size).to eq(1)
    end
  end

  describe "start_session!（ログインの成立。#8 が使う）" do
    it "セッションを発行し、Cookie bl_session を設定する（HttpOnly・SameSite=Lax・Path=/。有効期限の属性なし。http のため Secure なし）" do
      verified_request(state_changing: true)
      post :login_action, params: { user_id: user.id }

      line = cookie_header("bl_session")
      expect(line).to be_present
      expect(line.downcase).to include("httponly", "samesite=lax", "path=/")
      expect(line.downcase).not_to include("max-age", "expires", "secure")
      token = line[/\Abl_session=([^;]+)/, 1]
      expect(token).to match(/\A[A-Za-z0-9_-]{43}\z/)
      expect(SessionStore.new.find(token, now: Time.current).user).to eq(user)
    end

    it "本番では、Secure を付ける" do
      allow(AppEnvironment).to receive(:current).and_return(AppEnvironment.new("production"))

      verified_request(state_changing: true)
      request.env["HTTPS"] = "on" # 本番は、SSL を終端するプロキシの背後（assume_ssl）。Rails は、Secure の Cookie を、SSL の要求にだけ書く
      post :login_action, params: { user_id: user.id }

      expect(cookie_header("bl_session").downcase).to include("secure")
    end

    it "既存のセッション（Cookie にあるもの）は、破棄する（セッション固定化の防止）" do
      old = sign_in(user)
      verified_request(state_changing: true)
      cookies[SessionCookie::NAME] = old.token
      request.headers["X-CSRF-Token"] = old.csrf_token

      post :login_action, params: { user_id: user.id }

      expect(response).to have_http_status(:ok)
      expect(Session.exists?(old.session.id)).to be(false)
      expect(Session.where(user_id: user.id).count).to eq(1)
    end

    it "Cookie の値は、新しい token（古い token と違う）" do
      old = sign_in(user)
      verified_request(state_changing: true)
      cookies[SessionCookie::NAME] = old.token
      request.headers["X-CSRF-Token"] = old.csrf_token

      post :login_action, params: { user_id: user.id }

      expect(cookie_header("bl_session")).not_to include(old.token)
    end
  end

  describe "end_session!（ログアウト）" do
    it "セッションを破棄し、Cookie を失効させる" do
      signed_in = sign_in(user)
      verified_request(state_changing: true)
      cookies[SessionCookie::NAME] = signed_in.token
      request.headers["X-CSRF-Token"] = signed_in.csrf_token

      post :logout_action

      expect(response).to have_http_status(:no_content)
      expect(Session.exists?(signed_in.session.id)).to be(false)
      line = cookie_header("bl_session")
      expect(line.downcase).to include("max-age=0")
      expect(line).to start_with("bl_session=;")
      expect(line.downcase).to include("httponly", "samesite=lax", "path=/")
    end

    it "セッションが無くても、例外にしない（Cookie を失効させる）" do
      verified_request(state_changing: true)

      post :logout_action

      expect(response).to have_http_status(:no_content)
      expect(cookie_header("bl_session").downcase).to include("max-age=0")
    end
  end

  describe "bl_oauth（認可の途中の状態。暗号化した短命の Cookie）" do
    it "login: HttpOnly・SameSite=Lax・Path=/・Max-Age=600 の Cookie を設定する。値は暗号化されている" do
      verified_request(state_changing: true)
      post :oauth_start, params: { purpose: "login" }

      line = cookie_header("bl_oauth")
      expect(line.downcase).to include("max-age=600", "httponly", "samesite=lax", "path=/")
      expect(line.downcase).not_to include("secure")
      expect(line).not_to include("dummy-state-0123")
      expect(line).not_to include("dummy-verifier")
    end

    it "本番では、Secure を付ける" do
      allow(AppEnvironment).to receive(:current).and_return(AppEnvironment.new("production"))
      verified_request(state_changing: true)
      request.env["HTTPS"] = "on"

      post :oauth_start, params: { purpose: "login" }

      expect(cookie_header("bl_oauth").downcase).to include("secure", "max-age=600")
    end

    it "connect: 内部のアカウント識別子を持つ。往復できる" do
      verified_request(state_changing: true)
      post :oauth_start, params: { purpose: "connect", user_id: user.id }
      sealed = cookie_header("bl_oauth")[/\Abl_oauth=([^;]+)/, 1]

      payload = OAuthStateCookie.new(secret: Rails.application.secret_key_base).open(CGI.unescape(sealed), expected_purpose: "connect", now: Time.current)

      expect(payload).to have_attributes(purpose: "connect", user_id: user.id, state: "dummy-state-0123")
    end

    it "consume_oauth_cookie: 用途が合えば、内容を返し、Cookie を失効させる（state の再利用を防ぐ）" do
      sealed = OAuthStateCookie.new(secret: Rails.application.secret_key_base).seal(
        state: "dummy-state-0123", nonce: "dummy-nonce-0123", code_verifier: "dummy-verifier-0123456789", purpose: "login", now: Time.current
      )
      verified_request
      cookies[OAuthStateCookie::NAME] = sealed

      get :oauth_finish, params: { purpose: "login" }

      expect(JSON.parse(response.body)).to eq({ "state" => "dummy-state-0123", "purpose" => "login", "user_id" => nil })
      expect(cookie_header("bl_oauth").downcase).to include("max-age=0")
    end

    # [ 説明, Cookie の値の作り方（nil なら、Cookie を送らない）, 期待する用途 ]
    {
      "用途違い（login の Cookie を connect で使う）" => [ ->(sealed) { sealed }, "connect" ],
      "Cookie が無い" => [ ->(_sealed) { nil }, "login" ],
      "改ざん（末尾に文字を足す）" => [ ->(sealed) { "#{sealed}x" }, "login" ],
      "でたらめな値" => [ ->(_sealed) { "garbage" }, "login" ]
    }.each do |label, (value_of, purpose)|
      it "consume_oauth_cookie: #{label}は InvalidCookie。失敗でも、Cookie を失効させる" do
        sealed = OAuthStateCookie.new(secret: Rails.application.secret_key_base).seal(
          state: "dummy-state-0123", nonce: "dummy-nonce-0123", code_verifier: "dummy-verifier-0123456789", purpose: "login", now: Time.current
        )
        value = value_of.call(sealed)
        verified_request
        cookies[OAuthStateCookie::NAME] = value if value

        get :oauth_finish, params: { purpose: purpose }

        expect(JSON.parse(response.body)).to eq({ "invalid" => true })
        expect(cookie_header("bl_oauth").to_s.downcase).to include("max-age=0")
      end
    end

    it "consume_oauth_cookie: 期限（600 秒）を過ぎた Cookie は、InvalidCookie" do
      sealed = OAuthStateCookie.new(secret: Rails.application.secret_key_base).seal(
        state: "dummy-state-0123", nonce: "dummy-nonce-0123", code_verifier: "dummy-verifier-0123456789", purpose: "login", now: 11.minutes.ago
      )
      verified_request
      cookies[OAuthStateCookie::NAME] = sealed

      get :oauth_finish, params: { purpose: "login" }

      expect(JSON.parse(response.body)).to eq({ "invalid" => true })
    end
  end

  describe "redirect_to_public（リダイレクト先は、公開オリジンの絶対 URL）" do
    it "BFF が付けた X-Forwarded-Host・X-Forwarded-Proto から、Location を作る（バックエンドのホストを含めない）" do
      verified_request(forwarded_host: "app.example.test", forwarded_proto: "https")
      request.host = "backend-production.up.railway.app"

      get :redirect_action, params: { path: "/studio" }

      expect(response).to have_http_status(302)
      expect(response.headers["Location"]).to eq("https://app.example.test/studio")
      expect(response.headers["Location"]).not_to include("railway")
    end

    it "クエリつきの経路" do
      verified_request
      get :redirect_action, params: { path: "/?login_error=oauth_failed" }

      expect(response.headers["Location"]).to eq("https://app.example.test/?login_error=oauth_failed")
    end

    it "開発（http・ポートつき）" do
      verified_request(forwarded_host: "localhost:3000", forwarded_proto: "http")
      get :redirect_action, params: { path: "/studio" }

      expect(response.headers["Location"]).to eq("http://localhost:3000/studio")
    end

    [ "//evil.example", "https://evil.example/", "studio", "/a b" ].each do |path|
      it "不正な経路 #{path.inspect} は、リダイレクトせず、500 internal_error（呼び出しの誤り）" do
        verified_request
        get :redirect_action, params: { path: path }

        expect(response).to have_http_status(500)
        expect(response.headers["Location"]).to be_nil
      end
    end

    it "公開オリジン（X-Forwarded-Host）が無ければ、リダイレクトしない（バックエンドのホストへ、補わない）。500 internal_error" do
      verified_request(forwarded_host: nil)
      get :redirect_action, params: { path: "/studio" }

      expect(response).to have_http_status(500)
      expect(response.headers["Location"]).to be_nil
    end

    it "公開オリジンが不正（経路を含む）なら、リダイレクトしない" do
      verified_request(forwarded_host: "evil.example/path")
      get :redirect_action, params: { path: "/studio" }

      expect(response).to have_http_status(500)
    end
  end

  describe "client_ip・public_origin（BFF の確認を通った要求から）" do
    it "X-Forwarded-For の先頭を、IP とする" do
      verified_request(forwarded_for: "203.0.113.5, 10.0.0.1")
      get :ip_action

      expect(JSON.parse(response.body)).to eq({ "ip" => "203.0.113.5", "known" => true, "origin" => "https://app.example.test" })
    end

    it "IP が分からなければ、unknown（別の値で補わない）" do
      verified_request(forwarded_for: nil)
      get :ip_action

      expect(JSON.parse(response.body)).to include("ip" => "unknown", "known" => false)
    end

    it "要求の接続元（REMOTE_ADDR）・Client-IP は、使わない" do
      verified_request(forwarded_for: nil)
      request.env["REMOTE_ADDR"] = "198.51.100.7"
      request.env["HTTP_CLIENT_IP"] = "198.51.100.8"
      get :ip_action

      expect(JSON.parse(response.body)).to include("ip" => "unknown")
    end

    it "BFF の確認を通っていない要求では、転送ヘッダを読めない（403。動作の中まで進まない）" do
      request.headers["X-BFF-Secret"] = "wrong"
      request.env[ForwardedHeaders::ENV_KEY] = ForwardedHeaders::Values.new(forwarded_for: "203.0.113.5", forwarded_host: "app.example.test", forwarded_proto: "https")
      get :ip_action

      expect(response).to have_http_status(403)
      expect(response.body).not_to include("203.0.113.5")
    end
  end

  describe "enforce_rate_limit!（頻度制限の適用。#8・#11・#12 が使う）" do
    it "上限までは通し、超えたら 429 rate_limited（details の retry_at は、枠が空く時刻。JST の ISO 8601）" do
      verified_request
      get :limited_action
      expect(response).to have_http_status(:no_content)

      verified_request
      get :limited_action

      expect(response).to have_http_status(429)
      expect(JSON.parse(response.body)).to eq({ "error" => { "code" => "rate_limited", "details" => { "retry_at" => "2026-10-07T13:31:00+09:00" } } })
    end

    it "枠が空く時刻になれば、また通る" do
      verified_request
      get :limited_action
      rate_clock[:now] += 61

      verified_request
      get :limited_action

      expect(response).to have_http_status(:no_content)
    end
  end

  describe "エラーの境界" do
    it "RecordNotFound は 404 not_found（他のアカウントのレコードも、存在しないものとして扱う）" do
      verified_request
      get :not_found_action

      expect(response).to have_http_status(404)
      expect(JSON.parse(response.body)).to eq({ "error" => { "code" => "not_found", "details" => {} } })
    end

    it "応答には Cache-Control: no-store と、JSON の Content-Type" do
      verified_request
      get :public_action

      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["Content-Type"]).to start_with("application/json")
    end
  end

  describe "共通の部品は、動作として公開されない" do
    it "共通の部品（start_session! など）は、private（public のメソッドは、Rails が動作として扱う）" do
      %i[ start_session! end_session! issue_oauth_cookie consume_oauth_cookie redirect_to_public enforce_rate_limit! client_ip public_origin current_user current_session csrf_token ].each do |name|
        expect(Api::BaseController.private_method_defined?(name)).to be(true), "#{name} が private ではない"
        expect(Api::BaseController.public_method_defined?(name)).to be(false), "#{name} が public"
      end
    end

    it "Api::BaseController の動作（action_methods）は、存在しない経路の 404 だけ" do
      expect(Api::BaseController.action_methods.to_a).to eq([ "route_not_found" ])
    end
  end
end
