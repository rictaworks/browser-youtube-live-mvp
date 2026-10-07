# Rails と DB を使うスペックの設定。Rails・DB を使わないスペックは、spec_helper だけを読み込む。
require "spec_helper"
require_relative "support/test_environment_guard"

# Rails を読み込む前に、環境を確かめる。development が指定されたまま、テストが走る事故を防ぐ。
TestEnvironmentGuard.verify_rails_env!(ENV)
ENV["RAILS_ENV"] = "test"

require_relative "../config/environment"

# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?

require "rspec/rails"

# 接続先がテスト用の DB であることを、スキーマの更新（maintain_test_schema!）の前に確かめる。
# DATABASE_URL が開発 DB を指したままだと、maintain_test_schema! が開発 DB のスキーマを作り直してしまう。
TestEnvironmentGuard.verify_database_name!(ActiveRecord::Base.configurations.find_db_config("test").database)

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
end
