require "rails_helper"
require "support/model_support"
require "support/expected_schema"

# 15 テーブルのモデルと、その関連（requirements.md 21 章の ER 図の関係線）。
RSpec.describe "モデルと関連（requirements.md 21 章）" do
  it "15 テーブルのそれぞれに、ActiveRecord のモデルが 1 つずつある（余分なモデルも無い）" do
    Rails.autoloaders.main.eager_load_dir(Rails.root.join("app/models").to_s)
    models = ApplicationRecord.descendants.select(&:name).reject(&:abstract_class?)

    expect(models.map(&:table_name)).to match_array(ExpectedSchema::TABLES.keys)
    expect(models.map(&:name)).to match_array(
      %w[ User Session YoutubeConnection Broadcast DailyUsage RelayTicket HealthSample BroadcastEvent UsageEvent QuotaDay QuotaEntry TransferMonth DeletionHold SystemSetting AdminAction ]
    )
  end

  it "主キーは、テーブルの主キー（自然キーのテーブルは、その列）" do
    ExpectedSchema::PRIMARY_KEYS.each do |table, key|
      expect(table.classify.constantize.primary_key).to eq(key), "#{table} の主キー"
    end
  end

  describe "関連の定義（ER 図の関係線）" do
    # [ モデル, 関連の名前, 種類, 相手のモデル ]
    expected = [
      [ User, :sessions, :has_many, Session ],
      [ User, :youtube_connection, :has_one, YoutubeConnection ],
      [ User, :broadcasts, :has_many, Broadcast ],
      [ User, :daily_usages, :has_many, DailyUsage ],
      [ User, :relay_tickets, :has_many, RelayTicket ],
      [ User, :health_samples, :has_many, HealthSample ],
      [ User, :broadcast_events, :has_many, BroadcastEvent ],
      [ User, :usage_events, :has_many, UsageEvent ],
      [ Session, :user, :belongs_to, User ],
      [ YoutubeConnection, :user, :belongs_to, User ],
      [ Broadcast, :user, :belongs_to, User ],
      [ Broadcast, :daily_usage, :belongs_to, DailyUsage ],
      [ Broadcast, :relay_tickets, :has_many, RelayTicket ],
      [ Broadcast, :health_samples, :has_many, HealthSample ],
      [ Broadcast, :broadcast_events, :has_many, BroadcastEvent ],
      [ Broadcast, :quota_entries, :has_many, QuotaEntry ],
      [ DailyUsage, :user, :belongs_to, User ],
      [ DailyUsage, :broadcasts, :has_many, Broadcast ],
      [ RelayTicket, :user, :belongs_to, User ],
      [ RelayTicket, :broadcast, :belongs_to, Broadcast ],
      [ HealthSample, :user, :belongs_to, User ],
      [ HealthSample, :broadcast, :belongs_to, Broadcast ],
      [ BroadcastEvent, :user, :belongs_to, User ],
      [ BroadcastEvent, :broadcast, :belongs_to, Broadcast ],
      [ UsageEvent, :user, :belongs_to, User ],
      [ QuotaDay, :quota_entries, :has_many, QuotaEntry ],
      [ QuotaEntry, :quota_day, :belongs_to, QuotaDay ],
      [ QuotaEntry, :broadcast, :belongs_to, Broadcast ]
    ]

    expected.each do |model, name, macro, target|
      it "#{model}.#{name}（#{macro}）は、#{target} を指す" do
        reflection = model.reflect_on_association(name)

        expect(reflection).not_to be_nil, "#{model} に関連 #{name} が無い"
        expect(reflection.macro).to eq(macro)
        expect(reflection.klass).to eq(target)
      end
    end

    it "削除は DB の外部キーに任せる（has_many・has_one に dependent を置かない。連鎖の順序をアプリケーションに持たせない）" do
      expected.select { |_, _, macro, _| %i[ has_many has_one ].include?(macro) }.each do |model, name, _, _|
        expect(model.reflect_on_association(name).options).not_to have_key(:dependent), "#{model}.#{name} に dependent がある"
      end
    end

    it "usage_events.user と quota_entries.broadcast は、任意（アカウント・配信との紐づけを外すことがある。7.4）" do
      expect(UsageEvent.reflect_on_association(:user).options[:optional]).to be(true)
      expect(QuotaEntry.reflect_on_association(:broadcast).options[:optional]).to be(true)
    end

    it "quota_entries.quota_day は、割り当て日（quota_date 列）で結ぶ" do
      reflection = QuotaEntry.reflect_on_association(:quota_day)

      expect(reflection.foreign_key).to eq("quota_date")
      expect(reflection.association_primary_key).to eq("quota_date")
    end
  end

  describe "関連をたどる（2 つのアカウントのレコードが、混ざらない）" do
    it "アカウントから、自分のレコードだけがたどれる" do
      user = create(:user)
      other = create(:user)
      records = create_account_records(user)
      create_account_records(other)

      expect(user.sessions).to eq([ records.fetch(:session) ])
      expect(user.youtube_connection).to eq(records.fetch(:youtube_connection))
      expect(user.broadcasts).to eq([ records.fetch(:broadcast) ])
      expect(user.daily_usages).to eq([ records.fetch(:daily_usage) ])
      expect(user.relay_tickets).to eq([ records.fetch(:relay_ticket) ])
      expect(user.health_samples).to eq([ records.fetch(:health_sample) ])
      expect(user.broadcast_events).to eq([ records.fetch(:broadcast_event) ])
      expect(user.usage_events).to eq([ records.fetch(:usage_event) ])
    end

    it "割り当て日から、台帳の明細がたどれる" do
      entry = create(:quota_entry)

      expect(entry.quota_day.quota_entries).to eq([ entry ])
    end
  end
end
