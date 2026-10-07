require "rails_helper"
require "support/model_support"
require "support/expected_schema"

# requirements.md 14 章・20.1 の「アカウント識別子」欄。
# 「利用者に属するテーブルは、すべてアカウントの識別子（user_id）を持つ」ことを、information_schema を走査して検査する。
# 新しいテーブルが増えたとき、分類（spec/support/expected_schema.rb）の更新を強制する。
RSpec.describe "アカウント識別子（user_id）を持つテーブル（requirements.md 14 章・20.1）" do
  classified = [
    ExpectedSchema::ACCOUNT_TABLE,
    *ExpectedSchema::USER_OWNED_TABLES,
    *ExpectedSchema::SYSTEM_WIDE_TABLES,
    *ExpectedSchema::WITHOUT_ACCOUNT_ID_TABLES
  ]

  it "分類の表は、15 テーブルを、ちょうど 1 回ずつ含む" do
    expect(classified.size).to eq(15)
    expect(classified).to match_array(ExpectedSchema::TABLES.keys)
  end

  it "information_schema の、すべてのテーブルが、20.1 の分類のいずれかに入っている（未分類のテーブルが無い）" do
    unclassified = SchemaInspector.table_names - classified

    expect(unclassified).to be_empty,
      "分類されていないテーブル: #{unclassified.join(', ')}。利用者に属するテーブルなら user_id を持たせ、" \
      "spec/support/expected_schema.rb の分類（USER_OWNED_TABLES など）へ足してください（20.1 の「アカウント識別子」欄）"
  end

  describe "利用者に属するテーブル" do
    ExpectedSchema::USER_OWNED_TABLES.each do |table|
      nullable = ExpectedSchema::NULLABLE_USER_ID_TABLES.include?(table)

      it "#{table} は、user_id（uuid）を持つ。#{nullable ? 'NULL 可（アカウントの削除時に外すため）' : 'NOT NULL'}" do
        column = SchemaInspector.information_schema_columns(table)["user_id"]

        expect(column).not_to be_nil, "#{table} に user_id が無い（利用者に属するテーブルは、アカウントの識別子を持つ。14 章）"
        expect(column[:data_type]).to eq("uuid")
        expect(column[:nullable]).to eq(nullable)
      end
    end

    it "user_id が NULL 可なのは、usage_events だけ" do
      nullable_tables = ExpectedSchema::USER_OWNED_TABLES.select do |table|
        SchemaInspector.information_schema_columns(table).fetch("user_id")[:nullable]
      end

      expect(nullable_tables).to eq(%w[ usage_events ])
    end
  end

  describe "利用者に属さないテーブル" do
    it "users は、user_id を持たない（主キーの id が、アカウントの識別子）" do
      expect(SchemaInspector.information_schema_columns("users")).not_to have_key("user_id")
    end

    (ExpectedSchema::SYSTEM_WIDE_TABLES + ExpectedSchema::WITHOUT_ACCOUNT_ID_TABLES).each do |table|
      it "#{table} は、user_id を持たない（20.1：システム全体、または保持しない）" do
        expect(SchemaInspector.information_schema_columns(table)).not_to have_key("user_id")
      end
    end
  end

  it "user_id を持つテーブルは、利用者に属するテーブルだけ（走査の結果が、分類と一致する）" do
    expect(SchemaInspector.tables_with_column("user_id")).to match_array(ExpectedSchema::USER_OWNED_TABLES)
  end
end
