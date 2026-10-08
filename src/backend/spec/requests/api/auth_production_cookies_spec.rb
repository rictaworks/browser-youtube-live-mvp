require "rails_helper"
require "support/api_helpers"
require "support/auth_flow_helpers"

# 本番の構成での Cookie（issue #8。#7 のレビューの提案 P5。requirements.md 7.1・28.1）。
# セッションの Cookie は HttpOnly・Secure・SameSite=Lax。本番は Secure を付ける（開発・テストの http では付けない。CookiePolicy）。
# 本番の環境の判定（AppEnvironment）を使い、HTTPS の要求として届いたときの Set-Cookie に Secure が付くことを確かめる。
# Rails は、SSL でない要求には、Secure の Cookie を書かない。Railway は TLS を終端するので、本番は assume_ssl で、すべての要求を
# SSL として扱う（config/environments/production.rb。spec/config/production_ssl_spec.rb が、assume_ssl と force_ssl を静的に検査する）。
RSpec.describe "本番の構成での Set-Cookie（Secure）", type: :request do
  include ApiHelpers
  include AuthFlowHelpers
  include ActiveSupport::Testing::TimeHelpers
  include_context "API の環境"

  let(:production) { AppEnvironment.new("production") }
  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  # 本番では、assume_ssl が、HTTPS の要求として扱う。テストでは、HTTPS の要求として届いたことを、環境で表す
  let(:https_env) { public_listener_env.merge("HTTPS" => "on") }

  before do
    travel_to(now)
    fresh_rate_limiter({ now: now })
    # 疑似の実装は、テストの環境の判定で先に作る（構築時の環境の検査を通す）。要求の処理中だけ、環境の判定を本番にする
    test_environment = AppEnvironment.new("test")
    @fake = FakeGoogleOidc.new(secret: Rails.application.secret_key_base, environment: test_environment)
    use_gateways(google_oidc: @fake, recaptcha_verifier: FakeRecaptchaVerifier.new(environment: test_environment))
    allow(AppEnvironment).to receive(:current).and_return(production)
  end

  after { travel_back }

  def attributes_of(line)
    line.downcase.split(";").map(&:strip)
  end

  it "前提: 環境の判定は本番。Cookie の方針は Secure" do
    expect(AppEnvironment.current.production?).to be(true)
    expect(CookiePolicy.secure?).to be(true)
    expect(SessionCookie.attributes("dummy-token")).to include(secure: true, httponly: true, same_site: :lax, path: "/")
    expect(OAuthStateCookie.attributes("dummy-sealed")).to include(secure: true, httponly: true, same_site: :lax, path: "/", max_age: 600)
  end

  it "login/start の bl_oauth: Secure・HttpOnly・SameSite=Lax・Path=/・Max-Age=600" do
    login_start("dev-pass", env: https_env)

    expect(response).to have_http_status(:ok)
    attributes = attributes_of(cookie_line("bl_oauth"))
    expect(attributes).to include("secure", "httponly", "samesite=lax", "path=/", "max-age=600")
  end

  it "callback の成功: bl_session は Secure・HttpOnly・SameSite=Lax・Path=/（有効期限の属性は付けない）。bl_oauth の失効も Secure" do
    login_start("dev-pass", env: https_env)
    oauth_cookie = cookie_value("bl_oauth")
    state = Rack::Utils.parse_query(URI.parse(json_body.fetch("authorization_url")).query)
    code = @fake.issue_code(
      sub: "dev-user-1", nonce: state.fetch("nonce"), code_challenge: state.fetch("code_challenge"),
      redirect_uri: "#{ApiHelpers::PUBLIC_ORIGIN}/api/auth/callback", now: now
    )

    api_get "/api/auth/callback?#{URI.encode_www_form(code: code, state: state.fetch('state'))}", env: https_env,
            headers: { "Cookie" => cookie_header_of(oauth_cookie, nil) }

    expect(response.headers["Location"]).to eq("#{ApiHelpers::PUBLIC_ORIGIN}/studio")
    session_attributes = attributes_of(cookie_line("bl_session"))
    expect(session_attributes).to include("secure", "httponly", "samesite=lax", "path=/")
    expect(session_attributes.grep(/\Amax-age|\Aexpires/)).to be_empty
    expired = attributes_of(cookie_line("bl_oauth"))
    expect(expired).to include("secure", "httponly", "samesite=lax", "path=/")
    expect(expired_cookie?("bl_oauth")).to be(true)
  end

  it "callback の失敗でも、bl_oauth の失効に Secure を付ける" do
    api_get "/api/auth/callback?error=access_denied", env: https_env, headers: no_cookies

    expect(response.headers["Location"]).to eq("#{ApiHelpers::PUBLIC_ORIGIN}/?login_error=oauth_failed")
    expect(attributes_of(cookie_line("bl_oauth"))).to include("secure", "httponly", "samesite=lax", "path=/")
  end

  it "logout の bl_session の失効にも Secure を付ける（設定のときと同じ属性）" do
    signed_in = sign_in

    api_post "/api/auth/logout", signed_in: signed_in, env: https_env

    expect(response).to have_http_status(:no_content)
    expect(attributes_of(cookie_line("bl_session"))).to include("secure", "httponly", "samesite=lax", "path=/")
    expect(expired_cookie?("bl_session")).to be(true)
  end

  it "SSL でない要求には、Rails は Secure の Cookie を書かない（だから、本番は assume_ssl で、すべての要求を SSL として扱う）" do
    login_start("dev-pass")

    expect(response).to have_http_status(:ok)
    expect(cookie_line("bl_oauth")).to be_nil
  end

  it "開発・テストでは、Secure を付けない（http のブラウザが Cookie を保存できなくなる）" do
    allow(AppEnvironment).to receive(:current).and_return(AppEnvironment.new("development"))

    login_start("dev-pass")

    expect(attributes_of(cookie_line("bl_oauth"))).not_to include("secure")
  end
end
