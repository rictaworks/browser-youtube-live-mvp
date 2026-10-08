require "rails_helper"
require "support/api_helpers"
require "support/auth_flow_helpers"
require "support/google_oidc_support"
require "support/log_capture"

# GET /api/dev/google/authorize（疑似の Google の、アカウント選択の画面。issue #8）。開発・テストのみ。契約の外（http-api.md 1.1）。
# 固定の 3 アカウント（dev-user-1〜dev-user-3）を表示し、選ぶと redirect_uri?code=…&state=… へ戻す。コードは sub と nonce を含む（ステートレス）。
# 画面は ERB の最小のページ。文言は config/locales/ja.yml。ログインの操作は本番と同じ経路で、この画面は認可 URL の行き先だけを差し替える。
RSpec.describe "GET /api/dev/google/authorize（疑似の Google）", type: :request do
  include ApiHelpers
  include AuthFlowHelpers
  include GoogleOidcSupport
  include ActiveSupport::Testing::TimeHelpers
  include_context "API の環境"

  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:origin) { ApiHelpers::PUBLIC_ORIGIN }
  let(:callback_url) { "#{origin}/api/auth/callback" }
  let(:state) { SecureRandom.urlsafe_base64(32) }
  let(:nonce) { SecureRandom.urlsafe_base64(32) }
  let(:verifier) { SecureRandom.urlsafe_base64(64) }
  let(:challenge) { s256_challenge(verifier) }
  let(:fake) { FakeGoogleOidc.new(secret: Rails.application.secret_key_base) }

  before { travel_to(now) }
  after { travel_back }

  def query(overrides = {})
    {
      response_type: "code", scope: "openid", redirect_uri: callback_url, state: state, nonce: nonce,
      code_challenge: challenge, code_challenge_method: "S256"
    }.merge(overrides)
  end

  # overrides は、既定のパラメータを置き換える値（nil にすると、そのパラメータを付けない）。ハッシュでも、キーワードでも渡せる
  def authorize(overrides = {}, headers: {}, **inline)
    pairs = query(overrides.merge(inline)).compact
    api_get "/api/dev/google/authorize?#{URI.encode_www_form(pairs)}", headers: no_cookies.merge(headers)
  end

  describe "アカウント選択の画面" do
    before { authorize }

    it "200。HTML（UTF-8）。Cache-Control: no-store" do
      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to eq("text/html; charset=utf-8")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "固定の 3 アカウント（dev-user-1〜dev-user-3）だけを、リンクで表示する" do
      expect(account_links.keys).to eq(%w[ dev-user-1 dev-user-2 dev-user-3 ])
    end

    it "各リンクは、redirect_uri?code=…&state=…（公開オリジンのコールバック。state はそのまま返す）" do
      account_links.each_value do |href|
        uri = URI.parse(href)
        expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq(callback_url)
        expect(Rack::Utils.parse_query(uri.query).keys).to eq(%w[ code state ])
        expect(Rack::Utils.parse_query(uri.query).fetch("state")).to eq(state)
      end
    end

    it "コードは、選んだアカウントの sub と、開始の nonce・PKCE の challenge・redirect_uri を含む（ステートレス）。認証つき" do
      account_links.each do |name, href|
        code = Rack::Utils.parse_query(URI.parse(href).query).fetch("code")

        identity = fake.authenticate(code: code, code_verifier: verifier, nonce: nonce, redirect_uri: callback_url, now: now)

        expect(identity.sub).to eq(name)
        expect { fake.authenticate(code: code, code_verifier: verifier, nonce: "dummy-other-nonce", redirect_uri: callback_url, now: now) }.to raise_error(GoogleOidc::AuthenticationFailed)
      end
    end

    it "アカウントごとのコードは別の値" do
      codes = account_links.values.map { |href| Rack::Utils.parse_query(URI.parse(href).query).fetch("code") }

      expect(codes.uniq.size).to eq(3)
    end

    it "選択はリンク（GET）だけ。フォーム・スクリプト・外部の資源を持たない" do
      document = Nokogiri::HTML(response.body)

      expect(document.css("form, script, iframe, img, link, object, embed")).to be_empty
      expect(document.css("a").size).to eq(3)
      expect(document.css("[src]")).to be_empty
    end

    it "文言は config/locales/ja.yml から（title と見出しは、ja.dev.google.authorize.title）" do
      document = Nokogiri::HTML(response.body)
      title = I18n.t("dev.google.authorize.title", locale: :ja)

      expect(title).to be_present
      expect(document.at_css("title").text).to eq(title)
      expect(document.at_css("h1").text).to eq(title)
      expect(document.at_css("html")["lang"]).to eq("ja")
    end

    it "検索エンジンに載せない（noindex）" do
      expect(Nokogiri::HTML(response.body).at_css('meta[name="robots"]')["content"]).to eq("noindex")
    end

    it "Cookie を設定しない・DB を書き換えない・セッションを要しない" do
      expect(response.headers["Set-Cookie"]).to be_nil
      expect { authorize }.not_to change { [ User.count, Session.count, UsageEvent.count, DeletionHold.count ] }
    end
  end

  describe "ログインの全体の流れ（疑似の画面を経由する）" do
    it "開始 → 疑似の画面 → アカウントの選択 → コールバック → /studio。ログイン済みになる" do
      fresh_rate_limiter({ now: now })

      run_fake_login(account: "dev-user-2")

      expect(response).to have_http_status(:found)
      expect(response.headers["Location"]).to eq("#{origin}/studio")
      expect(User.sole.google_sub).to eq("dev-user-2")
      expect(cookie_value(SessionCookie::NAME)).to be_present
    end
  end

  describe "パラメータの検査（不正なら、画面を出さずに 422 invalid_input）" do
    def expect_invalid(*fields)
      expect(response).to have_http_status(422)
      expect(json_body).to eq({ "error" => { "code" => "invalid_input", "details" => { "fields" => fields } } })
      expect(response.body).not_to include("<a")
    end

    it "redirect_uri が、公開オリジンのコールバックと違う（別のホスト・http・パス・クエリ・末尾のスラッシュ・javascript:）" do
      [
        "https://evil.example.test/api/auth/callback",
        "http://#{ApiHelpers::PUBLIC_HOST}/api/auth/callback",
        "#{origin}/api/auth/callback/",
        "#{origin}/api/auth/callback?x=1",
        "#{origin}/api/auth/callback#frag",
        "#{origin}/other",
        "#{origin}.evil.example.test/api/auth/callback",
        "javascript:alert(1)",
        "//#{ApiHelpers::PUBLIC_HOST}/api/auth/callback",
        "/api/auth/callback",
        ""
      ].each do |bad|
        authorize(redirect_uri: bad)
        expect_invalid("redirect_uri")
      end
    end

    it "redirect_uri が無い・配列" do
      authorize(redirect_uri: nil)
      expect_invalid("redirect_uri")

      api_get "/api/dev/google/authorize?#{URI.encode_www_form(query.except(:redirect_uri))}&redirect_uri[]=#{CGI.escape(callback_url)}", headers: no_cookies
      expect_invalid("redirect_uri")
    end

    it "response_type が code でない・scope が openid でない（email などを要求する）・code_challenge_method が S256 でない" do
      authorize(response_type: "token")
      expect_invalid("response_type")

      authorize(scope: "openid email")
      expect_invalid("scope")

      authorize(scope: "openid profile")
      expect_invalid("scope")

      authorize(code_challenge_method: "plain")
      expect_invalid("code_challenge_method")
    end

    it "state・nonce・code_challenge が無い・空" do
      %i[ state nonce code_challenge ].each do |name|
        authorize(name => nil)
        expect_invalid(name.to_s)

        authorize(name => "")
        expect_invalid(name.to_s)
      end
    end

    it "state・nonce・code_challenge に、base64url 以外の文字（HTML・URL を壊す文字）を含む" do
      [ "a b", "a<b", "a\"b", "a'b", "a&b", "a>b", "a/b", "a?b", "a#b", "a%20b", "a+b", "a=b", "<script>alert(1)</script>", "あ" ].each do |bad|
        %i[ state nonce code_challenge ].each do |name|
          authorize(name => bad)
          expect_invalid(name.to_s)
        end
      end
    end

    it "state・nonce・code_challenge が長すぎる（#{OAuthStateCookie::MAX_FIELD_LENGTH + 1} 文字）" do
      %i[ state nonce code_challenge ].each do |name|
        authorize(name => "a" * (OAuthStateCookie::MAX_FIELD_LENGTH + 1))
        expect_invalid(name.to_s)
      end
    end

    it "不備のある項目が複数なら、すべて挙げる（契約の順）" do
      authorize(redirect_uri: "https://evil.example.test/", state: "a b", scope: "email")

      expect(response).to have_http_status(422)
      expect(json_body.dig("error", "details", "fields")).to eq(%w[ scope redirect_uri state ])
    end

    it "HTML に、検査を通らなかった値が現れない" do
      authorize(state: "<script>alert(1)</script>")

      expect(response.body).not_to include("alert(1)")
    end
  end

  describe "公開オリジン（開発: http://localhost:3000）" do
    it "redirect_uri は、BFF が付けた X-Forwarded-Host・X-Forwarded-Proto から作った公開オリジンのコールバックだけを受け付ける" do
      headers = { "X-Forwarded-Host" => "localhost:3000", "X-Forwarded-Proto" => "http" }

      authorize({ redirect_uri: "http://localhost:3000/api/auth/callback" }, headers: headers)

      expect(response).to have_http_status(:ok)
      expect(account_links.values).to all(start_with("http://localhost:3000/api/auth/callback?code="))

      authorize({ redirect_uri: callback_url }, headers: headers)
      expect(response).to have_http_status(422)
    end

    it "公開オリジンが分からない（X-Forwarded-Host が無い）: 500 internal_error（バックエンドのホストへ倒さない）" do
      authorize({}, headers: { "X-Forwarded-Host" => nil })

      expect(response).to have_http_status(500)
      expect(error_code).to eq("internal_error")
    end
  end

  describe "共通の規約（#7 の基盤）と、疑似の実装でないとき" do
    it "X-BFF-Secret が無い: 403 forbidden（BFF を通らずに、画面を出さない）" do
      authorize({}, headers: { "X-BFF-Secret" => nil })

      expect(response).to have_http_status(403)
      expect(error_code).to eq("forbidden")
    end

    it "ログインの方針は、匿名と宣言している（Dev::GoogleController#authorize）" do
      expect(Dev::GoogleController.login_policy_for("authorize")).to eq(:anonymous)
    end

    it "POST は経路が無い（GET だけ）" do
      api_post "/api/dev/google/authorize", {}

      expect(response).to have_http_status(404)
    end

    it "使っている実装が疑似の Google でなければ（実物が選ばれているなら）、画面を出さない: 404 not_found" do
      live = instance_double(GoogleOidcClient)
      use_gateways(google_oidc: live, recaptcha_verifier: ExternalServices.current.recaptcha_verifier)

      authorize

      expect(response).to have_http_status(404)
      expect(error_code).to eq("not_found")
      expect(response.body).not_to include("<a")
    end

    it "ログ: state・nonce・コードの値は出ない。画面を出した事実だけ" do
      output = capture_logs { authorize }

      expect(output).to include("Dev::GoogleController#authorize")
      [ state, nonce ].each { |value| expect(output).not_to include(value) }
      account_links.each_value do |href|
        expect(output).not_to include(Rack::Utils.parse_query(URI.parse(href).query).fetch("code"))
      end
    end
  end
end
