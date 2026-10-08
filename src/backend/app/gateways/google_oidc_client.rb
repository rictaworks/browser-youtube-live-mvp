require "base64"
require "digest"
require "jwt"

# Google ログイン（OpenID Connect の認可コードフロー + PKCE）の実物（issue #8。requirements.md 7.1・23.1・28.1）。
#
#   authorization_url  Google の認可 URL。スコープは openid のみ（メールアドレス・プロフィールを要求しない）・response_type=code・
#                      PKCE（code_challenge_method=S256）・state・nonce・redirect_uri
#   authenticate       認可コードをトークンへ交換し（client_secret と PKCE の検証子を送る）、ID トークンを検証して、sub を返す
#
# ID トークンの検証は、jwt gem に任せる（署名の検証を自作しない）。
#   署名        Google の公開鍵（JWKS。GoogleJwksCache がキャッシュし、kid で選ぶ）。アルゴリズムは RS256 だけ（none・HS256 への取り違えを許さない）
#   iss・aud    設定の iss（2 つの形）・クライアント ID。aud が複数なら、azp がクライアント ID
#   必須の claims  iss・aud・sub・exp・iat・nonce
# gem が実時計を読む検証（exp・iat）は使わず、引数 now で行う（時計を引数で受け取る。テストで時刻を進められる）。
#   exp  now 以前（now と同じ時刻を含む）は期限切れ。 iat  now より 60 秒を超えて先なら拒否（時計のずれ）
#   nonce  bl_oauth の値と一致（定数時間で比較）。 sub  ASCII の表示できる文字の 1〜255 文字
#
# 失敗は GoogleOidc::AuthenticationFailed（理由の符号だけ）。アクセストークンは取り出さない・保持しない。メール・氏名などの claims も
# 取り出さない。コード・検証子・秘密値・トークン・sub を、ログ・例外に出さない。通信は ExternalHttp（接続 3 秒・読み取り 5 秒・リダイレクトを追わない）。
class GoogleOidcClient
  SCOPE = "openid".freeze
  CODE_CHALLENGE_METHOD = "S256".freeze
  ALGORITHMS = %w[ RS256 ].freeze
  REQUIRED_CLAIMS = %w[ iss aud sub exp iat nonce ].freeze
  # iat が now より先でもよい範囲（秒。時計のずれ）
  IAT_LEEWAY_SECONDS = 60
  # Google の sub は、最大 255 文字の ASCII（https://developers.google.com/identity/openid-connect/openid-connect）
  SUB_PATTERN = /\A[\x21-\x7E]{1,255}\z/
  # ID トークンの長さの上限（文字）。Google の ID トークンは 1,500 文字前後
  ID_TOKEN_MAX_LENGTH = 16_384
  LOG_TAG = "[google_oidc]".freeze

  # トークンエンドポイントとの通信の失敗（ExternalHttp::Failure の符号）の対応
  UNREACHABLE_CAUSES = %i[ timeout connection tls ].freeze

  # 公開鍵のキャッシュ（プロセスで共有する。ExternalServices が渡す）
  attr_reader :jwks_cache

  def initialize(client_id:, client_secret:, http:, endpoints:, jwks_cache:, logger: Rails.logger)
    @client_id = non_blank!(client_id, "client_id")
    @client_secret = non_blank!(client_secret, "client_secret")
    @authorization_endpoint = https_endpoint!(endpoints, :authorization_endpoint)
    @token_endpoint = https_endpoint!(endpoints, :token_endpoint)
    @issuers = issuers!(endpoints)
    @http = http
    @jwks_cache = jwks_cache
    @logger = logger
  end

  # Google の認可 URL（スコープは openid のみ）
  def authorization_url(state:, nonce:, code_challenge:, redirect_uri:)
    uri = URI.parse(@authorization_endpoint)
    uri.query = URI.encode_www_form(
      client_id: @client_id,
      redirect_uri: non_blank!(redirect_uri, "redirect_uri"),
      response_type: "code",
      scope: SCOPE,
      state: non_blank!(state, "state"),
      nonce: non_blank!(nonce, "nonce"),
      code_challenge: non_blank!(code_challenge, "code_challenge"),
      code_challenge_method: CODE_CHALLENGE_METHOD
    )
    uri.to_s
  end

  # 認可コードを交換し、ID トークンを検証して、Identity（sub）を返す。失敗は GoogleOidc::AuthenticationFailed
  def authenticate(code:, code_verifier:, nonce:, redirect_uri:, now:)
    non_blank!(code, "code")
    non_blank!(code_verifier, "code_verifier")
    non_blank!(nonce, "nonce")
    non_blank!(redirect_uri, "redirect_uri")
    raise ArgumentError, "now must be a Time" unless now.is_a?(Time)

    id_token = exchange_code(code, code_verifier, redirect_uri)
    claims = decode_id_token(id_token, now)
    verify_claims!(claims, nonce, now)
    GoogleOidc::Identity.new(sub: claims.fetch("sub"))
  rescue GoogleOidc::AuthenticationFailed => failure
    @logger.warn("#{LOG_TAG} authentication failed reason=#{failure.reason}")
    raise
  end

  # クライアント ID・秘密値を出さない
  def inspect
    "#<#{self.class.name}>"
  end

  private

  # --- 認可コードの交換 ---

  # トークンエンドポイントへ交換を依頼し、ID トークンの文字列を返す。アクセストークンは取り出さない
  def exchange_code(code, code_verifier, redirect_uri)
    response = @http.post_form(
      @token_endpoint,
      form: {
        code: code, client_id: @client_id, client_secret: @client_secret, redirect_uri: redirect_uri,
        grant_type: "authorization_code", code_verifier: code_verifier
      }
    )
    rejected!(response.status) unless response.status == 200

    body = response.json
    failed!(:token_response_invalid) unless body.is_a?(Hash)

    id_token = body["id_token"]
    failed!(:id_token_missing) unless id_token.is_a?(String) && !id_token.empty?

    id_token
  rescue ExternalHttp::Failure => failure
    failed!(UNREACHABLE_CAUSES.include?(failure.reason) ? :token_endpoint_unreachable : :token_response_invalid)
  end

  def rejected!(status)
    @logger.warn("#{LOG_TAG} token exchange rejected status=#{status}")
    failed!(:token_exchange_rejected)
  end

  # --- ID トークンの検証 ---

  # 署名・iss・aud・必須の claims を、jwt gem で検証して、claims を返す
  def decode_id_token(id_token, now)
    failed!(:id_token_malformed) if id_token.length > ID_TOKEN_MAX_LENGTH

    claims, _header = JWT.decode(id_token, nil, true, decode_options(now))
    claims
  rescue JWT::IncorrectAlgorithm
    failed!(:algorithm_invalid)
  rescue JWT::VerificationError
    failed!(:signature_invalid)
  rescue JWT::SignatureError
    failed!(:signing_key_unknown)
  rescue JWT::InvalidIssuerError
    failed!(:issuer_invalid)
  rescue JWT::InvalidAudError
    failed!(:audience_invalid)
  rescue JWT::MissingRequiredClaim
    failed!(:claim_missing)
  rescue JWT::MalformedTokenError
    failed!(:id_token_malformed)
  rescue JWT::Error
    failed!(:id_token_invalid)
  end

  # exp・iat は、gem が実時計で検証するので無効にし、verify_claims! で now を使って検証する
  def decode_options(now)
    {
      algorithms: ALGORITHMS,
      jwks: ->(options) { @jwks_cache.keys(now: now, invalidate: options[:invalidate] == true) },
      verify_iss: true, iss: @issuers,
      verify_aud: true, aud: @client_id,
      verify_expiration: false,
      verify_iat: false,
      required_claims: REQUIRED_CLAIMS
    }
  end

  # 署名の検証のあとの claims の検証（引数 now を使う）
  def verify_claims!(claims, nonce, now)
    exp = claims["exp"]
    iat = claims["iat"]
    failed!(:id_token_invalid) unless exp.is_a?(Numeric) && iat.is_a?(Numeric)
    failed!(:expired) if exp <= now.to_f
    failed!(:issued_in_future) if iat > now.to_f + IAT_LEEWAY_SECONDS
    failed!(:audience_invalid) if Array(claims["aud"]).size > 1 && claims["azp"] != @client_id
    failed!(:nonce_mismatch) unless matches?(claims["nonce"], nonce)
    failed!(:subject_invalid) unless claims["sub"].is_a?(String) && SUB_PATTERN.match?(claims["sub"])
  end

  def matches?(actual, expected)
    actual.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(actual, expected)
  end

  def failed!(reason)
    raise GoogleOidc::AuthenticationFailed.new(reason)
  end

  # --- 構築の検査 ---

  def non_blank!(value, name)
    raise ArgumentError, "#{name} must be a non-empty String" unless value.is_a?(String) && !value.strip.empty?

    value
  end

  def https_endpoint!(endpoints, key)
    value = endpoints[key]
    raise ArgumentError, "endpoints must have an https URL for #{key}" unless value.is_a?(String) && value.start_with?("https://")

    value
  end

  def issuers!(endpoints)
    issuers = endpoints[:issuers]
    raise ArgumentError, "endpoints must have issuers (a non-empty Array of String)" unless issuers.is_a?(Array) && !issuers.empty? && issuers.all?(String)

    issuers.dup.freeze
  end
end
