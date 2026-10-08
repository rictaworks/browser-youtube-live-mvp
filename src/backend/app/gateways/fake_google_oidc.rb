require "base64"
require "digest"
require "openssl"

# 疑似の Google ログイン（issue #8）。開発・テストのみ。GoogleOidcClient と同じ使い方で、実際の Google を呼ばない。
# 利用者のログインの操作は本番と同じ経路（ランディングの「ログイン」→ login/start → 認可 URL → コールバック → /studio）で、
# 疑似は、認可 URL の行き先だけを差し替える。開発者向けの近道（ログイン済みの状態を直接作る経路）は、持たない。
#
#   authorization_url  行き先は、redirect_uri と同じオリジンの疑似の認可画面（/api/dev/google/authorize。Dev::GoogleController）。
#                      パラメータは本物と同じ（response_type=code・scope=openid・PKCE の S256・state・nonce・redirect_uri。client_id は無い）
#   issue_code         疑似の認可画面が、選ばれたアカウントに発行する認可コード。sub・nonce・PKCE の challenge・redirect_uri・期限を含む
#                      （ステートレス。サーバーに記憶を持たない）。改ざんを検出するため、鍵つきのハッシュ（HMAC）を付ける
#   authenticate       本物と同じ検証（期限・redirect_uri・PKCE・nonce）を行い、Identity（sub）を返す。失敗は GoogleOidc::AuthenticationFailed
#
# アカウントは、設定（config/external_services.yml の fake_google）の固定の 3 つ（dev-user-1〜dev-user-3）だけ。
# 本番では構築できない（FakeServices）。コード・検証子・sub を、ログ・例外に出さない。時刻は引数 now で受け取る。
class FakeGoogleOidc
  CODE_KEY_PURPOSE = "fake_google_code".freeze
  CODE_PATTERN = /\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/
  CODE_MAX_LENGTH = 4096
  ACCOUNT_PATTERN = /\A[A-Za-z0-9_-]{1,64}\z/
  LOG_TAG = "[fake_google]".freeze

  attr_reader :accounts

  def initialize(secret:, config: ExternalServices.config.fetch(:fake_google), environment: AppEnvironment.current, logger: Rails.logger)
    FakeServices.verify_environment!(environment)
    @key = DerivedKeys.new(secret: secret).derive(CODE_KEY_PURPOSE)
    @accounts = accounts!(config).freeze
    @authorize_path = path!(config)
    @code_lifetime_seconds = lifetime!(config)
    @logger = logger
  end

  # 疑似の認可画面の URL（redirect_uri と同じオリジン）
  def authorization_url(state:, nonce:, code_challenge:, redirect_uri:)
    origin = origin_of(non_blank!(redirect_uri, "redirect_uri"))
    query = URI.encode_www_form(
      response_type: "code",
      scope: GoogleOidcClient::SCOPE,
      redirect_uri: redirect_uri,
      state: non_blank!(state, "state"),
      nonce: non_blank!(nonce, "nonce"),
      code_challenge: non_blank!(code_challenge, "code_challenge"),
      code_challenge_method: GoogleOidcClient::CODE_CHALLENGE_METHOD
    )
    "#{origin}#{@authorize_path}?#{query}"
  end

  # 選ばれたアカウント（sub）に発行する認可コード
  def issue_code(sub:, nonce:, code_challenge:, redirect_uri:, now:)
    raise ArgumentError, "sub must be one of the fixed fake accounts" unless @accounts.include?(sub)

    non_blank!(nonce, "nonce")
    non_blank!(code_challenge, "code_challenge")
    non_blank!(redirect_uri, "redirect_uri")
    raise ArgumentError, "now must be a Time" unless now.is_a?(Time)

    encoded = encode(JSON.generate(
      "sub" => sub, "nonce" => nonce, "challenge" => code_challenge, "redirect_uri" => redirect_uri,
      "exp" => now.to_i + @code_lifetime_seconds
    ))
    "#{encoded}.#{sign(encoded)}"
  end

  # 本物の GoogleOidcClient#authenticate と同じ引数・同じ検証・同じ例外
  def authenticate(code:, code_verifier:, nonce:, redirect_uri:, now:)
    non_blank!(code, "code")
    non_blank!(code_verifier, "code_verifier")
    non_blank!(nonce, "nonce")
    non_blank!(redirect_uri, "redirect_uri")
    raise ArgumentError, "now must be a Time" unless now.is_a?(Time)

    payload = open_code(code)
    verify_payload!(payload, code_verifier, nonce, redirect_uri, now)
    GoogleOidc::Identity.new(sub: payload.fetch("sub"))
  rescue GoogleOidc::AuthenticationFailed => failure
    @logger.warn("#{LOG_TAG} authentication failed reason=#{failure.reason}")
    raise
  end

  # 鍵を出さない
  def inspect
    "#<#{self.class.name}>"
  end

  private

  # --- コード ---

  def open_code(code)
    failed!(:code_invalid) unless code.length <= CODE_MAX_LENGTH && CODE_PATTERN.match?(code)

    encoded, signature = code.split(".", 2)
    failed!(:code_invalid) unless ActiveSupport::SecurityUtils.secure_compare(signature, sign(encoded))

    payload = JSON.parse(Base64.urlsafe_decode64(encoded))
    failed!(:code_invalid) unless well_formed?(payload)

    payload
  rescue ArgumentError, JSON::ParserError
    failed!(:code_invalid)
  end

  def well_formed?(payload)
    payload.is_a?(Hash) &&
      %w[ sub nonce challenge redirect_uri ].all? { |key| payload[key].is_a?(String) } &&
      payload["exp"].is_a?(Integer) &&
      @accounts.include?(payload["sub"])
  end

  def verify_payload!(payload, code_verifier, nonce, redirect_uri, now)
    failed!(:code_expired) if payload.fetch("exp") <= now.to_i
    failed!(:redirect_uri_mismatch) unless same?(payload.fetch("redirect_uri"), redirect_uri)
    failed!(:pkce_mismatch) unless same?(payload.fetch("challenge"), s256(code_verifier))
    failed!(:nonce_mismatch) unless same?(payload.fetch("nonce"), nonce)
  end

  def same?(left, right)
    ActiveSupport::SecurityUtils.secure_compare(left, right)
  end

  def s256(verifier)
    encode(Digest::SHA256.digest(verifier))
  end

  def sign(encoded)
    encode(OpenSSL::HMAC.digest("SHA256", @key, encoded))
  end

  def encode(bytes)
    Base64.urlsafe_encode64(bytes, padding: false)
  end

  def failed!(reason)
    raise GoogleOidc::AuthenticationFailed.new(reason)
  end

  # --- 引数・設定の検査 ---

  def non_blank!(value, name)
    raise ArgumentError, "#{name} must be a non-empty String" unless value.is_a?(String) && !value.strip.empty?

    value
  end

  # http・https のオリジン（スキーム + ホスト + 非標準のポート）を返す
  def origin_of(redirect_uri)
    uri = URI.parse(redirect_uri)
    raise ArgumentError, "redirect_uri must be an http or https URL with a host" unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty? && uri.userinfo.nil?

    port = uri.port == uri.default_port ? "" : ":#{uri.port}"
    "#{uri.scheme}://#{uri.host}#{port}"
  rescue URI::InvalidURIError
    raise ArgumentError, "redirect_uri must be an http or https URL with a host"
  end

  def accounts!(config)
    accounts = config.fetch(:accounts)
    valid = accounts.is_a?(Array) && !accounts.empty? && accounts.all? { |account| account.is_a?(String) && ACCOUNT_PATTERN.match?(account) }
    raise ArgumentError, "fake_google.accounts must be a non-empty Array of account names" unless valid

    accounts.dup
  end

  def path!(config)
    path = config.fetch(:authorize_path)
    raise ArgumentError, "fake_google.authorize_path must be an absolute path" unless path.is_a?(String) && path.match?(%r{\A/[A-Za-z0-9/_-]+\z})

    path
  end

  def lifetime!(config)
    seconds = config.fetch(:code_lifetime_seconds)
    raise ArgumentError, "fake_google.code_lifetime_seconds must be a positive Integer" unless seconds.is_a?(Integer) && seconds.positive?

    seconds
  end
end
