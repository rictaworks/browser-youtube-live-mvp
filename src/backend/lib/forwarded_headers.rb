# 転送ヘッダ（X-Forwarded-*）の隔離（Rack ミドルウェア。issue #7。requirements.md 6.1・28.1・28.2）。
#
# 利用者の IP と公開オリジンは、BFF の確認（X-BFF-Secret）を通った要求の X-Forwarded-For・X-Forwarded-Host・
# X-Forwarded-Proto からだけ読む。確認を通らない要求の転送ヘッダは、読まない。
# これを、規約ではなく構造で守るため、ミドルウェアの先頭で、転送ヘッダを Rack の env から取り除き、別のキー（bl.forwarded_headers）へ
# 移す。移した値を読めるのは、確認を通った要求を作る BffGuard（VerifiedBffRequest）だけ。
#
# 取り除くことで、次も防げる。
#   - Rails の HostAuthorization が、X-Forwarded-Host も許可の一覧と照合し、BFF の要求（公開ドメインが一覧に無い）を拒否すること
#   - request.ip・request.remote_ip・request.host・request.ssl? が、確認の前の転送ヘッダに引きずられること
#   - Rails 標準のログ（Started GET ... for <IP>）が、利用者の IP を出すこと（RequestLogger も、IP を出さない）
class ForwardedHeaders
  # ミドルウェアを通っていない env から読もうとした（設定の不備。黙って生のヘッダを読まない）
  class NotInstalledError < StandardError; end

  # 保管した、転送ヘッダの値（加工しない文字列。または nil）。検証は、読む側（ClientIp・PublicOrigin）が行う。
  # inspect・to_s に値を出さない（env をログ・例外の報告へ出しても、IP が漏れない）。
  Values = Data.define(:forwarded_for, :forwarded_host, :forwarded_proto) do
    def inspect
      "#<#{self.class.name} [FILTERED]>"
    end

    def to_s
      inspect
    end
  end

  ENV_KEY = "bl.forwarded_headers".freeze

  # 取り除く env のキー。Rack・Rails が転送ヘッダとして読むもの（Rack::Request・ActionDispatch::Request・ActionDispatch::SSL）
  STRIPPED_ENV_KEYS = %w[
    HTTP_X_FORWARDED_FOR
    HTTP_X_FORWARDED_HOST
    HTTP_X_FORWARDED_PROTO
    HTTP_X_FORWARDED_SCHEME
    HTTP_X_FORWARDED_SSL
    HTTP_X_FORWARDED_PORT
    HTTP_FORWARDED
    HTTP_CLIENT_IP
  ].freeze

  # 保管した値。ミドルウェアが通っていない env なら、NotInstalledError
  def self.fetch(env)
    env.fetch(ENV_KEY) { raise NotInstalledError, "ForwardedHeaders middleware did not run for this request" }
  end

  def initialize(app)
    @app = app
  end

  def call(env)
    env[ENV_KEY] = Values.new(
      forwarded_for: env["HTTP_X_FORWARDED_FOR"],
      forwarded_host: env["HTTP_X_FORWARDED_HOST"],
      forwarded_proto: env["HTTP_X_FORWARDED_PROTO"]
    )
    STRIPPED_ENV_KEYS.each { |key| env.delete(key) }
    @app.call(env)
  end
end
