require "rails_helper"
require "support/external_http_support"
require "support/google_oidc_support"
require "support/log_capture"

# Google の実物 GoogleOidcClient の、YouTube 接続用のメソッド（issue #11。requirements.md 7.2・7.3・23.1。src/contracts/http-api.md 3 章）。
#   youtube_authorization_url  YouTube の認可 URL: スコープは youtube の 1 種のみ・response_type=code・PKCE（S256）・state・redirect_uri・
#                              access_type=offline・prompt=consent・login_hint。include_granted_scopes と nonce は付けない
#   exchange_youtube_code      認可コードを交換し、OAuthGrant（アクセストークン・更新トークン・付与されたスコープ）を返す。ID トークンは要らない
#   revoke                     受け取ったトークンを失効させる（GoogleTokenClient に任せる。接続が成立しなかったとき）
# 失敗は GoogleOidc::AuthenticationFailed（理由の符号だけ）。トークン・コード・秘密値を、ログ・例外に出さない。実際の Google は呼ばない（WebMock）。
RSpec.describe GoogleOidcClient, "YouTube 接続" do
  include GoogleOidcSupport

  let(:http) { ExternalHttp.new }
  let(:cache) { GoogleJwksCache.new(http: http, jwks_uri: google_config.fetch(:jwks_uri), ttl_seconds: 3600, min_refetch_seconds: 60) }
  let(:client) do
    described_class.new(client_id: client_id, client_secret: client_secret, http: http, endpoints: google_config, jwks_cache: cache)
  end
  let(:callback_uri) { "https://app.example.test/api/youtube/connect/callback" }
  let(:youtube_scope) { "https://www.googleapis.com/auth/youtube" }
  let(:refresh_token) { "1//dummy-refresh-token-must-not-appear" }
  let(:youtube_access_token) { "ya29.dummy-youtube-access-token-must-not-appear" }
  let(:token_url) { google_config.fetch(:token_endpoint) }
  let(:revoke_url) { google_config.fetch(:revoke_endpoint) }

  def exchange(code: auth_code, verifier: code_verifier, redirect: callback_uri)
    client.exchange_youtube_code(code: code, code_verifier: verifier, redirect_uri: redirect)
  end

  def token_body(**overrides)
    {
      "access_token" => youtube_access_token, "expires_in" => 3599, "refresh_token" => refresh_token,
      "scope" => youtube_scope, "token_type" => "Bearer"
    }.merge(overrides.transform_keys(&:to_s)).reject { |_key, value| value == :omit }
  end

  def stub_exchange(status: 200, body: token_body)
    stub_request(:post, token_url).to_return(status: status, body: body.is_a?(String) ? body : JSON.generate(body))
  end

  def expect_failure(reason, &block)
    expect(&block).to raise_error(GoogleOidc::AuthenticationFailed) { |error|
      expect(error.reason).to eq(reason), "期待: #{reason} 実際: #{error.reason}"
    }
  end

  describe "設定（config/external_services.yml）" do
    it "YouTube のスコープは、設定ファイルにある（コードに URL を直書きしない）。1 種のみ" do
      expect(google_config.fetch(:youtube_scope)).to eq(youtube_scope)
    end

    it "YouTube のスコープが設定に無ければ、構築できない（既定のスコープへ倒さない）" do
      expect { described_class.new(client_id: client_id, client_secret: client_secret, http: http, endpoints: google_config.except(:youtube_scope), jwks_cache: cache) }
        .to raise_error(ArgumentError, /youtube_scope/)
    end

    it "youtube_scope: 要求するスコープを返す（接続の判定が、付与されたスコープと比べる。スコープの値を、呼び出し側に持たせない）" do
      expect(client.youtube_scope).to eq(youtube_scope)
      expect(client.youtube_scope).to be_frozen
    end

    it "失効のエンドポイントが設定に無ければ、構築できない" do
      expect { described_class.new(client_id: client_id, client_secret: client_secret, http: http, endpoints: google_config.except(:revoke_endpoint), jwks_cache: cache) }
        .to raise_error(ArgumentError, /revoke_endpoint/)
    end
  end

  describe "#youtube_authorization_url" do
    let(:url) do
      client.youtube_authorization_url(
        state: "dummy-state-0001", code_challenge: s256_challenge(code_verifier), redirect_uri: callback_uri, login_hint: "dummy-google-sub-10001"
      )
    end
    let(:uri) { URI.parse(url) }
    let(:query) { Rack::Utils.parse_query(uri.query) }

    it "認可の画面は設定ファイルの URL（https://accounts.google.com/o/oauth2/v2/auth）" do
      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq(google_config.fetch(:authorization_endpoint))
    end

    it "パラメータは、この 10 個だけ（スコープ・response_type=code・PKCE の S256・state・redirect_uri・access_type=offline・prompt=consent・login_hint・client_id）" do
      expect(query).to eq(
        "client_id" => client_id,
        "redirect_uri" => callback_uri,
        "response_type" => "code",
        "scope" => youtube_scope,
        "state" => "dummy-state-0001",
        "code_challenge" => s256_challenge(code_verifier),
        "code_challenge_method" => "S256",
        "access_type" => "offline",
        "prompt" => "consent",
        "login_hint" => "dummy-google-sub-10001"
      )
    end

    it "スコープは youtube の 1 種のみ（openid・email・profile を含めない）" do
      expect(query.fetch("scope").split).to eq([ youtube_scope ])
    end

    it "オフライン（更新トークンを受け取る）で、接続のたびに同意画面を表示する（prompt=consent）" do
      expect(query).to include("access_type" => "offline", "prompt" => "consent")
    end

    it "include_granted_scopes を付けない（過去に付与したスコープを、混ぜない）。nonce も付けない（ID トークンを使わない）" do
      expect(query).not_to have_key("include_granted_scopes")
      expect(query).not_to have_key("nonce")
    end

    it "login_hint は、ログイン中の Google の識別子（sub）。接続先のチャンネルは、同意画面で利用者が選ぶ（チャンネルを指定するパラメータを付けない）" do
      expect(query.fetch("login_hint")).to eq("dummy-google-sub-10001")
      %w[ hd authuser channel channel_id ].each { |name| expect(query).not_to have_key(name) }
    end

    it "値は符号化される（記号を含む値が、そのまま往復する）" do
      tricky = "a+b/c=d&e f?g#h"
      value = client.youtube_authorization_url(state: tricky, code_challenge: "x-_y", redirect_uri: "#{callback_uri}?x=1&y=2", login_hint: tricky)
      parsed = Rack::Utils.parse_query(URI.parse(value).query)

      expect(parsed).to include("state" => tricky, "login_hint" => tricky, "redirect_uri" => "#{callback_uri}?x=1&y=2")
    end

    it "引数が空・文字列でないときは ArgumentError" do
      valid = { state: "s", code_challenge: "c", redirect_uri: callback_uri, login_hint: "h" }
      valid.each_key do |name|
        [ nil, "", "  ", 1 ].each do |bad|
          expect { client.youtube_authorization_url(**valid, name => bad) }.to raise_error(ArgumentError, /#{name}/)
        end
      end
    end

    it "ログイン用の認可 URL（authorization_url）は、これまでどおり（openid のみ。YouTube の権限を要求しない）" do
      login_url = client.authorization_url(state: "s", nonce: "n", code_challenge: "c", redirect_uri: redirect_uri)

      expect(Rack::Utils.parse_query(URI.parse(login_url).query).fetch("scope")).to eq("openid")
    end
  end

  describe "#exchange_youtube_code（成功）" do
    it "OAuthGrant を返す: アクセストークン・更新トークン・付与されたスコープ・有効秒数" do
      stub_exchange

      grant = exchange

      expect(grant).to be_a(OAuthGrant)
      expect(grant.access_token).to eq(youtube_access_token)
      expect(grant.refresh_token).to eq(refresh_token)
      expect(grant.scopes).to eq([ youtube_scope ])
      expect(grant.expires_in).to eq(3599)
    end

    it "トークンエンドポイントへ送るのは、code・client_id・client_secret・redirect_uri・grant_type・code_verifier（PKCE の検証子を送る）" do
      stub = stub_request(:post, token_url)
             .with(
               body: {
                 "code" => auth_code, "client_id" => client_id, "client_secret" => client_secret, "redirect_uri" => callback_uri,
                 "grant_type" => "authorization_code", "code_verifier" => code_verifier
               },
               headers: { "Content-Type" => "application/x-www-form-urlencoded" }
             )
             .to_return(status: 200, body: JSON.generate(token_body))

      exchange

      expect(stub).to have_been_requested.once
    end

    it "ID トークンは要らない（YouTube の接続は openid を要求しない）。あっても使わない" do
      stub_exchange(body: token_body("id_token" => "dummy.id.token"))

      expect(exchange.access_token).to eq(youtube_access_token)
    end

    it "更新トークンが無い応答（キーが無い・null）: refresh_token は nil（判定は呼び出し側。例外にしない）" do
      [ :omit, nil ].each do |absent|
        stub_exchange(body: token_body("refresh_token" => absent))

        grant = exchange

        expect(grant.refresh_token).to be_nil
        expect(grant.scope?(youtube_scope)).to be(true)
      end
    end

    it "YouTube の権限が付与されていない応答: スコープに youtube が含まれない（判定は呼び出し側。例外にしない）" do
      stub_exchange(body: token_body("scope" => "openid"))

      expect(exchange.scope?(youtube_scope)).to be(false)
    end

    it "スコープが空白区切りで複数: 配列にする" do
      stub_exchange(body: token_body("scope" => "openid #{youtube_scope}"))

      expect(exchange.scopes).to eq([ "openid", youtube_scope ])
    end

    it "scope が無い応答: スコープは空（付与を確認できないので、youtube を含むとしない）" do
      stub_exchange(body: token_body("scope" => :omit))

      expect(exchange.scopes).to eq([])
    end

    it "リダイレクトを追わない（302 は、交換の拒否）" do
      stub_request(:post, token_url).to_return(status: 302, headers: { "Location" => "https://evil.example.test/" })

      expect_failure(:token_exchange_rejected) { exchange }
      expect(a_request(:any, "https://evil.example.test/")).not_to have_been_made
    end

    it "クライアントのインスタンスに、トークンを保持しない" do
      stub_exchange

      exchange

      held = client.instance_variables.map { |name| client.instance_variable_get(name).to_s }.join
      expect(held).not_to include(youtube_access_token)
      expect(held).not_to include(refresh_token)
    end
  end

  describe "#exchange_youtube_code（失敗は GoogleOidc::AuthenticationFailed。理由の符号だけ）" do
    it "交換の拒否（400 invalid_grant。コードの再利用・期限切れ）: token_exchange_rejected" do
      stub_exchange(status: 400, body: { "error" => "invalid_grant", "error_description" => "dummy-description-must-not-appear" })

      expect_failure(:token_exchange_rejected) { exchange }
    end

    it "200 以外はすべて拒否（401・403・429・500）" do
      [ 401, 403, 429, 500, 503 ].each do |status|
        stub_exchange(status: status, body: "")

        expect_failure(:token_exchange_rejected) { exchange }
      end
    end

    it "通信の失敗（タイムアウト・接続拒否）: token_endpoint_unreachable" do
      stub_request(:post, token_url).to_timeout
      expect_failure(:token_endpoint_unreachable) { exchange }

      stub_request(:post, token_url).to_raise(Errno::ECONNREFUSED)
      expect_failure(:token_endpoint_unreachable) { exchange }
    end

    it "応答が JSON でない・オブジェクトでない: token_response_invalid" do
      stub_exchange(body: "not json at all")
      expect_failure(:token_response_invalid) { exchange }

      stub_exchange(body: "[1,2,3]")
      expect_failure(:token_response_invalid) { exchange }

      stub_exchange(body: "")
      expect_failure(:token_response_invalid) { exchange }
    end

    it "アクセストークンが無い・形が違う: token_response_invalid" do
      [ :omit, "", "has space", 123, nil, [ "a" ] ].each do |invalid|
        stub_exchange(body: token_body("access_token" => invalid))

        expect_failure(:token_response_invalid) { exchange }
      end
    end

    it "更新トークンの形が違う（文字列でない・空白を含む）: token_response_invalid（黙って更新トークン無しにしない）" do
      [ "", "has space", 123, [ "a" ] ].each do |invalid|
        stub_exchange(body: token_body("refresh_token" => invalid))

        expect_failure(:token_response_invalid) { exchange }
      end
    end

    it "scope が文字列でない: token_response_invalid" do
      [ 123, [ youtube_scope ], { "a" => 1 } ].each do |invalid|
        stub_exchange(body: token_body("scope" => invalid))

        expect_failure(:token_response_invalid) { exchange }
      end
    end

    it "有効秒数が無い・形が違う: token_response_invalid" do
      [ :omit, 0, -1, "3599", 3599.5, nil ].each do |invalid|
        stub_exchange(body: token_body("expires_in" => invalid))

        expect_failure(:token_response_invalid) { exchange }
      end
    end

    it "引数が空・文字列でないときは ArgumentError（呼び出しの誤り）" do
      valid = { code: auth_code, code_verifier: code_verifier, redirect_uri: callback_uri }
      valid.each_key do |name|
        [ nil, "", "  ", 1 ].each do |bad|
          expect { client.exchange_youtube_code(**valid, name => bad) }.to raise_error(ArgumentError, /#{name}/)
        end
      end
    end

    it "失敗のログと例外に、コード・検証子・秘密値・トークンを出さない。理由の符号は出る" do
      stub_exchange(status: 400, body: { "error" => "invalid_grant", "access_token" => youtube_access_token, "refresh_token" => refresh_token })

      error = nil
      output = capture_logs do
        exchange
      rescue GoogleOidc::AuthenticationFailed => caught
        error = caught
      end

      expect(error).to be_a(GoogleOidc::AuthenticationFailed)
      expect(output).to include("reason=token_exchange_rejected")
      [ auth_code, code_verifier, client_secret, youtube_access_token, refresh_token ].each do |secret|
        expect(output).not_to include(secret)
        expect(error.message).not_to include(secret)
      end
    end

    it "成功の応答のログにも、トークンを出さない" do
      stub_exchange

      output = capture_logs { exchange }

      [ auth_code, code_verifier, client_secret, youtube_access_token, refresh_token ].each { |secret| expect(output).not_to include(secret) }
    end
  end

  describe "#revoke（受け取ったトークンの失効。GoogleTokenClient に任せる）" do
    it "失効のエンドポイントへ、トークンをフォームで送る。200 は :revoked" do
      stub = stub_request(:post, revoke_url).with(body: { "token" => refresh_token }).to_return(status: 200, body: "")

      expect(client.revoke(token: refresh_token)).to eq(:revoked)
      expect(stub).to have_been_requested.once
    end

    it "すでに無効（400 invalid_token）は :already_invalid" do
      stub_request(:post, revoke_url).to_return(status: 400, body: JSON.generate("error" => "invalid_token"))

      expect(client.revoke(token: refresh_token)).to eq(:already_invalid)
    end

    it "一時的な失敗（503・タイムアウト）は YouTubeErrors::TokenTemporarilyUnavailable。想定外の応答は UnexpectedResponse" do
      stub_request(:post, revoke_url).to_return(status: 503, body: "")
      expect { client.revoke(token: refresh_token) }.to raise_error(YouTubeErrors::TokenTemporarilyUnavailable)

      stub_request(:post, revoke_url).to_timeout
      expect { client.revoke(token: refresh_token) }.to raise_error(YouTubeErrors::TokenTemporarilyUnavailable)

      stub_request(:post, revoke_url).to_return(status: 403, body: "")
      expect { client.revoke(token: refresh_token) }.to raise_error(YouTubeErrors::UnexpectedResponse)
    end

    it "トークンが空・文字列でないときは ArgumentError" do
      [ nil, "", "  ", 1 ].each { |bad| expect { client.revoke(token: bad) }.to raise_error(ArgumentError, /token/) }
    end

    it "ログに、トークンを出さない" do
      stub_request(:post, revoke_url).to_return(status: 503, body: "dummy-body-must-not-appear")

      output = capture_logs do
        expect { client.revoke(token: refresh_token) }.to raise_error(YouTubeErrors::TokenTemporarilyUnavailable)
      end

      expect(output).not_to include(refresh_token)
      expect(output).not_to include("must-not-appear")
    end
  end

  describe "ログイン（openid）の交換は、これまでどおり" do
    it "ID トークンが無い応答は、ログインの失敗（id_token_missing）。YouTube 接続の交換の変更が、ログインの検証を緩めない" do
      stub_request(:post, token_url).to_return(status: 200, body: JSON.generate(token_body))

      expect_failure(:id_token_missing) do
        client.authenticate(code: auth_code, code_verifier: code_verifier, nonce: nonce_value, redirect_uri: redirect_uri, now: Time.utc(2026, 10, 8, 3, 0, 0))
      end
    end
  end
end
