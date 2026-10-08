require "rails_helper"
require "support/api_helpers"
require "support/external_http_support"
require "support/auth_flow_helpers"
require "support/youtube_connect_support"

# YouTube 接続の全体を、実物の Google（GoogleOidcClient）と実物の YouTube の窓口（YouTubeGateway）で動かす（本番の組み合わせ。WebMock。issue #11）。
# 実際の HTTP の要求の形（トークンの交換・YouTube API の呼び出し・トークンの失効）と、次を確かめる。
#   - トークンの交換は、PKCE の検証子と client_secret を送る。確認（channels・liveBroadcasts の一覧取得）は、交換で得たアクセストークンで呼ぶ
#   - 不成立のとき、受け取ったトークンの失効は、Google のトークンの失効の口へ送る（YouTube API ではない。台帳に記帳しない）。既存の接続があれば、失効させない
#   - 認可コードの再利用（戻る操作での再送）は、Google が拒否する -> unverifiable
# 応答の実物は未確認（requirements.md 3 章・U5。最初の実機で採取して合わせる）。値は明らかなダミー。
RSpec.describe "YouTube 接続（実物の Google・実物の YouTube の窓口。WebMock）", type: :request do
  include ApiHelpers
  include AuthFlowHelpers
  include YouTubeConnectSupport
  include ActiveSupport::Testing::TimeHelpers
  include_context "API の環境"
  include_context "YouTube 接続の環境"

  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:clock) { { now: now } }
  let!(:limiter) { fresh_rate_limiter(clock) }
  let(:origin) { ApiHelpers::PUBLIC_ORIGIN }
  let(:user) { create(:user, google_sub: "dummy-google-sub-10001") }
  let(:login) { sign_in(user, now: now) }
  let(:http) { ExternalHttp.new }
  let(:google_config) { ExternalServices.config.fetch(:google_oidc) }
  let(:api_base) { ExternalServices.config.fetch(:youtube).fetch(:api_base) }
  let(:client_id) { "dummy-client-id-0001.apps.googleusercontent.com" }
  let(:client_secret) { "dummy-google-client-secret-0001" }
  let(:real_oidc) do
    GoogleOidcClient.new(
      client_id: client_id, client_secret: client_secret, http: http, endpoints: google_config,
      jwks_cache: GoogleJwksCache.new(http: http, jwks_uri: google_config.fetch(:jwks_uri), ttl_seconds: 3600, min_refetch_seconds: 60)
    )
  end
  let(:token_client) { FakeGoogleTokenClient.new(environment: AppEnvironment.new("test")) }
  let(:vault) { TokenVault.new(key: connect_key, token_client: token_client, cache: TokenVault::AccessTokenCache.new) }
  let(:real_gateway) do
    YouTubeGateway.new(
      http: ExternalHttp.new, token_vault: vault, api_base: api_base, stream_title: "Browser Live",
      environment: AppEnvironment.new("production"), clock: SystemClock.method(:now)
    )
  end
  let(:access_token) { "ya29.dummy-live-access-token-must-not-appear" }
  let(:refresh_token) { "1//dummy-live-refresh-token-must-not-appear" }
  let(:auth_code) { "dummy-live-authorization-code-0001" }
  let(:token_url) { google_config.fetch(:token_endpoint) }
  let(:revoke_url) { google_config.fetch(:revoke_endpoint) }
  let(:youtube_scope) { google_config.fetch(:youtube_scope) }

  before do
    travel_to(now)
    use_gateways(google_oidc: real_oidc, recaptcha_verifier: FakeRecaptchaVerifier.new)
    allow(YouTubeServices).to receive(:current).and_return(YouTubeServices::Services.new(token_vault: vault, youtube_gateway: real_gateway))
  end

  after { travel_back }

  # --- WebMock の応答 ---

  def json_reply(body, status: 200)
    { status: status, body: JSON.generate(body), headers: { "Content-Type" => "application/json; charset=UTF-8" } }
  end

  def token_body(**overrides)
    { "access_token" => access_token, "expires_in" => 3599, "refresh_token" => refresh_token, "scope" => youtube_scope, "token_type" => "Bearer" }
      .merge(overrides.transform_keys(&:to_s)).reject { |_key, value| value == :omit }
  end

  def youtube_error(status, reason)
    json_reply({ "error" => { "code" => status, "message" => "dummy-error-message-must-not-appear", "errors" => [ { "domain" => "youtube", "reason" => reason } ] } }, status: status)
  end

  # トークンの交換: PKCE の検証子が code_challenge と合い、client_secret・戻り先が正しい要求にだけ、応答する
  def stub_exchange(challenge, reply: json_reply(token_body))
    stub_request(:post, token_url).with do |request|
      form = URI.decode_www_form(request.body).to_h
      s256_challenge(form.fetch("code_verifier")) == challenge && form["code"] == auth_code && form["redirect_uri"] == "#{origin}/api/youtube/connect/callback" &&
        form["client_secret"] == client_secret && form["client_id"] == client_id && form["grant_type"] == "authorization_code"
    end.to_return(reply)
  end

  def stub_channels(items: [ { "kind" => "youtube#channel", "id" => "dummy-channel-id", "snippet" => { "title" => "Dummy Live Channel" } } ], bearer: access_token)
    stub_request(:get, "#{api_base}/channels").with(query: hash_including("part" => "snippet", "mine" => "true"), headers: { "Authorization" => "Bearer #{bearer}" })
                                              .to_return(json_reply({ "kind" => "youtube#channelListResponse", "items" => items }))
  end

  def stub_broadcasts(reply: json_reply({ "kind" => "youtube#liveBroadcastListResponse", "items" => [] }), bearer: access_token)
    stub_request(:get, "#{api_base}/liveBroadcasts").with(query: hash_including("part" => "id", "mine" => "true", "maxResults" => "1"), headers: { "Authorization" => "Bearer #{bearer}" })
                                                    .to_return(reply)
  end

  def stub_revoke(status: 200)
    stub_request(:post, revoke_url).to_return(status: status, body: "")
  end

  # 認可の開始。Google の同意画面は、ブラウザの外（このスペックの対象外）。認可 URL のクエリと、bl_oauth の値を控える
  def start_live_flow
    api_post "/api/youtube/connect/start", { recaptcha_token: "dev-pass" }, signed_in: login
    expect(response).to have_http_status(:ok)
    @authorization_query = Rack::Utils.parse_query(URI.parse(json_body.fetch("authorization_url")).query)
    @challenge = @authorization_query.fetch("code_challenge")
    @state = @authorization_query.fetch("state")
    @oauth_cookie = cookie_value(OAuthStateCookie::NAME)
  end

  # 開始 -> （Google の同意画面）-> コールバック。ブロックは、開始のあと（PKCE の challenge が分かったあと）に、WebMock の応答を用意する。
  # コールバックの応答の状態にしておく
  def run_live_flow(state_override: nil)
    start_live_flow
    yield if block_given?
    send_callback(state: state_override || @state)
  end

  def send_callback(code: auth_code, state: @state, error: nil)
    params = { code: code, state: state, error: error }.compact
    api_get "/api/youtube/connect/callback?#{URI.encode_www_form(params)}", headers: { "Cookie" => cookie_header_of(@oauth_cookie, login.token) }
  end

  def expect_redirect(result)
    expect(response).to have_http_status(:found)
    expect(response.headers["Location"]).to eq("#{origin}/account?connect=#{result}")
  end

  def common_entries
    QuotaEntry.where(bucket: "common").map { |entry| [ entry.method, entry.units ] }
  end

  describe "開始: 実物の Google の認可 URL" do
    it "https://accounts.google.com の認可の画面。client_id つき・スコープは youtube の 1 種・offline・consent・login_hint（sub）・PKCE の S256" do
      start_live_flow

      expect(json_body.fetch("authorization_url")).to start_with("https://accounts.google.com/o/oauth2/v2/auth?")
      expect(@authorization_query).to include(
        "client_id" => client_id, "scope" => youtube_scope, "access_type" => "offline", "prompt" => "consent",
        "login_hint" => "dummy-google-sub-10001", "code_challenge_method" => "S256", "response_type" => "code",
        "redirect_uri" => "#{origin}/api/youtube/connect/callback"
      )
      expect(@authorization_query).not_to have_key("include_granted_scopes")
      expect(@authorization_query).not_to have_key("nonce")
    end
  end

  describe "成立（connected）" do
    it "トークンを交換し（検証子・client_secret を送る）、交換で得たアクセストークンで、チャンネルとライブの有効を確認して、接続を保存する" do
      exchange = nil
      channels = nil
      broadcasts = nil
      run_live_flow do
        exchange = stub_exchange(@challenge)
        channels = stub_channels
        broadcasts = stub_broadcasts
      end

      expect_redirect("connected")
      expect(exchange).to have_been_requested.once
      expect(channels).to have_been_requested.once
      expect(broadcasts).to have_been_requested.once
      expect(a_request(:post, revoke_url)).not_to have_been_made
      expect(YoutubeConnection.owned_by(user).sole).to have_attributes(state: "connected", connected_at: now, last_verified_at: now)
    end

    it "確認の呼び出しは、台帳の共通枠に記帳される（channels.list 1・liveBroadcasts.list 1）" do
      run_live_flow do
        stub_exchange(@challenge)
        stub_channels
        stub_broadcasts
      end

      expect(common_entries).to contain_exactly([ "channels.list", 1 ], [ "liveBroadcasts.list", 1 ])
    end

    it "保存されるのは暗号化した更新トークンだけ。アクセストークン・平文の更新トークン・チャンネル名は、DB のどの表にも無い" do
      run_live_flow do
        stub_exchange(@challenge)
        stub_channels
        stub_broadcasts
      end

      dump = database_dump
      [ access_token, refresh_token, "Dummy Live Channel", auth_code ].each { |secret| expect(dump).not_to include(secret) }
      expect(YoutubeConnection.owned_by(user).sole.refresh_token_ciphertext).to be_present
    end

    it "ログに、トークン・認可コード・チャンネル名が出ない" do
      output = capture_logs do
        run_live_flow do
          stub_exchange(@challenge)
          stub_channels
          stub_broadcasts
        end
      end

      [ access_token, refresh_token, auth_code, "Dummy Live Channel", @state, client_secret ].each do |secret|
        expect(output).not_to include(secret), "ログに機密が出ている: #{secret[0, 12]}"
      end
      expect(output).to include("[youtube_connect] completed user_id=#{user.id} result=connected")
    end

    it "保存した更新トークンで、あとから再確認できる（保存したトークンが、アクセストークンの取得に使える）" do
      run_live_flow do
        stub_exchange(@challenge)
        stub_channels
        stub_broadcasts
      end
      recheck_access = "fake-access-token-1" # 疑似のトークンエンドポイント（vault の token_client）が返す
      stub_channels(bearer: recheck_access)
      stub_broadcasts(bearer: recheck_access)

      api_post "/api/youtube/recheck", nil, signed_in: login

      expect(response).to have_http_status(:ok)
      expect(json_body.dig("youtube", "state")).to eq("connected")
    end
  end

  describe "成立（live_not_enabled）" do
    it "配信の一覧取得が liveStreamingNotEnabled（403）を返す: live_not_enabled で成立する" do
      run_live_flow do
        stub_exchange(@challenge)
        stub_channels
        stub_broadcasts(reply: youtube_error(403, "liveStreamingNotEnabled"))
      end

      expect_redirect("live_not_enabled")
      expect(YoutubeConnection.owned_by(user).sole.state).to eq("live_not_enabled")
      expect(a_request(:post, revoke_url)).not_to have_been_made
    end

    it "livePermissionBlocked（制限中）も、live_not_enabled で成立する" do
      run_live_flow do
        stub_exchange(@challenge)
        stub_channels
        stub_broadcasts(reply: youtube_error(403, "livePermissionBlocked"))
      end

      expect_redirect("live_not_enabled")
    end
  end

  describe "不成立: 受け取ったトークンを破棄し、既存の接続が無ければ、Google のトークンの失効の口へ送る" do
    it "チャンネルが無い（空の一覧）: no_channel。更新トークンの失効を 1 回（トークンをフォームで送る）。接続を保存しない" do
      revoke = nil
      run_live_flow do
        stub_exchange(@challenge)
        stub_channels(items: [])
        revoke = stub_request(:post, revoke_url).with(body: { "token" => refresh_token }).to_return(status: 200, body: "")
      end

      expect_redirect("no_channel")
      expect(revoke).to have_been_requested.once
      expect(YoutubeConnection.count).to eq(0)
    end

    it "失効の呼び出しは、Google のトークンの失効の口（oauth2.googleapis.com）。YouTube API へは送らない・台帳に記帳しない" do
      run_live_flow do
        stub_exchange(@challenge)
        stub_channels(items: [])
        stub_revoke
      end

      expect(a_request(:post, revoke_url)).to have_been_made.once
      expect(a_request(:any, %r{\Ahttps://www\.googleapis\.com/youtube/v3/}).with { |request| request.method == :post }).not_to have_been_made
      expect(common_entries).to contain_exactly([ "channels.list", 1 ]) # チャンネルの確認の 1 ユニットだけ。失効は記帳されない
    end

    it "youtubeSignupRequired（チャンネルの作成が要る）も no_channel" do
      run_live_flow do
        stub_exchange(@challenge)
        stub_request(:get, "#{api_base}/channels").with(query: hash_including("mine" => "true")).to_return(youtube_error(401, "youtubeSignupRequired"))
        stub_revoke
      end

      expect_redirect("no_channel")
    end

    it "更新トークンが無い応答: no_refresh_token。更新トークンが無いので、アクセストークンを失効させる" do
      revoke = nil
      run_live_flow do
        stub_exchange(@challenge, reply: json_reply(token_body("refresh_token" => :omit)))
        revoke = stub_request(:post, revoke_url).with(body: { "token" => access_token }).to_return(status: 200, body: "")
      end

      expect_redirect("no_refresh_token")
      expect(revoke).to have_been_requested.once
      expect(a_request(:get, %r{\Ahttps://www\.googleapis\.com/youtube/v3/})).not_to have_been_made
      expect(YoutubeConnection.count).to eq(0)
    end

    it "youtube のスコープが付与されていない応答: scope_denied。YouTube を呼ばず、更新トークンを失効させる" do
      revoke = nil
      run_live_flow do
        stub_exchange(@challenge, reply: json_reply(token_body("scope" => "openid")))
        revoke = stub_request(:post, revoke_url).with(body: { "token" => refresh_token }).to_return(status: 200, body: "")
      end

      expect_redirect("scope_denied")
      expect(revoke).to have_been_requested.once
      expect(a_request(:get, %r{\Ahttps://www\.googleapis\.com/youtube/v3/})).not_to have_been_made
    end

    it "YouTube が一時的に失敗（503）: unverifiable。更新トークンを失効させる。接続を保存しない" do
      run_live_flow do
        stub_exchange(@challenge)
        stub_request(:get, "#{api_base}/channels").with(query: hash_including("mine" => "true")).to_return(youtube_error(503, "backendError"))
        stub_revoke
      end

      expect_redirect("unverifiable")
      expect(a_request(:post, revoke_url)).to have_been_made.once
      expect(YoutubeConnection.count).to eq(0)
    end

    it "YouTube がタイムアウト: unverifiable" do
      run_live_flow do
        stub_exchange(@challenge)
        stub_request(:get, "#{api_base}/channels").with(query: hash_including("mine" => "true")).to_timeout
        stub_revoke
      end

      expect_redirect("unverifiable")
    end

    it "YouTube が割り当て超過（quotaExceeded）を返す: unverifiable。台帳に超過の印を付ける" do
      run_live_flow do
        stub_exchange(@challenge)
        stub_request(:get, "#{api_base}/channels").with(query: hash_including("mine" => "true")).to_return(youtube_error(403, "quotaExceeded"))
        stub_revoke
      end

      expect_redirect("unverifiable")
      expect(QuotaDay.find(UsageCalendar.quota_date(now))).to have_attributes(exhausted: true)
    end

    it "権限が不足している（insufficientPermissions）: scope_denied" do
      run_live_flow do
        stub_exchange(@challenge)
        stub_request(:get, "#{api_base}/channels").with(query: hash_including("mine" => "true")).to_return(youtube_error(403, "insufficientPermissions"))
        stub_revoke
      end

      expect_redirect("scope_denied")
    end

    it "既存の接続があれば、失効させない（同じ付与を共有するため）。既存の接続は変更しない" do
      existing = create(:youtube_connection, :with_stream, user: user, state: "connected")
      before = existing.reload.attributes
      run_live_flow do
        stub_exchange(@challenge)
        stub_channels(items: [])
      end

      expect_redirect("no_channel")
      expect(a_request(:post, revoke_url)).not_to have_been_made
      expect(existing.reload.attributes).to eq(before)
    end

    it "Google のトークンの失効が失敗（503）しても、結果は変わらない（no_channel）。失敗を記録する" do
      output = capture_logs do
        run_live_flow do
          stub_exchange(@challenge)
          stub_channels(items: [])
          stub_revoke(status: 503)
        end
      end

      expect_redirect("no_channel")
      expect(output).to include("[youtube_connect] revoke failed user_id=#{user.id}")
      expect(output).not_to include(refresh_token)
    end

    it "不成立のときも、ログとデータベースに、トークンを出さない" do
      output = capture_logs do
        run_live_flow do
          stub_exchange(@challenge)
          stub_channels(items: [])
          stub_revoke
        end
      end

      [ access_token, refresh_token, auth_code, @state, @oauth_cookie ].each { |secret| expect(output).not_to include(secret) }
      expect(database_dump).not_to include(refresh_token)
    end
  end

  describe "コードの交換の失敗: トークンを受け取っていないので、YouTube も失効の口も呼ばない" do
    it "Google が交換を拒否（400 invalid_grant）: unverifiable" do
      run_live_flow do
        stub_request(:post, token_url).to_return(json_reply({ "error" => "invalid_grant", "error_description" => "dummy-description-must-not-appear" }, status: 400))
      end

      expect_redirect("unverifiable")
      expect(a_request(:get, %r{\Ahttps://www\.googleapis\.com/youtube/v3/})).not_to have_been_made
      expect(a_request(:post, revoke_url)).not_to have_been_made
    end

    it "Google に到達できない（タイムアウト）: unverifiable" do
      run_live_flow { stub_request(:post, token_url).to_timeout }

      expect_redirect("unverifiable")
    end

    it "応答が壊れている: unverifiable" do
      run_live_flow { stub_request(:post, token_url).to_return(status: 200, body: "not json") }

      expect_redirect("unverifiable")
    end

    it "認可コードの再利用（戻る操作での再送）: 1 回目は成立し、2 回目は Google が拒否 -> unverifiable。接続は 1 件のまま・状態は変わらない" do
      run_live_flow do
        stub_exchange(@challenge)
        stub_channels
        stub_broadcasts
      end
      expect_redirect("connected")
      stub_request(:post, token_url).to_return(json_reply({ "error" => "invalid_grant" }, status: 400))

      send_callback

      expect_redirect("unverifiable")
      expect(YoutubeConnection.owned_by(user).count).to eq(1)
      expect(YoutubeConnection.owned_by(user).sole.state).to eq("connected")
    end

    it "state の不一致: コードを交換しない（トークンエンドポイントを呼ばない）" do
      run_live_flow(state_override: "dummy-other-state")

      expect_redirect("unverifiable")
      expect(a_request(:post, token_url)).not_to have_been_made
    end

    it "error=access_denied（同意画面での拒否）: コードを交換しない。scope_denied" do
      start_live_flow
      send_callback(code: nil, error: "access_denied")

      expect_redirect("scope_denied")
      expect(a_request(:post, token_url)).not_to have_been_made
    end
  end
end
