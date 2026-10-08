require "rails_helper"
require "support/api_helpers"
require "support/auth_flow_helpers"
require "support/youtube_connect_support"
require "nokogiri"

# 疑似の Google の同意画面（YouTube 接続。issue #11）。開発・テストのみ。契約の外（src/contracts/http-api.md 1.1）。
#
#   GET /api/dev/google/connect          FakeGoogleOidc#youtube_authorization_url が返す行き先。認可の要求のパラメータを、本物に求める値と同じか検査して
#                                        （スコープは youtube の 1 種・offline・consent・PKCE の S256・戻り先は公開オリジンの YouTube 接続のコールバック・
#                                        include_granted_scopes と nonce は無い）、選択肢（リンク）を出す
#   GET /api/dev/google/connect/choose   選択肢を選ぶと、認可コード（または error=access_denied）を付けて、戻り先へ 302 で戻す。
#                                        チャンネルが無い・ライブ未有効・確認不能の選択肢は、疑似の YouTube へ失敗を注入してから戻す
# 本番には存在しない（経路を描かない・疑似でなければ画面を出さない・疑似は本番で構築できない）。開発者向けの近道（接続済みの状態を直接作る経路）は、持たない。
RSpec.describe "疑似の Google の同意画面（YouTube 接続）", type: :request do
  include ApiHelpers
  include AuthFlowHelpers
  include YouTubeConnectSupport
  include_context "API の環境"
  include_context "YouTube 接続の環境"

  let(:fake) { FakeGoogleOidc.new(secret: Rails.application.secret_key_base) }
  let(:origin) { ApiHelpers::PUBLIC_ORIGIN }
  let(:expected_callback) { "#{origin}/api/youtube/connect/callback" }
  let(:verifier) { "dummy-verifier-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789" }
  let(:authorization) do
    {
      "response_type" => "code", "scope" => youtube_scope, "redirect_uri" => expected_callback, "state" => "dummy-state-0001",
      "code_challenge" => s256_challenge(verifier), "code_challenge_method" => "S256", "access_type" => "offline",
      "prompt" => "consent", "login_hint" => "dev-user-1"
    }
  end
  let(:scenarios) do
    %w[ allow allow_live_not_enabled allow_no_channel allow_unverifiable allow_without_youtube allow_without_refresh_token deny ]
  end

  def consent(overrides = {})
    api_get "/api/dev/google/connect?#{URI.encode_www_form(authorization.merge(overrides).compact)}", headers: no_cookies
  end

  def choose(scenario, overrides = {})
    query = authorization.merge("scenario" => scenario).merge(overrides).compact
    api_get "/api/dev/google/connect/choose?#{URI.encode_www_form(query)}", headers: no_cookies
  end

  def redirect_query
    Rack::Utils.parse_query(URI.parse(response.headers["Location"]).query)
  end

  # 疑似の YouTube へ注入された失敗が、次の確認に当たるかを調べる（確認は 1 回で、注入を消費する）
  def probe_outcome
    YouTubeServices.current.youtube_gateway.probe_channel(nil, access_token: "fake-probe-token").outcome
  rescue YouTubeErrors::Base => error
    error.class.name.demodulize
  end

  describe "GET /api/dev/google/connect（選択肢の画面）" do
    it "200 の HTML。見出し（固有名詞 Google）と、選択肢のリンク 7 つ（識別子の表示）" do
      consent

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to start_with("text/html")
      expect(response.headers["Cache-Control"]).to eq("no-store")
      page = Nokogiri::HTML(response.body)
      expect(page.at_css("h1").text).to eq("Google")
      expect(page.css("a").map { |anchor| anchor.text.strip }).to eq(scenarios)
    end

    it "検索エンジンへ載せない（noindex）。日本語のページ" do
      consent

      page = Nokogiri::HTML(response.body)
      expect(page.at_css('meta[name="robots"]')["content"]).to eq("noindex")
      expect(page.at_css("html")["lang"]).to eq("ja")
    end

    it "各リンクは、同じ認可の要求のパラメータと、選択肢の識別子（scenario）を持つ、選択の経路（同一オリジンの相対パス）" do
      consent

      Nokogiri::HTML(response.body).css("a").each do |anchor|
        uri = URI.parse(anchor["href"])
        query = Rack::Utils.parse_query(uri.query)
        expect(uri.path).to eq("/api/dev/google/connect/choose")
        expect(uri.host).to be_nil
        expect(query.except("scenario")).to eq(authorization)
        expect(query.fetch("scenario")).to eq(anchor.text.strip)
      end
    end

    it "要求されたスコープ・アカウント（login_hint）を、書式なしの値として表示する（テスターが、要求の中身を確かめられる）" do
      consent

      expect(response.body).to include(youtube_scope)
      expect(response.body).to include("dev-user-1")
    end

    it "ログインしていなくても開ける（匿名と宣言している）。Cookie を設定しない" do
      consent

      expect(response).to have_http_status(:ok)
      expect(set_cookie_lines).to be_empty
    end

    it "DB を変えない・YouTube を呼ばない" do
      expect { consent }.not_to change { [ User.count, YoutubeConnection.count, QuotaEntry.count, UsageEvent.count ] }
    end
  end

  describe "認可の要求のパラメータの検査（本物に求める値と同じか。不備があれば 422 invalid_input で、項目名を挙げる）" do
    {
      "response_type が code でない" => [ { "response_type" => "token" }, %w[ response_type ] ],
      "スコープが openid（ログインのスコープ）" => [ { "scope" => "openid" }, %w[ scope ] ],
      "スコープが youtube.readonly（別のスコープ）" => [ { "scope" => "https://www.googleapis.com/auth/youtube.readonly" }, %w[ scope ] ],
      "スコープが 2 種" => [ { "scope" => "openid https://www.googleapis.com/auth/youtube" }, %w[ scope ] ],
      "スコープが無い" => [ { "scope" => nil }, %w[ scope ] ],
      "戻り先が違うオリジン" => [ { "redirect_uri" => "https://evil.example.test/api/youtube/connect/callback" }, %w[ redirect_uri ] ],
      "戻り先がログインのコールバック" => [ { "redirect_uri" => "https://app.example.test/api/auth/callback" }, %w[ redirect_uri ] ],
      "戻り先に余計なクエリ" => [ { "redirect_uri" => "https://app.example.test/api/youtube/connect/callback?x=1" }, %w[ redirect_uri ] ],
      "state が無い" => [ { "state" => nil }, %w[ state ] ],
      "state に使えない文字" => [ { "state" => "a b<c>" }, %w[ state ] ],
      "code_challenge が無い" => [ { "code_challenge" => nil }, %w[ code_challenge ] ],
      "PKCE の方式が S256 でない" => [ { "code_challenge_method" => "plain" }, %w[ code_challenge_method ] ],
      "オンライン（access_type が offline でない）" => [ { "access_type" => "online" }, %w[ access_type ] ],
      "同意画面を強制しない（prompt が consent でない）" => [ { "prompt" => "none" }, %w[ prompt ] ],
      "login_hint が無い" => [ { "login_hint" => nil }, %w[ login_hint ] ],
      "login_hint に使えない文字" => [ { "login_hint" => "a@example.test" }, %w[ login_hint ] ],
      "include_granted_scopes が付いている" => [ { "include_granted_scopes" => "true" }, %w[ include_granted_scopes ] ],
      "nonce が付いている（ID トークンを使わない）" => [ { "nonce" => "dummy-nonce" }, %w[ nonce ] ],
      "複数の不備（項目の順に挙げる）" => [ { "state" => nil, "scope" => "openid", "prompt" => "none" }, %w[ scope state prompt ] ]
    }.each do |label, (overrides, fields)|
      it "#{label}: 422 invalid_input（fields: #{fields.join('・')}）。選択肢の画面を出さない" do
        consent(overrides)

        expect(response).to have_http_status(422)
        expect(json_body).to eq({ "error" => { "code" => "invalid_input", "details" => { "fields" => fields } } })
        expect(response.body).not_to include("<a")
      end

      it "#{label}: 選択（choose）も 422。疑似の YouTube へ失敗を注入しない" do
        choose("allow_no_channel", overrides)

        expect(response).to have_http_status(422)
        expect(probe_outcome).to eq("connected")
      end
    end

    it "パラメータが配列・ハッシュ（state[]=x）でも、422（文字列でないものは不備）" do
      api_get "/api/dev/google/connect?#{URI.encode_www_form(authorization.except('state'))}&state[]=x", headers: no_cookies
      expect(response).to have_http_status(422)

      api_get "/api/dev/google/connect?#{URI.encode_www_form(authorization.except('scope'))}&scope[a]=x", headers: no_cookies
      expect(response).to have_http_status(422)
    end
  end

  describe "GET /api/dev/google/connect/choose（選択）" do
    it "allow: 戻り先（公開オリジンの YouTube 接続のコールバック）へ 302。code と state を付ける。コードは、全部を付与する（更新トークンつき）" do
      choose("allow")

      expect(response).to have_http_status(:found)
      expect(response.headers["Location"]).to start_with("#{expected_callback}?")
      expect(redirect_query.keys).to match_array(%w[ code state ])
      expect(redirect_query.fetch("state")).to eq("dummy-state-0001")
      grant = fake.exchange_youtube_code(code: redirect_query.fetch("code"), code_verifier: verifier, redirect_uri: expected_callback)
      expect(grant.scope?(youtube_scope)).to be(true)
      expect(grant.refresh_token?).to be(true)
    end

    it "allow_without_youtube: youtube のスコープを付与しないコード" do
      choose("allow_without_youtube")

      grant = fake.exchange_youtube_code(code: redirect_query.fetch("code"), code_verifier: verifier, redirect_uri: expected_callback)
      expect(grant.scope?(youtube_scope)).to be(false)
    end

    it "allow_without_refresh_token: 更新トークンが無いコード" do
      choose("allow_without_refresh_token")

      grant = fake.exchange_youtube_code(code: redirect_query.fetch("code"), code_verifier: verifier, redirect_uri: expected_callback)
      expect(grant.scope?(youtube_scope)).to be(true)
      expect(grant.refresh_token?).to be(false)
    end

    it "deny: コードを付けず、error=access_denied と state を付けて戻す（同意画面での拒否・取り消し）" do
      choose("deny")

      expect(response).to have_http_status(:found)
      expect(redirect_query).to eq("error" => "access_denied", "state" => "dummy-state-0001")
    end

    it "コードは、認可の要求の PKCE の challenge と戻り先に結びつく（別の検証子・別の戻り先では交換できない）" do
      choose("allow")
      code = redirect_query.fetch("code")

      expect { fake.exchange_youtube_code(code: code, code_verifier: "dummy-other-verifier-0123456789-abcdefghijklmnopqrstuvwxyz", redirect_uri: expected_callback) }
        .to raise_error(GoogleOidc::AuthenticationFailed) { |error| expect(error.reason).to eq(:pkce_mismatch) }
      expect { fake.exchange_youtube_code(code: code, code_verifier: verifier, redirect_uri: "https://evil.example.test/cb") }
        .to raise_error(GoogleOidc::AuthenticationFailed) { |error| expect(error.reason).to eq(:redirect_uri_mismatch) }
    end

    it "どの選択肢も、疑似の YouTube への注入は、その選択肢だけ（allow・allow_without_*・deny は、注入しない）" do
      %w[ allow allow_without_youtube allow_without_refresh_token deny ].each do |scenario|
        choose(scenario)

        expect(probe_outcome).to eq("connected"), "#{scenario} が注入した"
      end
    end

    it "allow_no_channel: 次の確認でチャンネルが無い（一度だけ）" do
      choose("allow_no_channel")

      expect(probe_outcome).to eq("no_channel")
      expect(probe_outcome).to eq("connected")
    end

    it "allow_live_not_enabled: 次の確認でライブ配信が有効でない（一度だけ）" do
      choose("allow_live_not_enabled")

      expect(probe_outcome).to eq("live_not_enabled")
      expect(probe_outcome).to eq("connected")
    end

    it "allow_unverifiable: 次の確認が一時的な失敗（一度だけ）" do
      choose("allow_unverifiable")

      expect(probe_outcome).to eq("Transient")
      expect(probe_outcome).to eq("connected")
    end

    it "注入しても、コードは全部を付与する種類（確認の側で不成立になる）" do
      choose("allow_no_channel")

      grant = fake.exchange_youtube_code(code: redirect_query.fetch("code"), code_verifier: verifier, redirect_uri: expected_callback)
      expect(grant.scope?(youtube_scope)).to be(true)
      expect(grant.refresh_token?).to be(true)
    end

    [ nil, "", "unknown", "ALLOW", "allow ", [ "allow" ], { "a" => "allow" } ].each do |scenario|
      it "選択肢の識別子が#{scenario.inspect}: 422 invalid_input（fields: scenario）。戻さない" do
        query = URI.encode_www_form(authorization.merge("scenario" => scenario).compact.reject { |_, value| value.is_a?(Enumerable) })
        suffix = scenario.is_a?(Array) ? "&scenario[]=allow" : (scenario.is_a?(Hash) ? "&scenario[a]=allow" : "")
        api_get "/api/dev/google/connect/choose?#{query}#{suffix}", headers: no_cookies

        expect(response).to have_http_status(422)
        expect(json_body.dig("error", "details", "fields")).to eq(%w[ scenario ])
        expect(response.headers["Location"]).to be_nil
      end
    end

    it "DB を変えない・Cookie を設定しない・測定イベントを記録しない" do
      expect { choose("allow") }.not_to change { [ User.count, YoutubeConnection.count, QuotaEntry.count, UsageEvent.count ] }
      expect(set_cookie_lines).to be_empty
    end

    it "ログに、認可コード・state を出さない" do
      output = capture_logs { choose("allow") }

      expect(output).not_to include(redirect_query.fetch("code"))
    end

    it "POST では呼べない（GET だけ）" do
      api_post "/api/dev/google/connect/choose", {}

      expect(response).to have_http_status(404)
    end
  end

  describe "環境の判定" do
    # 経路の表を、環境の判定を差し替えて引き直す。終わったら、本来の環境で引き直す
    after do
      allow(AppEnvironment).to receive(:current).and_call_original
      Rails.application.reload_routes!
    end

    def redraw_for(name)
      allow(AppEnvironment).to receive(:current).and_return(AppEnvironment.new(name))
      Rails.application.reload_routes!
    end

    def connect_routes
      Rails.application.routes.routes.select { |route| route.defaults[:controller] == "dev/google_connect" }
    end

    it "このテストの環境（test）には、経路がある（GET /api/dev/google/connect・/connect/choose）" do
      expect(connect_routes.map { |route| [ route.verb, route.path.spec.to_s.sub("(.:format)", ""), route.defaults[:action] ] })
        .to match_array([ [ "GET", "/api/dev/google/connect", "consent" ], [ "GET", "/api/dev/google/connect/choose", "choose" ] ])
    end

    it "疑似の認可 URL が指す経路（FakeGoogleOidc::CONNECT_AUTHORIZE_PATH）は、経路の表にある" do
      expect(Rails.application.routes.url_helpers.api_dev_google_connect_path).to eq(FakeGoogleOidc::CONNECT_AUTHORIZE_PATH)
    end

    %w[ development test ].each do |name|
      it "#{name}: 経路があり、画面が出る" do
        redraw_for(name)

        consent

        expect(connect_routes.size).to eq(2)
        expect(response).to have_http_status(:ok)
      end
    end

    it "production: 経路が無い。経路の表に、疑似の同意画面が一つも無い" do
      redraw_for("production")

      expect(connect_routes).to be_empty
      expect(Rails.application.routes.routes.map { |route| route.path.spec.to_s }).to all(satisfy { |path| !path.include?("/dev/") })
    end

    it "production: 要求は 404 not_found（存在しない /api の経路）。選択も、戻さない" do
      redraw_for("production")

      consent
      expect(response).to have_http_status(404)
      expect(json_body).to eq({ "error" => { "code" => "not_found", "details" => {} } })

      choose("allow")
      expect(response).to have_http_status(404)
      expect(response.headers["Location"]).to be_nil
    end

    it "production: 本番の YouTube 接続の経路（connect/start・connect/callback・recheck）は、ある" do
      redraw_for("production")

      actions = Rails.application.routes.routes.filter_map { |route| route.defaults[:action] if route.defaults[:controller] == "api/youtube" }

      expect(actions).to match_array(%w[ connect_start connect_callback recheck ])
    end

    it "使っている実装が疑似の Google でなければ（実物が選ばれているなら）、画面を出さない（404）" do
      real = instance_double(GoogleOidcClient)
      use_gateways(google_oidc: real, recaptcha_verifier: FakeRecaptchaVerifier.new)

      consent
      expect(response).to have_http_status(404)

      choose("allow")
      expect(response).to have_http_status(404)
    end

    it "使っている YouTube の窓口が疑似でなければ、失敗を注入する選択肢は 404（注入しない）。注入しない選択肢は通る" do
      services = YouTubeServices::Services.new(token_vault: instance_double(TokenVault), youtube_gateway: instance_double(YouTubeGateway))
      allow(YouTubeServices).to receive(:current).and_return(services)

      choose("allow_no_channel")
      expect(response).to have_http_status(404)
      expect(response.headers["Location"]).to be_nil

      choose("allow")
      expect(response).to have_http_status(:found)
    end
  end

  describe "共通の規約（#7 の基盤）" do
    it "X-BFF-Secret が無い要求は 403 forbidden（画面を出さない・戻さない）" do
      consent_url = "/api/dev/google/connect?#{URI.encode_www_form(authorization)}"
      api_get consent_url, headers: no_cookies.merge("X-BFF-Secret" => nil)

      expect(response).to have_http_status(403)
      expect(error_code).to eq("forbidden")
    end

    it "ログインの方針は、匿名と宣言している" do
      expect(Dev::GoogleConnectController.login_policy_for("consent")).to eq(:anonymous)
      expect(Dev::GoogleConnectController.login_policy_for("choose")).to eq(:anonymous)
    end
  end
end
