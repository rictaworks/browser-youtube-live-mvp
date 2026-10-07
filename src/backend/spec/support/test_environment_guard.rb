# テストが、開発 DB など、テスト用ではない環境へ向かう事故を防ぐ（ENV/DEVELOPMENT.md の未決事項）。
#
# Rails を読み込む前の spec/rails_helper.rb から呼ぶ。Rails にも DB にも依存しない（素の Ruby）。
# 事故の例:
#   - コンテナに RAILS_ENV=development が設定されたまま、テストが development 環境で走る
#   - DATABASE_URL が開発 DB（bl_development）を指したまま、テストが走り、開発 DB のスキーマを作り直す
# テストの実行は scripts/test_backend.sh を使う（RAILS_ENV=test と、テスト用 DB の DATABASE_URL を明示する）。
module TestEnvironmentGuard
  class UnsafeTestEnvironmentError < StandardError; end

  # テスト用 DB の名前の規則。小文字・数字・アンダースコア（先頭は小文字、63 文字まで）で、"test" を 1 つの語として含む
  # （bl_test・bl_test_issue5・issue5_test など）。開発 DB（bl_development）や既定の DB（postgres）は満たさない。
  TEST_DATABASE_NAME_PATTERN = /\A(?=[a-z][a-z0-9_]{0,62}\z)(?:[a-z0-9_]*_)?test(?:_[a-z0-9_]*)?\z/

  module_function

  # RAILS_ENV が未設定、または test であること。development・production などが設定されていれば、例外にする。
  def verify_rails_env!(environ)
    value = environ["RAILS_ENV"]
    return if value.nil? || value == "test"

    raise UnsafeTestEnvironmentError,
          "RAILS_ENV=#{value} is set, but the specs must run in the test environment. " \
          "Run them through scripts/test_backend.sh (it sets RAILS_ENV=test and the test DATABASE_URL)."
  end

  # 接続先の DB の名前が、テスト用の名前の規則を満たすこと。
  def verify_database_name!(name)
    return if name.is_a?(String) && TEST_DATABASE_NAME_PATTERN.match?(name)

    raise UnsafeTestEnvironmentError,
          "The specs would connect to database #{name.inspect}, which is not a test database name " \
          "(expected lowercase letters, digits and underscores, containing \"test\" as a word, e.g. bl_test). " \
          "Run them through scripts/test_backend.sh (it sets the test DATABASE_URL)."
  end
end
