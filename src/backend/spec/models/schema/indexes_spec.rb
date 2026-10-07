require "rails_helper"
require "support/model_support"
require "support/expected_schema"

# 索引の検査。一意制約（20.2）の索引と、期限監視（#15）・保持期間の適用（20.3）・所有権の絞り込み（14 章）が引く列の索引。
# 余分な索引（重複・取り残し）も失敗にする（テーブルごとに、索引の集合が、下の表と一致すること）。
RSpec.describe "索引（requirements.md 20.2・20.3・14 章）" do
  # [ 列, 一意か, 部分索引か（部分索引なら :partial、そうでなければ nil） ]。主キーの索引は含めない。部分索引の条件は、下の専用の例で検査する
  expected_indexes = {
    "users" => [ [ %w[ google_sub ], true, nil ] ],
    "sessions" => [ [ %w[ token_digest ], true, nil ], [ %w[ user_id ], false, nil ], [ %w[ expires_at ], false, nil ] ],
    "youtube_connections" => [ [ %w[ user_id ], true, nil ] ],
    "broadcasts" => [
      [ %w[ user_id ], true, :partial ],
      [ %w[ state accepted_at ], false, nil ],
      [ %w[ settlement_state ], false, nil ],
      [ %w[ ended_at ], false, nil ],
      [ %w[ user_id accepted_at ], false, nil ],
      [ %w[ daily_usage_id ], false, nil ]
    ],
    "daily_usages" => [ [ %w[ user_id usage_date ], true, nil ] ],
    "relay_tickets" => [ [ %w[ token_digest ], true, nil ], [ %w[ expires_at ], false, nil ], [ %w[ broadcast_id ], false, nil ], [ %w[ user_id ], false, nil ] ],
    "health_samples" => [ [ %w[ sampled_at ], false, nil ], [ %w[ broadcast_id sampled_at ], false, nil ], [ %w[ user_id ], false, nil ] ],
    "broadcast_events" => [ [ %w[ occurred_at ], false, nil ], [ %w[ broadcast_id occurred_at ], false, nil ], [ %w[ user_id ], false, nil ] ],
    "usage_events" => [ [ %w[ user_id ], false, nil ] ],
    "quota_days" => [],
    "quota_entries" => [ [ %w[ quota_date ], false, nil ], [ %w[ broadcast_id ], false, nil ] ],
    "transfer_months" => [],
    "deletion_holds" => [],
    "system_settings" => [],
    "admin_actions" => [ [ %w[ occurred_at ], false, nil ] ]
  }

  def actual_indexes(table)
    SchemaInspector.connection.indexes(table).map do |index|
      [ index.columns, index.unique, (index.where ? :partial : nil) ]
    end
  end

  it "15 テーブルのすべてについて、期待する索引の表がある" do
    expect(expected_indexes.keys).to match_array(ExpectedSchema::TABLES.keys)
  end

  expected_indexes.each do |table, indexes|
    it "#{table} の索引（主キーを除く）は、表のとおり" do
      expect(actual_indexes(table)).to match_array(indexes)
    end
  end

  describe "期限監視・保持期間の適用が引く列（issue #4 の受け入れ条件）" do
    # [ テーブル, 先頭の列 ]。複合索引は、先頭の列が合っていればよい（broadcasts (state, ...)）
    queried_columns = [
      [ "broadcasts", "state" ], [ "broadcasts", "settlement_state" ], [ "broadcasts", "ended_at" ],
      [ "relay_tickets", "expires_at" ], [ "health_samples", "sampled_at" ], [ "broadcast_events", "occurred_at" ],
      [ "sessions", "expires_at" ], [ "quota_entries", "quota_date" ]
    ]

    queried_columns.each do |table, column|
      it "#{table} は、#{column} で始まる索引を持つ" do
        expect(actual_indexes(table).map { |columns, _, _| columns.first }).to include(column)
      end
    end
  end

  it "部分一意索引 idx_broadcasts_one_unended_per_user は、終了していない行だけを対象にする（state <> 'ended'）" do
    index = SchemaInspector.connection.indexes("broadcasts").find { |candidate| candidate.name == "idx_broadcasts_one_unended_per_user" }

    expect(index).not_to be_nil
    expect(index.unique).to be(true)
    expect(index.columns).to eq(%w[ user_id ])
    expect(index.where).to match(/state.*<>.*'ended'/)
  end
end
