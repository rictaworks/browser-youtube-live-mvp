# CSRF トークン（issue #7。requirements.md 28.1。src/contracts/http-api.md 1.2・1.4）。
#
# セッションの識別子（Cookie bl_session の値）と SESSION_SECRET から、HMAC-SHA256 で導出する。保存しない。
# GET /api/state が返す csrf_token と、状態を変える要求の X-CSRF-Token の照合の、両方が、同じ導出を使う。
# セッションごとに違う値（同じアカウントの別のセッションとも違う）。セッションを破棄すれば、そのトークンは、検査の相手が無くなる。
class CsrfToken
  PURPOSE = "csrf".freeze

  def initialize(secret:)
    @key = DerivedKeys.new(secret: secret).derive(PURPOSE)
  end

  # セッションの識別子に紐づく、64 文字の 16 進数
  def derive(session_token)
    raise ArgumentError, "session token must be a non-empty String" unless session_token.is_a?(String) && !session_token.strip.empty?

    OpenSSL::HMAC.hexdigest("SHA256", @key, session_token)
  end

  # 提示された値（X-CSRF-Token）が、セッションに紐づく値と一致するか。定数時間で比較する。
  # セッションの識別子が不正・値が文字列でない場合は、例外にせず false（照合の失敗）。
  def valid?(session_token, provided)
    return false unless provided.is_a?(String)

    ActiveSupport::SecurityUtils.secure_compare(derive(session_token), provided)
  rescue ArgumentError
    false
  end

  def inspect
    "#<#{self.class.name} [FILTERED]>"
  end
end
