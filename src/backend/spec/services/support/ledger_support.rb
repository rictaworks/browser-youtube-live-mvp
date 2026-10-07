require "rails_helper"
require "support/model_support"

# 利用枠・割り当て台帳・転送量・設定（issue #9）のスペックの共通の補助。
#
# spec/rails_helper.rb は spec/support/** を自動では読み込まない。このディレクトリ（spec/services/support）も同じ。
# 各スペックは、先頭で次のように読み込み、最上位の describe の中で include する（全体へ include しない。ほかの support との名前の衝突を避ける）。
#   require "rails_helper"
#   require "support/model_support"
#   require "services/support/ledger_support"
#   RSpec.describe ... do
#     include LedgerSupport
#
# 台帳の不変条件（requirements.md 8.4・20.2）。明細と配信の残額から、割り当て日ごとの値を再計算して、保存された値と比べる。
#   used_units          当該割り当て日の明細（bucket が prep・settle）の units の合計
#   common_used_units   当該割り当て日の明細（bucket が common）の units の合計
#   reserved_units      当該割り当て日に属する配信の、予約の残額（prep_reserved_units + settle_reserved_units）の合計
# 例のグループに :ledger を付けると、各例の終わりに、台帳の全体（すべての割り当て日）で不変条件を検査する。
module LedgerSupport
  # 割り当て日は、太平洋時間の日付。正午の時刻は、タイムゾーンの定義（夏時間を含む）から作る（固定の時差で作らない）
  PACIFIC_ZONE_NAME = "America/Los_Angeles".freeze

  # 先頭の割り当て日（2026-10-07）から offset 日あとの割り当て日
  def quota_day(offset = 0)
    Date.new(2026, 10, 7) + offset
  end

  # その割り当て日の正午（太平洋時間）の時刻（UTC）。割り当て日の算出が、その日になることを確かめる（補助の誤用を、黙って通さない）
  def noon_of(quota_date)
    time = ActiveSupport::TimeZone[PACIFIC_ZONE_NAME].local(quota_date.year, quota_date.month, quota_date.day, 12).utc
    actual = UsageCalendar.quota_date(time)
    raise "noon_of(#{quota_date}) is on quota date #{actual}" unless actual == quota_date

    time
  end

  # アカウントを作り、識別子を記録する（コミットするスペックが、例の終わりに、SQL で整理するため）。
  # Google の識別子（google_sub。一意）は、実行ごとに一意にする。途中で打ち切られた実行が、コミットした行を残していても、衝突しない
  def create_tracked_user
    create(:user, google_sub: "dummy-google-sub-ledger-#{SecureRandom.hex(8)}").tap { |user| tracked_user_ids << user.id }
  end

  def tracked_user_ids
    @tracked_user_ids ||= []
  end

  # 予約をまだ持たない、受理直後の配信（state: reserved。予約の枠は 0・0）。アカウントは新しく作る。
  # ファクトリの既定は、予約の枠を埋めた姿（340・210）なので、台帳の予約の前には、このメソッドで作る。
  # traits は、ファクトリのトレイト（:ended など）。attributes は、列の値の上書き。
  def create_bare_broadcast(quota_date:, user: nil, traits: [], **attributes)
    owner = user || create_tracked_user
    usage = create(:daily_usage, user: owner, usage_date: attributes.fetch(:usage_date, quota_date))
    create(
      :broadcast,
      *traits,
      { user: owner, daily_usage: usage, usage_date: usage.usage_date, quota_date: quota_date,
        prep_reserved_units: 0, settle_reserved_units: 0 }.merge(attributes)
    )
  end

  # 受理の姿: 配信を作り、台帳へ予約する（成功を期待する）。予約済みの配信を返す。
  def create_reserved_broadcast(quota_date:, daily_total: Settings.defaults.daily_quota_units, **attributes)
    broadcast = create_bare_broadcast(quota_date: quota_date, **attributes)
    reserved = QuotaLedger.reserve!(broadcast, quota_date: quota_date, units: QuotaPolicy::RESERVATION_UNITS, daily_total: daily_total)
    raise "the reservation was refused (daily_total=#{daily_total}, quota_date=#{quota_date})" unless reserved

    broadcast
  end

  # 台帳の 1 日を、不変条件を満たす形で作る（保存した値と、明細・配信の残額からの再計算が、一致する）。
  #   used      使用済み: 同じ額の明細（bucket: prep。配信に属さない）を 1 件
  #   reserved  予約中: 同じ額の予約の残額を持つ配信（準備・確認枠にだけ持たせる）を 1 件
  #   common    共通枠の使用済み: 同じ額の明細（bucket: common）を 1 件
  # 割り当ての上限の境界（配信に使える上限）の検査の、前提の状態を作るために使う。
  def seed_day(quota_date, used: 0, reserved: 0, common: 0, exhausted: false)
    row = QuotaDay.create!(quota_date: quota_date, used_units: used, reserved_units: reserved, common_used_units: common, exhausted: exhausted)
    create(:quota_entry, quota_day: row, units: used, bucket: "prep") if used.positive?
    create(:quota_entry, :common, quota_day: row, units: common) if common.positive?
    create_bare_broadcast(quota_date: quota_date, prep_reserved_units: reserved) if reserved.positive?
    row
  end

  # 台帳の明細と配信の残額から再計算した、割り当て日の値
  def recomputed_day(quota_date)
    entries = QuotaEntry.where(quota_date: quota_date)
    {
      used_units: entries.where(bucket: %w[ prep settle ]).sum(:units),
      common_used_units: entries.where(bucket: "common").sum(:units),
      reserved_units: Broadcast.where(quota_date: quota_date).sum(:prep_reserved_units) +
                      Broadcast.where(quota_date: quota_date).sum(:settle_reserved_units)
    }
  end

  # 保存された割り当て日の値（行が無ければ、すべて 0）
  def stored_day(quota_date)
    row = QuotaDay.find_by(quota_date: quota_date)
    return { used_units: 0, common_used_units: 0, reserved_units: 0 } if row.nil?

    row.slice(:used_units, :common_used_units, :reserved_units).symbolize_keys
  end

  # 割り当て日の値が、明細と配信の残額から再計算した値と一致する
  def expect_ledger_consistent(*quota_dates)
    quota_dates.each do |quota_date|
      expect(stored_day(quota_date)).to eq(recomputed_day(quota_date)), "ledger of #{quota_date} differs from the recomputed value"
    end
  end

  # 台帳にある（または、配信・明細が指す）すべての割り当て日で、不変条件を検査する
  def expect_whole_ledger_consistent
    dates = (QuotaDay.pluck(:quota_date) + QuotaEntry.distinct.pluck(:quota_date) + Broadcast.distinct.pluck(:quota_date)).uniq
    expect_ledger_consistent(*dates)
  end

  # ブロックの中で実行されたすべての SQL の文（トランザクションの制御を含む）を、実行順に返す。
  # DbHelpers#capture_sql は、SAVEPOINT などを含めない。requires_new の検査には、こちらを使う。
  def capture_every_sql(&block)
    statements = []
    callback = lambda do |*, payload|
      statements << payload.fetch(:sql) unless payload[:name] == "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    statements
  end

  # count 本のスレッドを、同時に開始する（DbHelpers#run_concurrently）。スレッドごとに別の接続を使う。
  # 接続のプールの大きさ（既定 5。呼び出し側のスレッドが 1 本使う）を超える数は、接続の待ちで、全体が止まる（スレッドが接続を得られず、
  # 開始の合図が揃わない）。止まらずに、すぐ失敗させる。
  def run_threads(count, &block)
    raise ArgumentError, "#{count} threads exceed the available connections (#{concurrent_width})" if count > concurrent_width

    run_concurrently(count, &block)
  end

  # total 回の呼び出しを、同時に開始する、幅 width の波で行う（スレッドごとに別の接続を使う）。
  # 波に分けて、接続のプールの大きさを超えないようにする。結果は、呼び出しの番号の順に、[:ok, 値] または [:error, 例外]。
  def run_in_waves(total, width: concurrent_width, &block)
    results = []
    (0...total).each_slice(width) do |indexes|
      wave = run_threads(indexes.size) { |position| block.call(indexes.fetch(position)) }
      results.concat(wave)
    end
    results
  end

  # 同時に立てるスレッドの数。プールの大きさから、呼び出し側の 1 本を引く（最低 2 本）
  def concurrent_width
    [ ActiveRecord::Base.connection_pool.size - 1, 2 ].max
  end

  # コミットするスペック（self.use_transactional_tests = false）の、行の整理（SQL）。例の前と後に行う。
  # 例の前にも行うのは、途中で打ち切られた実行が、コミットした行を残していても、影響を受けないため。
  # 台帳の明細は、台帳の行（割り当て日）を参照するため、明細 → 台帳の行 → アカウント（配信・利用実績は、連鎖で消える）の順。
  #   quota_dates     例が使う割り当て日。これらの日に属する配信のアカウントも、整理する（他の例の日付と重ならない、未来の日付を使う）
  #   months          例が使う暦月
  #   setting_keys    例が書く設定のキー
  def clean_committed_rows!(quota_dates: [], months: [], setting_keys: [])
    stray_user_ids = Broadcast.where(quota_date: quota_dates).distinct.pluck(:user_id)
    QuotaEntry.where(quota_date: quota_dates).delete_all
    QuotaDay.where(quota_date: quota_dates).delete_all
    TransferMonth.where(month: months).delete_all
    SystemSetting.where(key: setting_keys).delete_all
    User.where(id: tracked_user_ids + stray_user_ids).delete_all
  end
end

# :ledger を付けた例のグループだけが対象（そのグループは、LedgerSupport を include していること）
RSpec.configure do |config|
  config.after(:each, :ledger) { expect_whole_ledger_consistent }
end
