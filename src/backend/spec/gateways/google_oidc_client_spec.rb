require "rails_helper"
require "support/external_http_support"
require "support/google_oidc_support"
require "support/log_capture"

# Google ログイン（OpenID Connect の認可コードフロー + PKCE）の実物 GoogleOidcClient（issue #8。requirements.md 7.1・28.1）。
#   認可 URL: スコープは openid のみ・response_type=code・PKCE（S256）・state・nonce・redirect_uri
#   認可コードの交換: client_secret と検証子を送る（ExternalHttp。リダイレクトを追わない）
#   ID トークンの検証: 署名（Google の公開鍵。JWKS をキャッシュし、kid で選ぶ。jwt gem）・iss・aud・exp・iat・nonce・sub
# 失敗は GoogleOidc::AuthenticationFailed（理由の符号だけ。トークン・コード・sub を含めない）。実際の Google は呼ばない（WebMock）。
RSpec.describe GoogleOidcClient do
  include GoogleOidcSupport

  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:http) { ExternalHttp.new }
  let(:cache) do
    GoogleJwksCache.new(http: http, jwks_uri: google_config.fetch(:jwks_uri), ttl_seconds: 3600, min_refetch_seconds: 60)
  end
  let(:client) do
    described_class.new(client_id: client_id, client_secret: client_secret, http: http, endpoints: google_config, jwks_cache: cache)
  end
  let(:claims) { id_token_claims(now: now) }

  def authenticate(code: auth_code, verifier: code_verifier, nonce: nonce_value, redirect: redirect_uri, at: now)
    client.authenticate(code: code, code_verifier: verifier, nonce: nonce, redirect_uri: redirect, now: at)
  end

  # 交換の応答に、署名した ID トークンを返させ、JWKS も返させる
  def arrange_exchange(token_claims = claims, **mint_options)
    stub_jwks
    stub_token_endpoint(id_token: mint_id_token(token_claims, **mint_options))
  end

  def expect_failure(reason, &block)
    expect(&block).to raise_error(GoogleOidc::AuthenticationFailed) { |error|
      expect(error.reason).to eq(reason), "期待: #{reason} 実際: #{error.reason}"
    }
  end

  describe "#authorization_url" do
    let(:url) do
      client.authorization_url(state: "dummy-state-0001", nonce: nonce_value, code_challenge: s256_challenge(code_verifier), redirect_uri: redirect_uri)
    end
    let(:uri) { URI.parse(url) }
    let(:query) { Rack::Utils.parse_query(uri.query) }

    it "認可の画面は設定ファイルの URL（https://accounts.google.com/o/oauth2/v2/auth）" do
      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq(google_config.fetch(:authorization_endpoint))
      expect(uri.scheme).to eq("https")
      expect(uri.host).to eq("accounts.google.com")
    end

    it "パラメータは、この 8 つだけ（スコープは openid のみ・response_type=code・PKCE の S256・state・nonce・redirect_uri）" do
      expect(query).to eq(
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => "openid",
        "state" => "dummy-state-0001",
        "nonce" => nonce_value,
        "code_challenge" => s256_challenge(code_verifier),
        "code_challenge_method" => "S256"
      )
    end

    it "メールアドレス・プロフィールを要求しない（scope に email・profile を含めない）" do
      scopes = query.fetch("scope").split

      expect(scopes).to eq([ "openid" ])
    end

    it "ログイン中の他のパラメータ（access_type・prompt・login_hint・include_granted_scopes）を付けない" do
      %w[ access_type prompt login_hint include_granted_scopes hd ].each { |name| expect(query).not_to have_key(name) }
    end

    it "値は符号化される（記号を含む値が、そのまま往復する）" do
      tricky = "a+b/c=d&e f?g#h"
      value = client.authorization_url(state: tricky, nonce: tricky, code_challenge: "x-_y", redirect_uri: "https://app.example.test/api/auth/callback?x=1&y=2")
      parsed = Rack::Utils.parse_query(URI.parse(value).query)

      expect(parsed.fetch("state")).to eq(tricky)
      expect(parsed.fetch("nonce")).to eq(tricky)
      expect(parsed.fetch("redirect_uri")).to eq("https://app.example.test/api/auth/callback?x=1&y=2")
    end

    it "引数が空・文字列でないときは ArgumentError" do
      valid = { state: "s", nonce: "n", code_challenge: "c", redirect_uri: redirect_uri }
      valid.each_key do |name|
        [ nil, "", "  ", 1 ].each do |bad|
          expect { client.authorization_url(**valid, name => bad) }.to raise_error(ArgumentError, /#{name}/)
        end
      end
    end
  end

  describe "#authenticate（成功）" do
    it "認可コードを交換し、ID トークンを検証して、sub を持つ Identity を返す" do
      arrange_exchange

      identity = authenticate

      expect(identity).to be_a(GoogleOidc::Identity)
      expect(identity.sub).to eq(google_sub)
    end

    it "トークンエンドポイントへ送るのは、code・client_id・client_secret・redirect_uri・grant_type・code_verifier（検証子と秘密値を送る）" do
      stub_jwks
      stub = stub_request(:post, google_config.fetch(:token_endpoint))
             .with(
               body: {
                 "code" => auth_code, "client_id" => client_id, "client_secret" => client_secret, "redirect_uri" => redirect_uri,
                 "grant_type" => "authorization_code", "code_verifier" => code_verifier
               },
               headers: { "Content-Type" => "application/x-www-form-urlencoded" }
             )
             .to_return(status: 200, body: token_response_body(mint_id_token(claims)))

      authenticate

      expect(stub).to have_been_requested.once
    end

    it "メール・氏名などの claims が ID トークンにあっても、Identity は sub だけ（メール・氏名・プロフィールを持ち出さない）" do
      arrange_exchange(claims.merge("email" => "dummy@example.test", "name" => "dummy-name", "picture" => "https://example.test/p.png"))

      identity = authenticate

      expect(GoogleOidc::Identity.members).to eq([ :sub ])
      expect(identity.to_h).to eq({ sub: google_sub })
    end

    it "アクセストークンを返さない・保持しない（Identity にも、クライアントのインスタンスにも無い）" do
      arrange_exchange

      identity = authenticate

      expect(identity.inspect).not_to include(access_token)
      expect(client.instance_variables.map { |name| client.instance_variable_get(name).to_s }.join).not_to include(access_token)
    end

    it "公開鍵（JWKS）はキャッシュされる（2 回目の認証で取得しない）" do
      arrange_exchange
      authenticate
      authenticate(code: "dummy-authorization-code-0002")

      expect(a_request(:get, google_config.fetch(:jwks_uri))).to have_been_made.once
      expect(a_request(:post, google_config.fetch(:token_endpoint))).to have_been_made.twice
    end

    it "iss は 2 つの形（https://accounts.google.com・accounts.google.com）のどちらでもよい" do
      [ "https://accounts.google.com", "accounts.google.com" ].each do |iss|
        arrange_exchange(claims.merge("iss" => iss))

        expect(authenticate.sub).to eq(google_sub), iss
      end
    end

    it "aud が配列でも、クライアント ID を含み、azp がクライアント ID なら通る" do
      arrange_exchange(claims.merge("aud" => [ client_id, "dummy-other-client" ], "azp" => client_id))

      expect(authenticate.sub).to eq(google_sub)
    end

    it "exp は now の 1 秒後なら通る（境界）。iat は now の 60 秒後まで通る（時計のずれ）" do
      arrange_exchange(claims.merge("exp" => now.to_i + 1, "iat" => now.to_i + 60))

      expect(authenticate.sub).to eq(google_sub)
    end

    it "sub は ASCII の表示できる文字 1〜255 文字" do
      [ "1", "a" * 255, "109876543210987654321" ].each do |sub|
        arrange_exchange(claims.merge("sub" => sub))

        expect(authenticate.sub).to eq(sub)
      end
    end
  end

  describe "#authenticate（ID トークンの検証の失敗）" do
    {
      "署名が別の鍵（kid は同じ）" => [ ->(c, test) { test.mint_id_token(c, key: test.other_key) }, :signature_invalid ],
      "署名の 1 文字を書き換えた" => [ ->(c, test) { test.mint_id_token(c).then { |t| t[0..-3] + (t[-2] == "A" ? "B" : "A") + t[-1] } }, :signature_invalid ],
      "本文を書き換えた（署名はそのまま）" => [
        lambda { |c, test|
          header, _payload, signature = test.mint_id_token(c).split(".")
          forged = Base64.urlsafe_encode64(JSON.generate(c.merge("sub" => "dummy-forged-sub")), padding: false)
          [ header, forged, signature ].join(".")
        },
        :signature_invalid
      ],
      "alg が none（署名なし）" => [ ->(c, test) { test.mint_id_token(c, key: nil, algorithm: "none") }, :algorithm_invalid ],
      "alg が HS256（公開鍵を HMAC の秘密値にした鍵の取り違え）" => [
        ->(c, test) { test.mint_id_token(c, key: test.signing_key.public_key.to_pem, algorithm: "HS256") },
        :algorithm_invalid
      ],
      "alg が RS384（許可する alg は RS256 だけ）" => [ ->(c, test) { test.mint_id_token(c, algorithm: "RS384") }, :algorithm_invalid ],
      "kid が JWKS に無い" => [ ->(c, test) { test.mint_id_token(c, key: test.other_key, kid: "dummy-unknown-kid") }, :signing_key_unknown ],
      "kid が無い" => [ ->(c, test) { test.mint_id_token(c, kid: nil) }, :signing_key_unknown ],
      "JWT として読めない" => [ ->(_c, _test) { "not-a-jwt" }, :id_token_malformed ],
      "区間が 3 つだが中身が壊れている" => [ ->(_c, _test) { "a.b.c" }, :id_token_malformed ]
    }.each do |label, (build, reason)|
      it "#{label}: #{reason}" do
        stub_jwks
        stub_token_endpoint(id_token: build.call(claims, self))

        expect_failure(reason) { authenticate }
      end
    end

    {
      "iss が違う" => [ { "iss" => "https://evil.example.test" }, :issuer_invalid ],
      "iss が似ている（末尾に文字を足した）" => [ { "iss" => "https://accounts.google.com.evil.example" }, :issuer_invalid ],
      "iss が無い" => [ { "iss" => :omit }, :issuer_invalid ],
      "aud が違う" => [ { "aud" => "dummy-other-client-id" }, :audience_invalid ],
      "aud が無い" => [ { "aud" => :omit }, :audience_invalid ],
      "aud が配列でクライアント ID を含まない" => [ { "aud" => [ "dummy-a", "dummy-b" ] }, :audience_invalid ],
      "aud が配列で複数、azp が無い" => [ { "aud" => [ GoogleOidcSupport::CLIENT_ID, "dummy-other" ], "azp" => :omit }, :audience_invalid ],
      "aud が配列で複数、azp が別のクライアント" => [ { "aud" => [ GoogleOidcSupport::CLIENT_ID, "dummy-other" ], "azp" => "dummy-other" }, :audience_invalid ],
      "exp が過去（期限切れ）" => [ lambda { |n| { "exp" => n.to_i - 1 } }, :expired ],
      "exp がちょうど now（期限の瞬間から無効）" => [ lambda { |n| { "exp" => n.to_i } }, :expired ],
      "exp が 1 時間前" => [ lambda { |n| { "exp" => n.to_i - 3600 } }, :expired ],
      "exp が無い" => [ { "exp" => :omit }, :claim_missing ],
      "exp が数値でない" => [ { "exp" => "tomorrow" }, :id_token_invalid ],
      "iat が now の 61 秒先（時計のずれを超える）" => [ lambda { |n| { "iat" => n.to_i + 61 } }, :issued_in_future ],
      "iat が無い" => [ { "iat" => :omit }, :claim_missing ],
      "iat が数値でない" => [ { "iat" => "yesterday" }, :id_token_invalid ],
      "nonce が違う（再送・取り違え）" => [ { "nonce" => "dummy-other-nonce" }, :nonce_mismatch ],
      "nonce が無い" => [ { "nonce" => :omit }, :claim_missing ],
      "nonce が文字列でない" => [ { "nonce" => 123 }, :nonce_mismatch ],
      "sub が無い" => [ { "sub" => :omit }, :claim_missing ],
      "sub が空" => [ { "sub" => "" }, :subject_invalid ],
      "sub が 256 文字" => [ { "sub" => "a" * 256 }, :subject_invalid ],
      "sub が数値" => [ { "sub" => 12_345 }, :subject_invalid ],
      "sub が配列" => [ { "sub" => [ "a" ] }, :subject_invalid ],
      "sub に空白を含む" => [ { "sub" => "dummy sub" }, :subject_invalid ],
      "sub に改行を含む" => [ { "sub" => "dummy\nsub" }, :subject_invalid ],
      "sub に日本語を含む" => [ { "sub" => "dummy-#{[ 0x3042 ].pack('U')}" }, :subject_invalid ]
    }.each do |label, (override, reason)|
      it "#{label}: #{reason}" do
        override = override.call(now) if override.respond_to?(:call)
        arrange_exchange(claims.merge(override.transform_keys(&:to_s)).reject { |_key, value| value == :omit })

        expect_failure(reason) { authenticate }
      end
    end

    it "検証の失敗では、sub を返さない（Identity を作らない）" do
      arrange_exchange(claims.merge("nonce" => "dummy-other-nonce"))

      expect { authenticate }.to raise_error(GoogleOidc::AuthenticationFailed)
    end

    it "判定の時刻は、引数の now（実時計を読まない）" do
      arrange_exchange

      expect(authenticate(at: now).sub).to eq(google_sub)
      expect_failure(:expired) { authenticate(at: now + 3601) }
    end
  end

  describe "#authenticate（認可コードの交換の失敗）" do
    [
      [ 400, "{\"error\":\"invalid_grant\"}" ],
      [ 401, "{\"error\":\"invalid_client\"}" ],
      [ 403, "{}" ],
      [ 429, "{}" ],
      [ 500, "{}" ],
      [ 503, "oops" ],
      [ 302, "" ]
    ].each do |status, body|
      it "HTTP #{status}: token_exchange_rejected。公開鍵を取得しない" do
        stub_request(:post, google_config.fetch(:token_endpoint)).to_return(status: status, body: body, headers: { "Location" => "https://evil.example.test/steal" })

        expect_failure(:token_exchange_rejected) { authenticate }
        expect(a_request(:get, google_config.fetch(:jwks_uri))).not_to have_been_made
        expect(a_request(:any, "https://evil.example.test/steal")).not_to have_been_made
      end
    end

    it "HTTP 200 でも、本文が JSON でない: token_response_invalid" do
      stub_token_endpoint(body: "not json")

      expect_failure(:token_response_invalid) { authenticate }
    end

    it "HTTP 200 でも、JSON の配列: token_response_invalid" do
      stub_token_endpoint(body: "[]")

      expect_failure(:token_response_invalid) { authenticate }
    end

    it "応答が大きすぎる: token_response_invalid" do
      stub_request(:post, google_config.fetch(:token_endpoint)).to_return(status: 200, body: "x" * (ExternalHttp::MAX_BODY_BYTES + 1))

      expect_failure(:token_response_invalid) { authenticate }
    end

    [
      [ "id_token が無い", {} ],
      [ "id_token が空", { "id_token" => "" } ],
      [ "id_token が文字列でない", { "id_token" => 123 } ],
      [ "id_token が null", { "id_token" => nil } ]
    ].each do |label, extra|
      it "#{label}: id_token_missing" do
        stub_token_endpoint(body: JSON.generate({ "access_token" => access_token }.merge(extra)))

        expect_failure(:id_token_missing) { authenticate }
      end
    end

    {
      "タイムアウト" => ->(stub) { stub.to_timeout },
      "接続の拒否" => ->(stub) { stub.to_raise(Errno::ECONNREFUSED) },
      "名前が引けない" => ->(stub) { stub.to_raise(SocketError) },
      "TLS の失敗（証明書の検証など）" => ->(stub) { stub.to_raise(OpenSSL::SSL::SSLError) },
      "読み取りのタイムアウト" => ->(stub) { stub.to_raise(Net::ReadTimeout) }
    }.each do |label, arrange|
      it "通信の失敗（#{label}）: token_endpoint_unreachable" do
        arrange.call(stub_request(:post, google_config.fetch(:token_endpoint)))

        expect_failure(:token_endpoint_unreachable) { authenticate }
      end
    end
  end

  describe "#authenticate（公開鍵の取得と鍵の入れ替え）" do
    it "公開鍵を取得できない: jwks_unavailable" do
      stub_token_endpoint(id_token: mint_id_token(claims))
      stub_request(:get, google_config.fetch(:jwks_uri)).to_raise(Errno::ECONNREFUSED)

      expect_failure(:jwks_unavailable) { authenticate }
    end

    it "公開鍵の応答が HTTP 500: jwks_unavailable" do
      stub_token_endpoint(id_token: mint_id_token(claims))
      stub_jwks(status: 500)

      expect_failure(:jwks_unavailable) { authenticate }
    end

    it "鍵の入れ替え: 新しい kid の ID トークンは、公開鍵を再取得して検証される（最短の間隔のあと）" do
      stub_jwks
      stub_token_endpoint(id_token: mint_id_token(claims))
      authenticate
      stub_jwks(jwks_document({ kid => signing_key, other_kid => other_key }))
      stub_token_endpoint(id_token: mint_id_token(id_token_claims(now: now + 120), key: other_key, kid: other_kid))

      identity = authenticate(at: now + 120)

      expect(identity.sub).to eq(google_sub)
      expect(a_request(:get, google_config.fetch(:jwks_uri))).to have_been_made.twice
    end

    it "未知の kid が続いても、最短の間隔の前は再取得しない: signing_key_unknown（取得先を叩き続けない）" do
      stub_jwks
      stub_token_endpoint(id_token: mint_id_token(claims, key: other_key, kid: "dummy-unknown-kid"))

      3.times { expect_failure(:signing_key_unknown) { authenticate } }

      expect(a_request(:get, google_config.fetch(:jwks_uri))).to have_been_made.once
    end

    it "再取得しても kid が無ければ: signing_key_unknown" do
      stub_jwks
      stub_token_endpoint(id_token: mint_id_token(claims, key: other_key, kid: "dummy-unknown-kid"))
      authenticate_error = nil
      begin
        authenticate
      rescue GoogleOidc::AuthenticationFailed => error
        authenticate_error = error
      end
      expect(authenticate_error.reason).to eq(:signing_key_unknown)

      expect_failure(:signing_key_unknown) { authenticate(at: now + 120) }
      expect(a_request(:get, google_config.fetch(:jwks_uri))).to have_been_made.twice
    end
  end

  describe "引数の検査（呼び出しの誤りは ArgumentError）" do
    it "code・code_verifier・nonce・redirect_uri が空・文字列でない" do
      valid = { code: auth_code, code_verifier: code_verifier, nonce: nonce_value, redirect_uri: redirect_uri, now: now }
      %i[ code code_verifier nonce redirect_uri ].each do |name|
        [ nil, "", "  ", 1 ].each do |bad|
          expect { client.authenticate(**valid, name => bad) }.to raise_error(ArgumentError, /#{name}/)
        end
      end
    end

    it "now が Time でない" do
      [ nil, "2026-10-08", 1_760_000_000 ].each do |bad|
        expect { authenticate(at: bad) }.to raise_error(ArgumentError, /now/)
      end
    end

    it "検査の誤りでは、通信しない" do
      expect { authenticate(code: "") }.to raise_error(ArgumentError)
      expect(a_request(:any, /./)).not_to have_been_made
    end

    it "構築: クライアント ID・秘密値が空、エンドポイントの欠落・https でない URL" do
      [ nil, "", "  ", 1 ].each do |bad|
        expect { described_class.new(client_id: bad, client_secret: client_secret, http: http, endpoints: google_config, jwks_cache: cache) }.to raise_error(ArgumentError, /client_id/)
        expect { described_class.new(client_id: client_id, client_secret: bad, http: http, endpoints: google_config, jwks_cache: cache) }.to raise_error(ArgumentError, /client_secret/)
      end
      expect { described_class.new(client_id: client_id, client_secret: client_secret, http: http, endpoints: google_config.except(:token_endpoint), jwks_cache: cache) }
        .to raise_error(ArgumentError, /token_endpoint/)
      expect { described_class.new(client_id: client_id, client_secret: client_secret, http: http, endpoints: google_config.merge(token_endpoint: "http://oauth2.googleapis.com/token"), jwks_cache: cache) }
        .to raise_error(ArgumentError, /token_endpoint/)
      expect { described_class.new(client_id: client_id, client_secret: client_secret, http: http, endpoints: google_config.merge(issuers: []), jwks_cache: cache) }
        .to raise_error(ArgumentError, /issuers/)
    end
  end

  describe "秘密値・トークン・コード・sub を出さない" do
    secrets_in_logs = lambda do |test|
      [ GoogleOidcSupport::CODE, GoogleOidcSupport::CODE_VERIFIER, GoogleOidcSupport::CLIENT_SECRET, GoogleOidcSupport::ACCESS_TOKEN,
        GoogleOidcSupport::SUB, test.mint_id_token(test.id_token_claims(now: Time.utc(2026, 10, 8, 3, 0, 0))) ]
    end

    it "inspect に、クライアントの秘密値を出さない" do
      expect(client.inspect).not_to include(client_secret)
      expect(client.inspect).not_to include(client_id)
    end

    it "失敗のログに、理由の符号だけを出す（トークン・コード・検証子・秘密値・sub を出さない）" do
      arrange_exchange(claims.merge("nonce" => "dummy-other-nonce"))

      output = capture_logs { expect_failure(:nonce_mismatch) { authenticate } }

      expect(output).to include("[google_oidc]")
      expect(output).to include("reason=nonce_mismatch")
      secrets_in_logs.call(self).each { |secret| expect(output).not_to include(secret) }
    end

    it "交換の拒否のログに、状態の符号を出す。応答の本文（エラーの説明・トークン）は出さない" do
      stub_request(:post, google_config.fetch(:token_endpoint))
        .to_return(status: 400, body: JSON.generate("error" => "invalid_grant", "error_description" => "dummy-description-must-not-appear"))

      output = capture_logs { expect_failure(:token_exchange_rejected) { authenticate } }

      expect(output).to include("reason=token_exchange_rejected")
      expect(output).to include("status=400")
      expect(output).not_to include("dummy-description-must-not-appear")
      secrets_in_logs.call(self).each { |secret| expect(output).not_to include(secret) }
    end

    it "例外のメッセージに、トークン・コード・sub を含めない" do
      arrange_exchange(claims.merge("sub" => "dummy-sub-with space"))

      expect { authenticate }.to raise_error(GoogleOidc::AuthenticationFailed) { |error|
        expect(error.message).to eq("google authentication failed: subject_invalid")
        secrets_in_logs.call(self).each { |secret| expect(error.message).not_to include(secret) }
      }
    end

    it "Identity の inspect に、sub を出さない" do
      arrange_exchange

      identity = authenticate

      expect(identity.inspect).not_to include(google_sub)
      expect(identity.to_s).not_to include(google_sub)
    end
  end
end
