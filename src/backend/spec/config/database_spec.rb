require "rails_helper"

# DB を使うスペック。テストが、開発 DB（bl_development）ではなく、テスト用の DB で動いていることを確かめる
RSpec.describe "データベース" do
  let(:connection) { ActiveRecord::Base.connection }

  it "PostgreSQL に接続している" do
    expect(connection.adapter_name).to eq("PostgreSQL")
  end

  it "接続先は、テスト用の名前の DB（既定は bl_test。scripts/test_backend.sh が与える）" do
    database = connection.select_value("SELECT current_database()")

    expect { TestEnvironmentGuard.verify_database_name!(database) }.not_to raise_error
    expect(database).not_to eq("bl_development")
  end

  it "scripts/test_backend.sh が環境変数 TEST_DB_NAME で指定した DB に接続している" do
    expected = ENV.fetch("TEST_DB_NAME", "bl_test")

    expect(connection.select_value("SELECT current_database()")).to eq(expected)
  end

  it "db/structure.sql が読み込まれている（ar_internal_metadata・schema_migrations がある）" do
    expect(connection.table_exists?("schema_migrations")).to be(true)
    expect(connection.table_exists?("ar_internal_metadata")).to be(true)
  end

  it "ar_internal_metadata の環境は test" do
    environment = connection.select_value("SELECT value FROM ar_internal_metadata WHERE key = 'environment'")

    expect(environment).to eq("test")
  end

  it "接続のタイムゾーンは UTC（Rails が設定する）" do
    expect(connection.select_value("SHOW TIME ZONE")).to eq("UTC")
  end
end
