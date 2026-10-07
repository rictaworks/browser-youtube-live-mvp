# アカウントに属するレコードを、すべてのテーブルに 1 件ずつ作る補助（所有権・連鎖削除のスペック用）。
module AccountRecords
  # 利用者に属する 8 テーブルと、配信に属する台帳の明細を、1 件ずつ作る。
  # 返り値は、{ session:, youtube_connection:, daily_usage:, broadcast:, relay_ticket:, health_sample:, broadcast_event:, usage_event:, quota_entry: }。
  # 同じ割り当て日の quota_days は、1 件を共有する（主キーが割り当て日のため）。
  def create_account_records(user)
    daily_usage = create(:daily_usage, user: user)
    broadcast = create(:broadcast, user: user, daily_usage: daily_usage)
    quota_day = QuotaDay.find_by(quota_date: broadcast.quota_date) || create(:quota_day, quota_date: broadcast.quota_date)

    {
      session: create(:session, user: user),
      youtube_connection: create(:youtube_connection, user: user),
      daily_usage: daily_usage,
      broadcast: broadcast,
      relay_ticket: create(:relay_ticket, user: user, broadcast: broadcast),
      health_sample: create(:health_sample, user: user, broadcast: broadcast),
      broadcast_event: create(:broadcast_event, user: user, broadcast: broadcast),
      usage_event: create(:usage_event, user: user),
      quota_entry: create(:quota_entry, quota_day: quota_day, broadcast: broadcast)
    }
  end
end

RSpec.configure do |config|
  config.include AccountRecords
end
