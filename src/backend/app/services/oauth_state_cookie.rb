# bl_oauth（issue #7。requirements.md 7.1・28.1。src/contracts/http-api.md 1.3）。
#
# 認可の途中の状態（state・nonce・PKCE の検証子・用途 login|connect・connect のときの内部のアカウント識別子）を、
# 暗号化した短命の Cookie で持つ。HttpOnly・SameSite=Lax・Path=/・Max-Age=600。本番は Secure（CookiePolicy）。
# 鍵は SESSION_SECRET から導出する（DerivedKeys の oauth_cookie。CSRF トークンの鍵とは別）。
#
# 暗号化は ActiveSupport::MessageEncryptor（AES-256-GCM。認証つき）。用途（login・connect）は、暗号化の用途にも結びつけ、
# 中身にも入れる。期限は、中身（exp）に入れ、引数で受け取る now と比べる（実時計に依存しない）。
# 改ざん・期限切れ・用途違い・でたらめな値は、すべて InvalidCookie（ほかの例外を漏らさない。メッセージに値を含めない）。
#
# 認可の完了後は、成功・失敗のどちらでも、Cookie を失効させる（state の再利用を防ぐ）。呼び出しは、Api::BaseController の
# issue_oauth_cookie・consume_oauth_cookie（#8・#11）。
class OAuthStateCookie
  NAME = "bl_oauth".freeze
  MAX_AGE = 600 # 秒
  PURPOSES = %w[ login connect ].freeze
  KEY_PURPOSE = "oauth_cookie".freeze

  # Cookie は 4096 バイトまで。これを超える値は、でたらめとして扱う
  MAX_SEALED_BYTES = 4096
  # state・nonce・検証子の、1 つあたりの長さの上限（Cookie に収める）
  MAX_FIELD_LENGTH = 512
  UUID_PATTERN = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  Payload = Data.define(:state, :nonce, :code_verifier, :purpose, :user_id)

  # Cookie が無効（改ざん・期限切れ・用途違い・でたらめな値）。メッセージに値を含めない
  class InvalidCookie < StandardError
    def initialize(message = "invalid oauth state cookie")
      super
    end
  end

  # Cookie を設定するときの属性（Rails の cookies[]= へ渡す Hash）
  def self.attributes(sealed, environment: AppEnvironment.current)
    { value: sealed, httponly: true, same_site: :lax, path: "/", max_age: MAX_AGE, secure: CookiePolicy.secure?(environment) }
  end

  # Cookie を失効させるときの属性（Path・HttpOnly・SameSite は、設定のときと同じ）
  def self.expiry_attributes(environment: AppEnvironment.current)
    { httponly: true, same_site: :lax, path: "/", secure: CookiePolicy.secure?(environment) }
  end

  def initialize(secret:)
    key = DerivedKeys.new(secret: secret).derive(KEY_PURPOSE)
    @encryptor = ActiveSupport::MessageEncryptor.new(
      key, cipher: "aes-256-gcm", serializer: ActiveSupport::MessageEncryptor::NullSerializer, url_safe: true
    )
  end

  # 状態を暗号化して、Cookie の値（URL 安全な文字列）にする。入力の誤りは ArgumentError（呼び出しの誤り）
  def seal(state:, nonce:, code_verifier:, purpose:, now:, user_id: nil)
    validate_seal!(state: state, nonce: nonce, code_verifier: code_verifier, purpose: purpose, now: now, user_id: user_id)

    json = JSON.generate(
      "state" => state, "nonce" => nonce, "code_verifier" => code_verifier,
      "purpose" => purpose, "user_id" => user_id, "exp" => now.to_i + MAX_AGE
    )
    @encryptor.encrypt_and_sign(json, purpose: purpose)
  end

  # Cookie の値から、状態を取り出す。無効なら InvalidCookie。expected_purpose（login・connect）が合わなければ、無効。
  def open(sealed, expected_purpose:, now:)
    raise ArgumentError, "expected_purpose must be one of: #{PURPOSES.join(', ')}" unless PURPOSES.include?(expected_purpose)
    raise ArgumentError, "now must be a Time" unless now.is_a?(Time)

    payload = parse(decrypt(sealed, expected_purpose))
    raise InvalidCookie unless payload.fetch("purpose") == expected_purpose
    raise InvalidCookie unless now.to_i < payload.fetch("exp")

    Payload.new(
      state: payload.fetch("state"), nonce: payload.fetch("nonce"), code_verifier: payload.fetch("code_verifier"),
      purpose: payload.fetch("purpose"), user_id: payload.fetch("user_id")
    )
  end

  def inspect
    "#<#{self.class.name} [FILTERED]>"
  end

  private

  def validate_seal!(state:, nonce:, code_verifier:, purpose:, now:, user_id:)
    raise ArgumentError, "purpose must be one of: #{PURPOSES.join(', ')}" unless PURPOSES.include?(purpose)
    raise ArgumentError, "now must be a Time" unless now.is_a?(Time)

    { "state" => state, "nonce" => nonce, "code_verifier" => code_verifier }.each do |name, value|
      unless value.is_a?(String) && !value.strip.empty? && value.length <= MAX_FIELD_LENGTH
        raise ArgumentError, "#{name} must be a non-empty String of at most #{MAX_FIELD_LENGTH} characters"
      end
    end

    if purpose == "connect"
      raise ArgumentError, "user_id (a UUID) is required for the connect purpose" unless user_id.is_a?(String) && UUID_PATTERN.match?(user_id)
    elsif !user_id.nil?
      raise ArgumentError, "user_id must not be given for the login purpose"
    end
  end

  # 復号する。でたらめな値は、InvalidCookie
  def decrypt(sealed, purpose)
    unless sealed.is_a?(String) && !sealed.empty? && sealed.bytesize <= MAX_SEALED_BYTES && sealed.valid_encoding?
      raise InvalidCookie
    end

    plain = @encryptor.decrypt_and_verify(sealed, purpose: purpose)
    raise InvalidCookie if plain.nil? # 用途違い

    plain
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, ArgumentError, EncodingError
    raise InvalidCookie
  end

  # 中身を検査する。形が違えば InvalidCookie
  def parse(plain)
    data = JSON.parse(plain)
    raise InvalidCookie unless data.is_a?(Hash) && well_formed?(data)

    data
  rescue JSON::ParserError
    raise InvalidCookie
  end

  def well_formed?(data)
    return false unless %w[ state nonce code_verifier ].all? { |key| data[key].is_a?(String) && !data[key].empty? }
    return false unless PURPOSES.include?(data["purpose"]) && data["exp"].is_a?(Integer)

    user_id = data["user_id"]
    data["purpose"] == "connect" ? (user_id.is_a?(String) && UUID_PATTERN.match?(user_id)) : user_id.nil?
  end
end
