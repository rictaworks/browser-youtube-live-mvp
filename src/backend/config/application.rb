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

module Backend
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # 時刻は JST。DB へは UTC で保存する（Rails の既定）
    config.time_zone = "Tokyo"

    # スキーマは SQL（db/structure.sql）で管理する。部分一意索引・CHECK 制約を保持するため。
    # pg_dump・psql が要る（Dockerfile の postgresql-client）。
    config.active_record.schema_format = :sql

    # セッションの署名鍵は、環境変数 SESSION_SECRET から与える（requirements.md 29.4）。
    # 本番は未設定なら起動を失敗させる。開発・テストは明示した開発用の値（AppEnvironment）。
    # credentials（config/master.key・credentials.yml.enc）は使わない（requirements.md 28.1）。
    config.secret_key_base = AppEnvironment.current.session_secret(ENV)

    # Don't generate system test files.
    config.generators.system_tests = nil
  end
end
