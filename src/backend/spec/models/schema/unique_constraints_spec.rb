require "rails_helper"
require "support/model_support"

# requirements.md 20.2（制約）・14 章（排他制御）。一意制約・主キー・部分一意索引を、DB が拒否することの検査。
# 検証（validates）を通さずに保存する。モデルの検証が先に拒否して、DB の制約を検査し損ねないため。
# 一意制約の違反は ActiveRecord::RecordNotUnique（モデルに一意性の検証は置かない。DB の制約が、唯一の保証）。
RSpec.describe "一意制約・部分一意索引（requirements.md 20.2）" do
  describe "users.google_sub は一意" do
    it "同じ google_sub の 2 件目を拒否する" do
      create(:user, google_sub: "dummy-sub-same")

      expect_db_violation(ActiveRecord::RecordNotUnique) { save_without_validation!(build(:user, google_sub: "dummy-sub-same")) }
    end

    it "異なる google_sub は、いくつでも持てる" do
      expect { create_list(:user, 3) }.to change(User, :count).by(3)
    end
  end

  describe "sessions.token_digest は一意" do
    it "同じ要約値の 2 件目を拒否する（アカウントが違っても）" do
      create(:session, token_digest: "dummy-digest-same")

      expect_db_violation(ActiveRecord::RecordNotUnique) { save_without_validation!(build(:session, token_digest: "dummy-digest-same")) }
    end

    it "同じアカウントが、複数のセッションを持てる" do
      user = create(:user)

      expect { create_list(:session, 3, user: user) }.to change { Session.owned_by(user).count }.by(3)
    end
  end

  describe "youtube_connections.user_id は一意（アカウントにつき 1 件）" do
    it "同じアカウントの 2 件目を拒否する" do
      user = create(:user)
      create(:youtube_connection, user: user)

      expect_db_violation(ActiveRecord::RecordNotUnique) { save_without_validation!(build(:youtube_connection, user: user)) }
    end

    it "別のアカウントは、それぞれ 1 件ずつ持てる" do
      expect { 2.times { create(:youtube_connection) } }.to change(YoutubeConnection, :count).by(2)
    end
  end

  describe "broadcasts: アカウントにつき、終了していないレコードは 1 件まで（部分一意索引）" do
    let(:user) { create(:user) }

    Contract::BroadcastState::ALL.reject { |state| state == Contract::BroadcastState::ENDED }.each do |state|
      it "終了していない配信（#{state}）がある間は、同じアカウントの、終了していない 2 件目を拒否する" do
        create(:broadcast, user: user, state: state)

        expect_db_violation(ActiveRecord::RecordNotUnique) { save_without_validation!(build(:broadcast, user: user)) }
      end
    end

    it "終了した配信（ended）は、同じアカウントに、いくつあってもよい" do
      expect { create_list(:broadcast, 3, :ended, user: user) }.to change { Broadcast.owned_by(user).count }.by(3)
    end

    it "終了した配信があっても、終了していない配信を 1 件、作れる" do
      create_list(:broadcast, 2, :ended, user: user)

      expect { create(:broadcast, user: user) }.to change { Broadcast.owned_by(user).count }.by(1)
    end

    it "終了していない配信を終了すれば、次の、終了していない配信を作れる" do
      first = create(:broadcast, user: user)
      first.update!(state: "ended", end_reason: "user_stop", ended_at: Time.current)

      expect { create(:broadcast, user: user) }.not_to raise_error
    end

    it "終了した配信を、終了していない状態へ戻す更新は、ほかに終了していない配信があると拒否される" do
      ended = create(:broadcast, :ended, user: user)
      create(:broadcast, user: user)

      expect_db_violation(ActiveRecord::RecordNotUnique) { ended.update_columns(state: "live", end_reason: nil, ended_at: nil) }
    end

    it "別のアカウントは、終了していない配信を、それぞれ 1 件ずつ持てる" do
      expect { 2.times { create(:broadcast) } }.to change(Broadcast, :count).by(2)
    end
  end

  describe "daily_usages: アカウントと利用日の組で一意" do
    it "同じアカウントの同じ利用日の 2 件目を拒否する" do
      user = create(:user)
      create(:daily_usage, user: user, usage_date: Date.new(2026, 10, 7))

      expect_db_violation(ActiveRecord::RecordNotUnique) do
        save_without_validation!(build(:daily_usage, user: user, usage_date: Date.new(2026, 10, 7)))
      end
    end

    it "同じアカウントの別の利用日は、持てる" do
      user = create(:user)
      create(:daily_usage, user: user, usage_date: Date.new(2026, 10, 7))

      expect { create(:daily_usage, user: user, usage_date: Date.new(2026, 10, 8)) }.not_to raise_error
    end

    it "別のアカウントの同じ利用日は、持てる" do
      create(:daily_usage, usage_date: Date.new(2026, 10, 7))

      expect { create(:daily_usage, usage_date: Date.new(2026, 10, 7)) }.not_to raise_error
    end
  end

  describe "relay_tickets.token_digest は一意（要約値は一意）" do
    it "同じ要約値の 2 件目を拒否する" do
      create(:relay_ticket, token_digest: "dummy-ticket-same")

      expect_db_violation(ActiveRecord::RecordNotUnique) { save_without_validation!(build(:relay_ticket, token_digest: "dummy-ticket-same")) }
    end
  end

  describe "主キーの重複（自然キーのテーブル）" do
    it "quota_days: 同じ割り当て日の 2 件目を拒否する" do
      create(:quota_day, quota_date: Date.new(2026, 10, 7))

      expect_db_violation(ActiveRecord::RecordNotUnique) { save_without_validation!(build(:quota_day, quota_date: Date.new(2026, 10, 7))) }
    end

    it "transfer_months: 同じ暦月の 2 件目を拒否する" do
      create(:transfer_month, month: "2026-10")

      expect_db_violation(ActiveRecord::RecordNotUnique) { save_without_validation!(build(:transfer_month, month: "2026-10")) }
    end

    it "deletion_holds: 同じ要約値の 2 件目を拒否する" do
      create(:deletion_hold, sub_digest: "dummy-sub-digest-same")

      expect_db_violation(ActiveRecord::RecordNotUnique) { save_without_validation!(build(:deletion_hold, sub_digest: "dummy-sub-digest-same")) }
    end

    it "system_settings: 同じキーの 2 件目を拒否する" do
      create(:system_setting, key: "daily_allowance")

      expect_db_violation(ActiveRecord::RecordNotUnique) { save_without_validation!(build(:system_setting, key: "daily_allowance")) }
    end
  end
end
