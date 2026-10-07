require "digest"

# フロントエンド（BFF）からの要求であることの確認（issue #7。requirements.md 6.1・28.1。src/contracts/http-api.md 1.2）。
#
# X-BFF-Secret（環境変数 BFF_SHARED_SECRET）を、定数時間で比較する。欠落・不一致は Rejected（呼び出し側が 403 forbidden にする。
# 本文に手がかりを書かない）。比較の前に、両方を SHA-256 で同じ長さにして、長さの違いが、比較の経路・時間に出ないようにする。
# 秘密値が未設定・空なら、NotConfiguredError（空の秘密値と、空のヘッダが一致して、すべての要求が通る事故を防ぐ。設定の不備として、500）。
# 秘密値・提示された値を、例外のメッセージ・ログへ出さない。
#
# 確認を通った要求（VerifiedBffRequest）だけが、転送ヘッダ（利用者の IP・公開オリジン）を読める。
class BffGuard
  ENV_NAME = "BFF_SHARED_SECRET".freeze

  # 秘密値が欠落・不一致。メッセージに、秘密値・提示された値を含めない
  class Rejected < StandardError
    def initialize(message = "BFF secret was rejected")
      super
    end
  end

  # サーバー側の秘密値が未設定・空（設定の不備）
  class NotConfiguredError < StandardError; end

  # 環境変数 BFF_SHARED_SECRET から作る。要求のたびに作る（読み直すので、秘密値のローテーションに、再起動が要らない）
  def self.from_environment(environ = ENV)
    new(secret: environ[ENV_NAME])
  end

  def initialize(secret:)
    raise NotConfiguredError, "#{ENV_NAME} is not set" unless secret.is_a?(String) && !secret.strip.empty?

    @secret_digest = Digest::SHA256.digest(secret)
  end

  # 秘密値が一致すれば、確認を通った要求を返す。forwarded は、保管された転送ヘッダ（ForwardedHeaders::Values）。
  # 一致しなければ Rejected（転送ヘッダを、読まない）。
  def verify!(presented, forwarded)
    raise Rejected unless matches?(presented)

    VerifiedBffRequest.new(forwarded)
  end

  def inspect
    "#<#{self.class.name} [FILTERED]>"
  end

  private

  def matches?(presented)
    return false unless presented.is_a?(String)

    ActiveSupport::SecurityUtils.fixed_length_secure_compare(Digest::SHA256.digest(presented), @secret_digest)
  end
end
