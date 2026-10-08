require "rails_helper"
require "support/api_helpers"
require "support/auth_flow_helpers"

# POST /api/auth/logout（src/contracts/http-api.md 3 章。issue #8。requirements.md 7.1・28.1）。
# セッションを破棄し、bl_session を失効させる（204）。ログイン済みのみ。状態を変える要求なので、CSRF の対象（X-BL-Client・X-CSRF-Token）。
RSpec.describe "POST /api/auth/logout", type: :request do
  include ApiHelpers
  include AuthFlowHelpers
  include_context "API の環境"

  let(:user) { create(:user) }
  let(:signed_in) { sign_in(user) }

  def logout(**options)
    api_post "/api/auth/logout", **options
  end

  it "204。サーバー側のセッションを破棄し、bl_session を失効させる" do
    logout(signed_in: signed_in)

    expect(response).to have_http_status(:no_content)
    expect(response.body).to be_empty
    expect(Session.exists?(signed_in.session.id)).to be(false)
    expect(expired_cookie?(SessionCookie::NAME)).to be(true)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "失効の Set-Cookie は、設定のときと同じ Path・HttpOnly・SameSite（ブラウザが確実に消す）" do
    logout(signed_in: signed_in)

    line = cookie_line(SessionCookie::NAME).downcase
    expect(line).to include("path=/", "httponly", "samesite=lax")
  end

  it "ログアウトしたあと、同じ識別子では、ログインが必要な API が 401" do
    logout(signed_in: signed_in)

    api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in

    expect(response).to have_http_status(401)
    expect(error_code).to eq("not_logged_in")
  end

  it "2 回目は 401 not_logged_in（セッションが無い）" do
    logout(signed_in: signed_in)
    logout(signed_in: signed_in)

    expect(response).to have_http_status(401)
    expect(json_body).to eq({ "error" => { "code" => "not_logged_in", "details" => {} } })
  end

  it "ログインしていない: 401 not_logged_in" do
    logout

    expect(response).to have_http_status(401)
    expect(error_code).to eq("not_logged_in")
    expect(cookie_line(SessionCookie::NAME)).to be_nil
  end

  it "破棄するのは、このセッションだけ（同じアカウントの別の端末のセッションと、ほかのアカウントのセッションは残る）" do
    other_device = sign_in(user)
    bystander = sign_in

    logout(signed_in: signed_in)

    expect(Session.exists?(signed_in.session.id)).to be(false)
    expect(Session.exists?(other_device.session.id)).to be(true)
    expect(Session.exists?(bystander.session.id)).to be(true)
    expect(User.exists?(user.id)).to be(true)
  end

  it "X-BL-Client が無い: 403 csrf_invalid。セッションは残る" do
    logout(signed_in: signed_in, headers: { "X-BL-Client" => nil })

    expect(response).to have_http_status(403)
    expect(error_code).to eq("csrf_invalid")
    expect(Session.exists?(signed_in.session.id)).to be(true)
  end

  it "X-CSRF-Token が無い・違う: 403 csrf_invalid。セッションは残る（クロスサイトの要求で、ログアウトさせられない）" do
    logout(signed_in: signed_in, headers: { "X-CSRF-Token" => nil })
    expect(response).to have_http_status(403)

    logout(signed_in: signed_in, headers: { "X-CSRF-Token" => "0" * 64 })
    expect(response).to have_http_status(403)
    expect(Session.exists?(signed_in.session.id)).to be(true)
  end

  it "Origin が公開オリジンと違う: 403 csrf_invalid" do
    logout(signed_in: signed_in, headers: { "Origin" => "https://evil.example.test" })

    expect(response).to have_http_status(403)
    expect(Session.exists?(signed_in.session.id)).to be(true)
  end

  it "X-BFF-Secret が無い: 403 forbidden" do
    logout(signed_in: signed_in, headers: { "X-BFF-Secret" => nil })

    expect(response).to have_http_status(403)
    expect(error_code).to eq("forbidden")
  end

  it "GET は経路が無い（404）" do
    api_get "/api/auth/logout", signed_in: signed_in

    expect(response).to have_http_status(404)
    expect(Session.exists?(signed_in.session.id)).to be(true)
  end

  it "ログインの方針は、ログインが必要と宣言している（Api::AuthController#logout）" do
    expect(Api::AuthController.login_policy_for("logout")).to eq(:login)
  end

  it "疑似のログインで得たセッションで、ログアウトできる（ログイン → ログアウトの往復）" do
    fresh_rate_limiter({ now: Time.current })
    run_fake_login
    token = cookie_value(SessionCookie::NAME)
    session_user = Session.sole.user
    login = ApiHelpers::SignedIn.new(user: session_user, token: token, session: Session.sole, csrf_token: csrf_token_for(token))

    logout(signed_in: login)

    expect(response).to have_http_status(:no_content)
    expect(Session.count).to eq(0)
  end
end
