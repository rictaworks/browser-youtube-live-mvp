require "base64"
require "digest"

# ログインの手続き（issue #8。requirements.md 7.1・23.1・28.1）。HTTP・Cookie・セッションを知らない（コントローラが、それらを扱う）。
#
#   start     認可の開始。state・nonce・PKCE の検証子（S256 の challenge）を作り、認可 URL を組み立てる。
#             state・nonce・検証子は、コントローラが bl_oauth（暗号化した短命の Cookie）に入れる
#   complete  認可の完了（コールバック）。次の順に確かめ、結果（Completion）を返す。
#               1. 保管した状態（bl_oauth）がある
#               2. state が一致する（定数時間で比較）。不一致・欠落は改ざん・取り違え
#               3. error パラメータが無い（利用者が認可を拒否した場合など）
#               4. 認可コードがある
#               5. コードを交換し、ID トークンを検証して、sub を得る（nonce・PKCE の検証子を渡す。GoogleOidc::AuthenticationFailed は :failed）
#               6. sub でアカウントを特定する（AccountRegistry）。保留中（削除から間もない）なら作らず :registration_held
#               7. 最終ログイン時刻を更新する
#             結果の status: :logged_in（user つき）・:registration_held・:failed（reason は理由の符号）
#
# 想定外の例外（DB の失敗など）は、握りつぶさずに伝える。state・nonce・検証子・コード・sub を、ログ・inspect に出さない
# （ログに出すのは、理由の符号と、内部のアカウント識別子だけ）。時刻は引数 now で受け取る。
class LoginProcedure
  STATE_BYTES = 32
  NONCE_BYTES = 32
  # PKCE の検証子: 64 バイトの乱数 = base64url で 86 文字（RFC 7636 は 43〜128 文字）
  VERIFIER_BYTES = 64
  # 認可コードの長さの上限（文字）。Google のコードは 100 文字前後
  CODE_MAX_LENGTH = 2048
  LOG_TAG = "[login]".freeze

  # 認可の開始の結果。inspect に値を出さない（認可 URL に state・nonce を含む）
  Start = Data.define(:authorization_url, :state, :nonce, :code_verifier) do
    def inspect
      "#<#{self.class.name} [FILTERED]>"
    end

    def to_s
      inspect
    end
  end

  # 認可の完了の結果。status は :logged_in・:registration_held・:failed。user は :logged_in のときだけ。reason は :failed のときだけ
  Completion = Data.define(:status, :user, :reason) do
    def logged_in?
      status == :logged_in
    end

    def held?
      status == :registration_held
    end

    def failed?
      status == :failed
    end
  end

  # oidc は GoogleOidcClient（実物）か FakeGoogleOidc（開発・テスト）。registry は AccountRegistry
  def initialize(oidc:, registry: AccountRegistry.new, logger: Rails.logger)
    @oidc = oidc
    @registry = registry
    @logger = logger
  end

  # 認可の開始。redirect_uri は、公開オリジンの /api/auth/callback
  def start(redirect_uri:)
    raise ArgumentError, "redirect_uri must be a non-empty String" unless redirect_uri.is_a?(String) && !redirect_uri.strip.empty?

    state = SecureRandom.urlsafe_base64(STATE_BYTES)
    nonce = SecureRandom.urlsafe_base64(NONCE_BYTES)
    code_verifier = SecureRandom.urlsafe_base64(VERIFIER_BYTES)
    authorization_url = @oidc.authorization_url(
      state: state, nonce: nonce, code_challenge: code_challenge_for(code_verifier), redirect_uri: redirect_uri
    )
    Start.new(authorization_url: authorization_url, state: state, nonce: nonce, code_verifier: code_verifier)
  end

  # 認可の完了。payload は bl_oauth から取り出した状態（OAuthStateCookie::Payload。無効・無しなら nil）。
  # code・state・error は、コールバックのクエリの値（無ければ nil。文字列でない値も来うる）
  def complete(payload:, code:, state:, error:, redirect_uri:, now:)
    check_arguments!(payload, redirect_uri, now)

    refusal = refusal_reason(payload, code, state, error)
    return failed(refusal) if refusal

    identity = @oidc.authenticate(code: code, code_verifier: payload.code_verifier, nonce: payload.nonce, redirect_uri: redirect_uri, now: now)
    registration = @registry.find_or_register(google_sub: identity.sub, now: now)
    return held if registration.held?

    logged_in(registration, now)
  rescue GoogleOidc::AuthenticationFailed => failure
    failed(failure.reason)
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private

  def code_challenge_for(code_verifier)
    Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier), padding: false)
  end

  # コードを交換する前に拒否する理由（無ければ nil）
  def refusal_reason(payload, code, state, error)
    return :state_cookie_invalid if payload.nil?
    return :state_mismatch unless state_matches?(payload.state, state)
    return :authorization_denied unless error.nil?
    return :code_missing unless code.is_a?(String) && !code.strip.empty?

    :code_too_long if code.length > CODE_MAX_LENGTH
  end

  def state_matches?(expected, given)
    given.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(expected, given)
  end

  def logged_in(registration, now)
    user = registration.user
    user.update!(last_login_at: now) if registration.existing?
    @logger.info("#{LOG_TAG} completed user_id=#{user.id}")
    Completion.new(status: :logged_in, user: user, reason: nil)
  end

  def held
    @logger.info("#{LOG_TAG} registration held")
    Completion.new(status: :registration_held, user: nil, reason: nil)
  end

  def failed(reason)
    @logger.warn("#{LOG_TAG} failed reason=#{reason}")
    Completion.new(status: :failed, user: nil, reason: reason)
  end

  def check_arguments!(payload, redirect_uri, now)
    unless payload.nil? || (payload.is_a?(OAuthStateCookie::Payload) && payload.purpose == "login")
      raise ArgumentError, "payload must be nil or the state of a login (OAuthStateCookie::Payload with the login purpose)"
    end
    raise ArgumentError, "redirect_uri must be a non-empty String" unless redirect_uri.is_a?(String) && !redirect_uri.strip.empty?
    raise ArgumentError, "now must be a Time" unless now.is_a?(Time)
  end
end
