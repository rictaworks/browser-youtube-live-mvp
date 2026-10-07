require "rails_helper"
require "support/model_support"
require "support/expected_schema"

# db/structure.sql の検査。部分一意索引・CHECK 制約・外部キーが、structure.sql に保存されていること。
# テスト用 DB は、この structure.sql を db:prepare（db:schema:load）で読み込んで作る。したがって、
#   - ここで検査するファイルの内容と、他のスペックが検査する DB の姿は、同じものから来ている
#   - structure.sql に保存されていなければ、テスト用 DB に再現されず、他のスペックが失敗する
# マイグレーションを足したあとは、開発 DB で bin/rails db:migrate を実行し、structure.sql を更新してコミットする。
RSpec.describe "db/structure.sql（部分一意索引・CHECK 制約・外部キーの保存と再現）" do
  structure_path = Rails.root.join("db/structure.sql")

  let(:structure) { File.read(structure_path, encoding: "UTF-8") }

  it "structure.sql がある（スキーマの形式は SQL。config.active_record.schema_format = :sql）" do
    expect(Rails.application.config.active_record.schema_format).to eq(:sql)
    expect(structure_path).to exist
  end

  it "15 テーブルの CREATE TABLE がある" do
    created = structure.scan(/^CREATE TABLE public\.(\w+) \(/).flatten - SchemaInspector::INTERNAL_TABLES

    expect(created).to match_array(ExpectedSchema::TABLES.keys)
  end

  it "uuid の主キーは、gen_random_uuid() を既定値にして保存されている" do
    expect(structure.scan("DEFAULT gen_random_uuid() NOT NULL").size).to eq(11)
  end

  it "部分一意索引（終了していない配信は、アカウントにつき 1 件まで）が保存されている" do
    expect(structure).to match(
      /^CREATE UNIQUE INDEX idx_broadcasts_one_unended_per_user ON public\.broadcasts USING btree \(user_id\) WHERE \(\(state\)::text <> 'ended'::text\);$/
    )
  end

  it "一意索引が保存されている（users.google_sub・sessions.token_digest・youtube_connections.user_id・daily_usages (user_id, usage_date)・relay_tickets.token_digest）" do
    [
      /CREATE UNIQUE INDEX \w+ ON public\.users USING btree \(google_sub\);/,
      /CREATE UNIQUE INDEX \w+ ON public\.sessions USING btree \(token_digest\);/,
      /CREATE UNIQUE INDEX \w+ ON public\.youtube_connections USING btree \(user_id\);/,
      /CREATE UNIQUE INDEX \w+ ON public\.daily_usages USING btree \(user_id, usage_date\);/,
      /CREATE UNIQUE INDEX \w+ ON public\.relay_tickets USING btree \(token_digest\);/
    ].each { |pattern| expect(structure).to match(pattern) }
  end

  it "DB にあるすべての CHECK 制約が、structure.sql に保存されている（名前で突き合わせる）" do
    in_database = ExpectedSchema::TABLES.keys.flat_map { |table| SchemaInspector.check_constraints(table).keys }
    in_file = structure.scan(/CONSTRAINT (chk_\w+) CHECK/).flatten

    expect(in_database).not_to be_empty
    expect(in_file).to match_array(in_database)
  end

  it "列挙の CHECK 制約 10 本・件数と量の CHECK 制約・月の形の CHECK 制約・タイトルの寿命の CHECK 制約が、structure.sql にある" do
    enumerations = %w[
      chk_broadcasts_state chk_broadcasts_end_reason chk_broadcasts_settlement_state chk_broadcasts_profile chk_broadcasts_privacy_status
      chk_youtube_connections_state chk_broadcast_events_event_type chk_usage_events_event_type
      chk_quota_entries_bucket chk_quota_entries_result
    ]
    others = %w[ chk_transfer_months_month_format chk_broadcasts_pending_title_lifecycle chk_quota_days_used_units_non_negative chk_quota_days_reserved_units_non_negative ]

    (enumerations + others).each do |name|
      expect(structure).to match(/CONSTRAINT #{name} CHECK/), "#{name} が structure.sql に無い"
    end
  end

  it "DB にあるすべての外部キーが、削除時の動作つきで、structure.sql に保存されている" do
    in_database = ExpectedSchema::TABLES.keys.flat_map { |table| SchemaInspector.connection.foreign_keys(table).map(&:name) }
    in_file = structure.scan(/ADD CONSTRAINT (fk_\w+) FOREIGN KEY/).flatten

    expect(in_file).to match_array(in_database)
    expect(structure.scan("ON DELETE CASCADE").size).to eq(10)
    expect(structure.scan("ON DELETE SET NULL").size).to eq(2)
  end

  it "db/migrate のすべてのマイグレーションの版が、structure.sql の schema_migrations に入っている（migrate のあとに structure.sql を更新した）" do
    versions = Dir[Rails.root.join("db/migrate/*.rb").to_s].map { |path| File.basename(path)[/\A\d+/] }

    expect(versions).not_to be_empty
    versions.each do |version|
      expect(structure).to include("('#{version}')"), "マイグレーション #{version} が structure.sql に記録されていない"
    end
  end

  it "テスト用 DB の schema_migrations は、db/migrate のすべての版を含む（db:schema:load が structure.sql から再現した）" do
    in_database = SchemaInspector.connection.select_values("SELECT version FROM schema_migrations")
    in_files = Dir[Rails.root.join("db/migrate/*.rb").to_s].map { |path| File.basename(path)[/\A\d+/] }

    expect(in_database).to include(*in_files)
  end
end
