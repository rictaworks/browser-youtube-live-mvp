# 本番の必須の環境変数の検査（requirements.md 29.4。issue #7）。
# 本番では、アプリケーション層の必須の環境変数が欠けていれば、起動を失敗させる。開発・テストでは検査しない
# （明示した開発用の値・疑似実装を使う。config/app_environment.rb）。
#
# どの名前が欠けているかを、例外に書く。値は書かない（秘密値をログ・例外へ出さない）。
# Rails にも DB にも依存しない（素の Ruby）。config/initializers/required_environment.rb が呼ぶ。
class RequiredEnvironment
  # 欠けている環境変数の名前を持つ。メッセージは、名前だけ
  class MissingError < StandardError
    attr_reader :names

    def initialize(names)
      @names = names.dup.freeze
      super("required environment variables are missing: #{@names.join(', ')}")
    end
  end

  # requirements.md 29.4 の、層が「アプリケーション」の変数（表の順）
  NAMES = %w[
    GOOGLE_CLIENT_ID
    GOOGLE_CLIENT_SECRET
    TOKEN_ENCRYPTION_KEY
    SESSION_SECRET
    RECAPTCHA_SECRET_KEY
    RELAY_SHARED_SECRET
    BFF_SHARED_SECRET
    ADMIN_BASIC_USER
    ADMIN_BASIC_PASSWORD
    DATABASE_URL
    RELAY_PUBLIC_URL
  ].freeze

  # environment は AppEnvironment。environ は ENV（または、名前 => 値の Hash）。
  # 本番で、必須の変数が未設定・空・空白だけなら、MissingError。それ以外の環境では、何もしない。
  def self.verify!(environment, environ = ENV)
    return unless environment.production?

    missing = NAMES.select { |name| environ[name].to_s.strip.empty? }
    raise MissingError, missing unless missing.empty?
  end
end
