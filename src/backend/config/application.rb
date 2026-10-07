require_relative "boot"

require "rails"
# 使うフレームワークだけを読み込む。Action Cable・Active Storage・Action Mailer・Action Mailbox・Action Text は使わない
# （requirements.md 2.3。標準モードのため、管理画面のビューに action_view を使う）。
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# 環境の判定。Rails の初期化の前に読み込む（secret_key_base の決定に使う）
require_relative "app_environment"
# 口の番号（公開側・内部側）・許可するホスト・本番の必須の環境変数。素の Ruby で、Rails の初期化の前に読み込む
require_relative "server_ports"
require_relative "allowed_hosts"
require_relative "required_environment"

module Backend
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # lib/ は、Rack ミドルウェア・ルーティングの制約など、アプリケーションの基盤を置く場所（issue #7）。
    # ミドルウェアは、起動の時点（config/initializers）で、クラスとして参照するため、再読み込みしない（autoload_lib_once）。
    # 変更したら、サーバーを再起動する（scripts/dc.sh restart backend）。
    config.autoload_lib_once(ignore: %w[assets tasks])

    # 時刻は JST。DB へは UTC で保存する（Rails の既定）
    config.time_zone = "Tokyo"

    # スキーマは SQL（db/structure.sql）で管理する。部分一意索引・CHECK 制約を保持するため。
    # pg_dump・psql が要る（Dockerfile の postgresql-client）。
    config.active_record.schema_format = :sql

    # セッションの署名鍵は、環境変数 SESSION_SECRET から与える（requirements.md 29.4）。
    # 本番は未設定なら起動を失敗させる。開発・テストは明示した開発用の値（AppEnvironment）。
    # credentials（config/master.key・credentials.yml.enc）は使わない（requirements.md 28.1）。
    config.secret_key_base = AppEnvironment.current.session_secret(ENV)

    # ホストの許可（DNS rebinding の防止）。環境ごとの一覧は config/allowed_hosts.rb（開発は localhost・backend、
    # 本番は *.up.railway.app・*.railway.internal。テストは制限しない）。ヘルスチェック（/up）は、検査の対象外。
    # 拒否の応答は JSON（HostRejectedApp）。lib/ のクラスは、起動の時点では読み込めないので、要求のときに参照する。
    config.hosts = AllowedHosts.for(AppEnvironment.current.name).dup
    config.host_authorization = {
      exclude: ->(request) { AllowedHosts.health_check?(request) },
      response_app: ->(env) { HostRejectedApp.call(env) }
    }

    # Don't generate system test files.
    config.generators.system_tests = nil
  end
end
