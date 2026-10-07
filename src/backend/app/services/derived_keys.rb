# SESSION_SECRET（Rails の secret_key_base）から、用途ごとの鍵を導出する（issue #7。requirements.md 28.1・29.4）。
# 用途が違えば別の鍵になる（用途の分離）。例: CSRF トークン（"csrf"）・bl_oauth の暗号化（"oauth_cookie"）。
# 導出は、HMAC-SHA256 による一方向。鍵から、秘密値を復元できない。保存しない（毎回、導出する）。
class DerivedKeys
  KEY_BYTES = 32 # HMAC-SHA256 の出力の長さ。AES-256 の鍵として使える
  CONTEXT = "bl:key-derivation:v1".freeze

  def initialize(secret:)
    raise ArgumentError, "secret must be a non-empty String" unless secret.is_a?(String) && !secret.strip.empty?

    @secret = secret.dup.freeze
  end

  # 用途（"csrf" など）の鍵（32 バイトのバイナリ文字列）
  def derive(purpose)
    raise ArgumentError, "purpose must be a non-empty String" unless purpose.is_a?(String) && !purpose.empty?

    OpenSSL::HMAC.digest("SHA256", @secret, "#{CONTEXT}:#{purpose}")
  end

  # 秘密値を、ログ・例外の報告へ出さない
  def inspect
    "#<#{self.class.name} [FILTERED]>"
  end
end
