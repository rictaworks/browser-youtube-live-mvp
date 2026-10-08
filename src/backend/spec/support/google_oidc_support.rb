# Google ログイン（OIDC）のスペックの共通の補助（issue #8）。
#
# ID トークンの署名には、テスト用の RSA 鍵を、メモリの上でだけ生成して使う。鍵をファイルに保存しない
# （*.pem・*.key を作らない。リポジトリに秘密鍵を置かない。requirements.md 28.1）。
# クライアント ID・秘密値・トークン・sub は、明らかなダミー値（dummy-…）。実際の Google は呼ばない（WebMock）。
#
# spec/rails_helper.rb は spec/support を自動では読み込まない。使うスペックは、先頭で
#   require "rails_helper"
#   require "support/external_http_support"
#   require "support/google_oidc_support"
# とし、`include GoogleOidcSupport` で使う。
require "jwt"
require "openssl"

module GoogleOidcSupport
  CLIENT_ID = "dummy-client-id-0001.apps.googleusercontent.com".freeze
  CLIENT_SECRET = "dummy-google-client-secret-0001".freeze
  KID = "dummy-key-id-0001".freeze
  OTHER_KID = "dummy-key-id-0002".freeze
  SUB = "dummy-google-sub-10001".freeze
  REDIRECT_URI = "https://app.example.test/api/auth/callback".freeze
  CODE = "dummy-authorization-code-0001".freeze
  CODE_VERIFIER = "dummy-code-verifier-0123456789-abcdefghijklmnopqrstuvwxyz".freeze
  NONCE = "dummy-nonce-value-0001".freeze
  ACCESS_TOKEN = "dummy-access-token-must-not-appear".freeze

  # メモリの上でだけ生成する鍵（プロセスごとに 1 回）
  module Keys
    @mutex = Mutex.new
    @cache = {}

    def self.fetch(name)
      @mutex.synchronize { @cache[name] ||= OpenSSL::PKey::RSA.generate(2048) }
    end
  end

  # 定数の読み取り口（スペックの本体（it・let）は、定数を字句の範囲で引くので、include した定数を、そのまま書けない）
  def client_id
    CLIENT_ID
  end

  def client_secret
    CLIENT_SECRET
  end

  def kid
    KID
  end

  def other_kid
    OTHER_KID
  end

  def google_sub
    SUB
  end

  def redirect_uri
    REDIRECT_URI
  end

  def auth_code
    CODE
  end

  def code_verifier
    CODE_VERIFIER
  end

  def nonce_value
    NONCE
  end

  def access_token
    ACCESS_TOKEN
  end

  def signing_key
    Keys.fetch(:signing)
  end

  def other_key
    Keys.fetch(:other)
  end

  # JWKS の本文（Google の https://www.googleapis.com/oauth2/v3/certs と同じ形）。keys は kid => 鍵（秘密鍵でも、公開鍵だけを載せる）
  def jwks_document(keys = { KID => signing_key })
    {
      "keys" => keys.map do |kid, key|
        JWT::JWK.new(key.public_key, { kid: kid }).export.transform_keys(&:to_s).merge("alg" => "RS256", "use" => "sig")
      end
    }
  end

  # ID トークンの claims（Google が openid だけを要求したときに返す形。email などは、テストで足す）
  def id_token_claims(now:, nonce: NONCE, **overrides)
    {
      "iss" => "https://accounts.google.com",
      "azp" => CLIENT_ID,
      "aud" => CLIENT_ID,
      "sub" => SUB,
      "at_hash" => "dummy-at-hash",
      "nonce" => nonce,
      "iat" => now.to_i - 5,
      "exp" => now.to_i + 3600
    }.merge(overrides.transform_keys(&:to_s)).reject { |_key, value| value == :omit }
  end

  # 署名した ID トークン。RS256 は、検証する側（jwt gem）とは別に、OpenSSL で組み立てる
  # （gem の符号化は、数値でない exp など、不正な claims を拒むため。検証側の異常系を作れるようにする）。
  # ほかの alg（none・HS256・RS384。取り違えの攻撃の再現）は、gem で符号化する
  def mint_id_token(claims, key: signing_key, kid: KID, algorithm: "RS256")
    return mint_rs256_token(claims, key, kid) if algorithm == "RS256"

    headers = kid.nil? ? {} : { kid: kid }
    JWT.encode(claims, key, algorithm, headers)
  end

  def mint_rs256_token(claims, key, kid)
    header = { "alg" => "RS256", "typ" => "JWT" }
    header["kid"] = kid unless kid.nil?
    signing_input = [ header, claims ].map { |part| Base64.urlsafe_encode64(JSON.generate(part), padding: false) }.join(".")
    signature = key.sign(OpenSSL::Digest.new("SHA256"), signing_input)
    "#{signing_input}.#{Base64.urlsafe_encode64(signature, padding: false)}"
  end

  # トークンエンドポイントの成功の応答（Google の形）
  def token_response_body(id_token)
    JSON.generate(
      "access_token" => ACCESS_TOKEN, "expires_in" => 3599, "scope" => "openid", "token_type" => "Bearer", "id_token" => id_token
    )
  end

  def google_config
    ExternalServices.config.fetch(:google_oidc)
  end

  def stub_jwks(document = jwks_document, status: 200)
    stub_request(:get, google_config.fetch(:jwks_uri)).to_return(status: status, body: JSON.generate(document), headers: { "Content-Type" => "application/json" })
  end

  def stub_token_endpoint(id_token: nil, status: 200, body: nil)
    stub_request(:post, google_config.fetch(:token_endpoint))
      .to_return(status: status, body: body || token_response_body(id_token), headers: { "Content-Type" => "application/json" })
  end

  # PKCE（S256）の code_challenge
  def s256_challenge(verifier)
    Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
  end
end
