# 環境の判定。Rails.env の値を、このアプリケーションが扱う 3 つの環境（development・test・production）へ対応づける。
# 未知の値は、既定の環境へ倒さず、例外にする。
#
# Rails にも DB にも依存しない（素の Ruby）。config/application.rb が、Rails の初期化の前に読み込む。
class AppEnvironment
  class UnknownEnvironmentError < StandardError; end
  class InvalidSecretError < StandardError; end

  NAMES = %i[ development test production ].freeze

  # 外部サービス（Google・YouTube・reCAPTCHA など）の実装の選択。
  # 開発・テストは疑似実装（:fake）、本番は実際の実装（:live）を使う（実際の外部サービスを、開発・テストでは呼ばない）。
  EXTERNAL_SERVICES = {
    development: :fake,
    test: :fake,
    production: :live
  }.freeze

  SESSION_SECRET_KEY = "SESSION_SECRET".freeze

  # 開発・テストで SESSION_SECRET が未設定のときだけ使う、明示した開発用の値。リポジトリに公開されている値なので、
  # 本番では使わせない（session_secret が例外にする）。
  DEVELOPMENT_SESSION_SECRET =
    "development-only-session-secret-published-in-the-repository-never-use-in-production-0123456789abcdef".freeze

  def self.current
    new(Rails.env)
  end

  attr_reader :name

  def initialize(name)
    symbol = name.to_s.to_sym
    unless NAMES.include?(symbol)
      raise UnknownEnvironmentError, "unknown environment #{name.inspect} (expected one of: #{NAMES.join(', ')})"
    end

    @name = symbol
  end

  def development? = name == :development
  def test? = name == :test
  def production? = name == :production

  def external_services
    EXTERNAL_SERVICES.fetch(name)
  end

  # Rails の secret_key_base（セッションの署名鍵）に使う値。環境変数 SESSION_SECRET から与える（requirements.md 29.4）。
  #   本番            未設定・空、または公開されている開発用の値なら、例外にして起動を失敗させる
  #   開発・テスト    未設定・空なら、明示した開発用の値を使う
  def session_secret(environ)
    value = environ[SESSION_SECRET_KEY].to_s

    if value.strip.empty?
      raise InvalidSecretError, "#{SESSION_SECRET_KEY} is required in production" if production?

      return DEVELOPMENT_SESSION_SECRET
    end

    if production? && value == DEVELOPMENT_SESSION_SECRET
      raise InvalidSecretError, "#{SESSION_SECRET_KEY} must not be the published development value in production"
    end

    value
  end
end
