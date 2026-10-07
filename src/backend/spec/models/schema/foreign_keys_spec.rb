require "rails_helper"
require "support/model_support"

# requirements.md 7.4（削除時の紐づけの外し方）・14 章・21 章。外部キーと、削除時の動作。
#   - users の削除で、sessions・youtube_connections・broadcasts・daily_usages・relay_tickets・health_samples・broadcast_events を連鎖して削除する
#   - usage_events.user_id と quota_entries.broadcast_id は、削除時に NULL にする（アカウント・配信との紐づけを外し、行は残す）
#   - broadcasts.daily_usage_id は、daily_usages への参照（既定の動作。参照されている間は、削除できない）
# モデルに dependent は置かない。削除は、DB の外部キーが行う（アプリケーションの削除の順序に依存しない）。
RSpec.describe "外部キーと削除時の動作（requirements.md 7.4・14 章・21 章）" do
  # [ 子のテーブル, 列, 親のテーブル, 親の列, 親の削除時の動作 ]。nil は、既定（参照されている間は、親を削除できない）
  expected_foreign_keys = [
    [ "sessions", "user_id", "users", "id", :cascade ],
    [ "youtube_connections", "user_id", "users", "id", :cascade ],
    [ "broadcasts", "user_id", "users", "id", :cascade ],
    [ "broadcasts", "daily_usage_id", "daily_usages", "id", nil ],
    [ "daily_usages", "user_id", "users", "id", :cascade ],
    [ "relay_tickets", "user_id", "users", "id", :cascade ],
    [ "relay_tickets", "broadcast_id", "broadcasts", "id", :cascade ],
    [ "health_samples", "user_id", "users", "id", :cascade ],
    [ "health_samples", "broadcast_id", "broadcasts", "id", :cascade ],
    [ "broadcast_events", "user_id", "users", "id", :cascade ],
    [ "broadcast_events", "broadcast_id", "broadcasts", "id", :cascade ],
    [ "usage_events", "user_id", "users", "id", :nullify ],
    [ "quota_entries", "quota_date", "quota_days", "quota_date", nil ],
    [ "quota_entries", "broadcast_id", "broadcasts", "id", :nullify ]
  ]

  it "外部キーは、表のとおり 14 本（これ以外の外部キーは無い）" do
    actual = SchemaInspector.table_names.flat_map do |table|
      SchemaInspector.connection.foreign_keys(table).map do |key|
        [ key.from_table, key.column, key.to_table, key.primary_key, key.on_delete ]
      end
    end

    expect(expected_foreign_keys.size).to eq(14)
    expect(actual).to match_array(expected_foreign_keys)
  end

  it "外部キーの名前は fk_<テーブル>_<列>（structure.sql で名前が安定する）" do
    names = SchemaInspector.table_names.flat_map { |table| SchemaInspector.connection.foreign_keys(table).map(&:name) }

    expect(names).to match_array(expected_foreign_keys.map { |table, column, *| "fk_#{table}_#{column}" })
  end

  describe "参照先の無い行を拒否する" do
    dangling = {
      "sessions.user_id" => -> { build(:session, user: nil).tap { |record| record.user_id = SecureRandom.uuid } },
      "youtube_connections.user_id" => -> { build(:youtube_connection, user: nil).tap { |record| record.user_id = SecureRandom.uuid } },
      "broadcasts.user_id" => -> { build(:broadcast, user: nil, daily_usage: create(:daily_usage)).tap { |record| record.user_id = SecureRandom.uuid } },
      "broadcasts.daily_usage_id" => lambda {
        build(:broadcast, user: create(:user), daily_usage: nil, usage_date: Date.new(2026, 10, 7)).tap { |record| record.daily_usage_id = SecureRandom.uuid }
      },
      "daily_usages.user_id" => -> { build(:daily_usage, user: nil).tap { |record| record.user_id = SecureRandom.uuid } },
      "relay_tickets.user_id" => -> { build(:relay_ticket, user: nil, broadcast: create(:broadcast)).tap { |record| record.user_id = SecureRandom.uuid } },
      "relay_tickets.broadcast_id" => -> { build(:relay_ticket, user: create(:user), broadcast: nil).tap { |record| record.broadcast_id = SecureRandom.uuid } },
      "health_samples.user_id" => -> { build(:health_sample, user: nil, broadcast: create(:broadcast)).tap { |record| record.user_id = SecureRandom.uuid } },
      "health_samples.broadcast_id" => -> { build(:health_sample, user: create(:user), broadcast: nil).tap { |record| record.broadcast_id = SecureRandom.uuid } },
      "broadcast_events.user_id" => -> { build(:broadcast_event, user: nil, broadcast: create(:broadcast)).tap { |record| record.user_id = SecureRandom.uuid } },
      "broadcast_events.broadcast_id" => -> { build(:broadcast_event, user: create(:user), broadcast: nil).tap { |record| record.broadcast_id = SecureRandom.uuid } },
      "usage_events.user_id" => -> { build(:usage_event, :detached).tap { |record| record.user_id = SecureRandom.uuid } },
      "quota_entries.quota_date" => -> { build(:quota_entry, quota_day: nil).tap { |record| record.quota_date = Date.new(2099, 12, 31) } },
      "quota_entries.broadcast_id" => -> { build(:quota_entry).tap { |record| record.broadcast_id = SecureRandom.uuid } }
    }

    it "14 本の外部キーのすべてを、検査する" do
      expect(dangling.keys).to match_array(expected_foreign_keys.map { |table, column, *| "#{table}.#{column}" })
    end

    dangling.each do |key, builder|
      it "#{key}: 存在しない親を指す行を拒否する" do
        record = instance_exec(&builder)

        expect_db_violation(ActiveRecord::InvalidForeignKey) { save_without_validation!(record) }
      end
    end
  end

  describe "アカウントの削除（users の削除）" do
    # users の削除を、アプリケーションの経路と、DB への直接の文の 2 通りで確かめる（どちらも、DB の外部キーが連鎖させる）
    {
      "ActiveRecord の destroy!" => ->(user) { user.destroy! },
      "DB への直接の削除（delete_all）" => ->(user) { User.where(id: user.id).delete_all }
    }.each do |label, remover|
      context "#{label}" do
        let!(:account) { create(:user) }
        let!(:other) { create(:user) }
        let!(:records) { create_account_records(account) }
        let!(:other_records) { create_account_records(other) }

        before { remover.call(account) }

        it "sessions・youtube_connections・broadcasts・daily_usages・relay_tickets・health_samples・broadcast_events を連鎖して削除する" do
          %i[ session youtube_connection daily_usage broadcast relay_ticket health_sample broadcast_event ].each do |key|
            record = records.fetch(key)
            expect(record.class.exists?(record.id)).to be(false), "#{key} が残っている"
          end
        end

        it "usage_events は、アカウントとの紐づけを外して残す（user_id が NULL になる）" do
          event = UsageEvent.find(records.fetch(:usage_event).id)

          expect(event.user_id).to be_nil
        end

        it "quota_entries は、配信との紐づけを外して残す（broadcast_id が NULL になる）。台帳（quota_days）は残る" do
          entry = QuotaEntry.find(records.fetch(:quota_entry).id)

          expect(entry.broadcast_id).to be_nil
          expect(QuotaDay.exists?(entry.quota_date)).to be(true)
        end

        it "他のアカウントのレコードには、何も起きない" do
          other_records.each do |key, record|
            expect(record.class.exists?(record.id)).to be(true), "他のアカウントの #{key} が消えた"
          end
          expect(UsageEvent.find(other_records.fetch(:usage_event).id).user_id).to eq(other.id)
          expect(QuotaEntry.find(other_records.fetch(:quota_entry).id).broadcast_id).to eq(other_records.fetch(:broadcast).id)
        end

        it "アカウントに紐づくレコードが、利用者に属する 8 テーブルのどこにも残らない（usage_events は紐づけが外れる）" do
          %w[ sessions youtube_connections broadcasts daily_usages relay_tickets health_samples broadcast_events usage_events ].each do |table|
            count = SchemaInspector.connection.select_value("SELECT count(*) FROM #{table} WHERE user_id = #{SchemaInspector.connection.quote(account.id)}")
            expect(count).to eq(0), "#{table} に、削除したアカウントの行が残っている"
          end
        end
      end
    end
  end

  describe "配信の削除（broadcasts の削除）" do
    it "接続チケット・健全性の標本・配信の出来事を連鎖して削除し、台帳の明細は、配信との紐づけを外して残す" do
      user = create(:user)
      records = create_account_records(user)

      records.fetch(:broadcast).destroy!

      expect(RelayTicket.exists?(records.fetch(:relay_ticket).id)).to be(false)
      expect(HealthSample.exists?(records.fetch(:health_sample).id)).to be(false)
      expect(BroadcastEvent.exists?(records.fetch(:broadcast_event).id)).to be(false)
      expect(QuotaEntry.find(records.fetch(:quota_entry).id).broadcast_id).to be_nil
      expect(DailyUsage.exists?(records.fetch(:daily_usage).id)).to be(true)
      expect(User.exists?(user.id)).to be(true)
    end
  end

  describe "参照されている親の削除（既定の動作）" do
    it "配信が参照している利用実績（daily_usages）は、削除できない" do
      records = create_account_records(create(:user))

      expect_db_violation(ActiveRecord::InvalidForeignKey) { records.fetch(:daily_usage).destroy! }
      expect(DailyUsage.exists?(records.fetch(:daily_usage).id)).to be(true)
    end

    it "台帳の明細が参照している割り当て日（quota_days）は、削除できない" do
      entry = create(:quota_entry)

      expect_db_violation(ActiveRecord::InvalidForeignKey) { entry.quota_day.destroy! }
      expect(QuotaDay.exists?(entry.quota_date)).to be(true)
    end
  end
end
