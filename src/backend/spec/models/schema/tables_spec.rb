require "rails_helper"
require "support/model_support"
require "support/expected_schema"

# requirements.md 20.1（テーブル一覧）・21 章（ER 図）。15 テーブルの、列・型・NULL 可否・既定値・主キー。
# テスト用 DB は db/structure.sql から作られるので、これは、structure.sql が再現した姿の検査である。
RSpec.describe "DB スキーマ: 15 テーブルの列・型・NULL 可否・主キー（requirements.md 20.1・21 章）" do
  it "20.1 の 15 テーブルだけがある（Rails の内部テーブルを除く）" do
    expect(ExpectedSchema::TABLES.size).to eq(15)
    expect(SchemaInspector.table_names).to match_array(ExpectedSchema::TABLES.keys)
  end

  ExpectedSchema::TABLES.each do |table, expected_columns|
    describe table do
      it "列の名前・型・NULL 可否・既定値は、ER 図のとおり（余分な列も無い）" do
        actual = SchemaInspector.columns(table)

        expect(actual.keys).to match_array(expected_columns.keys), "#{table} の列の名前が ER 図と一致しない"
        aggregate_failures do
          expected_columns.each do |column, expectation|
            expect(actual[column]).to eq(expectation), "#{table}.#{column}: [型, NULL 可, 既定値] が ER 図の期待 #{expectation.inspect} と違う（実際: #{actual[column].inspect}）"
          end
        end
      end

      it "主キーは #{ExpectedSchema::PRIMARY_KEYS.fetch(table)}" do
        expect(SchemaInspector.connection.primary_key(table)).to eq(ExpectedSchema::PRIMARY_KEYS.fetch(table))
      end
    end
  end

  describe "主キー" do
    it "uuid の主キーは、gen_random_uuid() を既定値にする（アプリケーションが採番しない）" do
      uuid_tables = ExpectedSchema::PRIMARY_KEYS.select { |_, key| key == "id" }.keys

      uuid_tables.each do |table|
        column = SchemaInspector.columns(table).fetch("id")
        expect(column).to eq([ "uuid", false, "gen_random_uuid()" ]), "#{table}.id"
      end
      expect(uuid_tables.size).to eq(11)
    end

    it "自然キーのテーブルは、quota_days（日付）・transfer_months（月の文字列）・deletion_holds（要約値）・system_settings（キー）の 4 つ" do
      natural = ExpectedSchema::PRIMARY_KEYS.reject { |_, key| key == "id" }

      expect(natural).to eq(
        "quota_days" => "quota_date",
        "transfer_months" => "month",
        "deletion_holds" => "sub_digest",
        "system_settings" => "key"
      )
    end
  end
end
