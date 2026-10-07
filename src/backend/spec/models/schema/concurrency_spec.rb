require "rails_helper"
require "support/model_support"

# 同時の操作での、DB の制約の検査（requirements.md 14 章・27 章「同時性」「整合性」）。
# 複数の接続（スレッド）が、同時に同じ制約へ挑む。保証するのは、アプリケーションの判定ではなく、DB の制約。
#
# 別の接続からは、未コミットの行が見えない。このグループは、トランザクションで包まず、実際にコミットする。
# 作ったアカウントは、各例の後で削除する（共有のテスト用 DB に残さない。子のレコードは、外部キーの連鎖で消える）。
RSpec.describe "同時の操作（requirements.md 14 章・27 章）" do
  self.use_transactional_tests = false

  let(:created_user_ids) { [] }

  after { User.where(id: created_user_ids).delete_all }

  def create_committed_user
    create(:user).tap { |user| created_user_ids << user.id }
  end

  def broadcast_attributes(user_id, daily_usage)
    {
      user_id: user_id, daily_usage_id: daily_usage.id, usage_date: daily_usage.usage_date, quota_date: daily_usage.usage_date,
      privacy_status: "unlisted", made_for_kids: false, accepted_at: Time.current
    }
  end

  it "同じアカウントの、終了していない配信の同時の作成は、1 件だけが成功する（部分一意索引。14 章）" do
    user = create_committed_user
    usages = create_list(:daily_usage, 3, user: user)

    results = run_concurrently(3) { |index| Broadcast.create!(broadcast_attributes(user.id, usages[index])) }

    expect(results.count { |status, _| status == :ok }).to eq(1)
    expect(results.select { |status, _| status == :error }.map { |_, error| error.class }).to all(eq(ActiveRecord::RecordNotUnique))
    expect(Broadcast.owned_by(user).count).to eq(1)
  end

  it "別のアカウントの、終了していない配信の同時の作成は、すべて成功する" do
    users = Array.new(3) { create_committed_user }
    usages = users.map { |user| create(:daily_usage, user: user) }

    results = run_concurrently(3) { |index| Broadcast.create!(broadcast_attributes(users[index].id, usages[index])) }

    expect(results.map(&:first)).to all(eq(:ok))
  end

  it "同じアカウントの同じ利用日の、利用実績の同時の作成は、1 件だけが成功する（アカウントと利用日の組で一意）" do
    user = create_committed_user

    results = run_concurrently(3) { DailyUsage.create!(user_id: user.id, usage_date: Date.new(2026, 10, 7)) }

    expect(results.count { |status, _| status == :ok }).to eq(1)
    expect(results.select { |status, _| status == :error }.map { |_, error| error.class }).to all(eq(ActiveRecord::RecordNotUnique))
  end

  it "同じ接続チケットの、使用済みの印の同時の確保は、1 つだけが成功する（条件付き更新。20.2）" do
    ticket = create(:relay_ticket)
    created_user_ids << ticket.user_id

    results = run_concurrently(3) { RelayTicket.find(ticket.id).mark_used(Time.current) }

    expect(results.map(&:first)).to all(eq(:ok))
    expect(results.map(&:last).count(true)).to eq(1)
    expect(RelayTicket.find(ticket.id).used_at).not_to be_nil
  end
end
