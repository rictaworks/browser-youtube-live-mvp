# frozen_string_literal: true

# 同時の操作の負荷確認（issue #9）。複数の接続（最大 24 スレッド）が、同時に、同じ台帳・同じ配信・同じ利用日の行へ挑む。
# 実装担当のスペック（接続のプールの既定 5 に合わせた、最大 4 スレッドの同時）より、はるかに多い重なりで、次を確かめる。
#   - 上限を超えて予約しない（成功は 16 本）・二重に消費しない・二重に計上しない・上限を超えて支出しない（共通枠・準備・確認枠）
#   - 付与・送出量・設定の更新が、1 つも失われない
#   - 割り当て日をまたぐ支出・移し替え・解放・予約・共通枠が入り混じっても、デッドロックせず、台帳の値が、明細と配信の残額から
#     独立に再計算した値（SQL）と一致する
#
# 使い捨てのテスト用 DB に、実際にコミットする（run_all.sh が、新しい名前の DB を作って、DATABASE_URL を向ける。DB には残るが、
# 次の実行は、新しい名前の DB を使うため、影響しない）。接続のプールは、環境変数 RAILS_MAX_THREADS（run_all.sh が 32 を与える）。
#
# 使い方（run_all.sh が実行する）:
#   scripts/dc.sh exec -T -e RAILS_MAX_THREADS=32 ... backend bundle exec ruby - < test/pr45/stress.rb
# 終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 前提を満たさない（DB が、テスト用でない・プールが小さい）
require "securerandom"

ENV["RAILS_ENV"] = "test"
ROOT = ENV.fetch("ISSUE09_APP_ROOT", "/app")
require "#{ROOT}/config/environment"

database = ActiveRecord::Base.connection_db_config.database
unless database.to_s.match?(/\Abl_test_[a-z0-9_]+\z/)
  warn "FAIL 接続先の DB（#{database.inspect}）が、テスト用の名前（bl_test_...）ではありません。中止します"
  exit 2
end

WIDTH = 24
pool_size = ActiveRecord::Base.connection_pool.size
if pool_size < WIDTH + 4
  warn "FAIL 接続のプールが小さすぎます（#{pool_size}）。RAILS_MAX_THREADS=32 を与えて実行してください"
  exit 2
end

FAILURES = []
CHECKED = []

def check(label)
  ok = begin
    yield ? true : false
  rescue StandardError => e
    puts "  (例外: #{e.class}: #{e.message.lines.first&.strip})"
    false
  end
  CHECKED << label
  puts "#{ok ? 'ok  ' : 'FAIL'} #{label}"
  FAILURES << label unless ok
end

def sql(statement)
  ActiveRecord::Base.with_connection { |connection| connection.select_value(statement) }
end

def sql_rows(statement)
  ActiveRecord::Base.with_connection { |connection| connection.select_rows(statement) }
end

# count 本のスレッドを、同時に開始する。各スレッドは自分の接続を使い、結果 [:ok, 値] または [:error, 例外] を返す（番号の順）。
def race(count)
  gate = Queue.new
  ready = Queue.new
  threads = Array.new(count) do |index|
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ready << index
        gate.pop
        begin
          [ :ok, yield(index) ]
        rescue StandardError => e
          [ :error, e ]
        end
      end
    end
  end
  count.times { ready.pop }
  count.times { gate << true }
  threads.map(&:value)
end

# total 回を、幅 WIDTH の波で行う
def waves(total, &block)
  (0...total).each_slice(WIDTH).flat_map do |indexes|
    race(indexes.size) { |position| block.call(indexes.fetch(position)) }
  end
end

def errors_of(results)
  results.select { |status, _| status == :error }.map { |_, error| "#{error.class}: #{error.message.lines.first&.strip}" }
end

def values_of(results)
  results.map { |status, value| status == :ok ? value : value.class }
end

# 各接続で、読み直した配信（AR のインスタンスは、スレッド間で共有しない）
def fresh(broadcast)
  Broadcast.find(broadcast.id)
end

def new_user
  User.create!(google_sub: "dummy-stress-#{SecureRandom.hex(8)}", last_login_at: Time.current)
end

def new_usage(user, date)
  DailyUsage.create!(user: user, usage_date: date)
end

def new_broadcast(quota_date:, user: new_user, usage_date: quota_date, usage: nil, **extra)
  usage ||= new_usage(user, usage_date)
  Broadcast.create!(
    { user: user, daily_usage: usage, state: "reserved", usage_date: usage.usage_date, quota_date: quota_date,
      privacy_status: "unlisted", made_for_kids: false, accepted_at: Time.current }.merge(extra)
  )
end

def reserved_broadcast(quota_date:)
  new_broadcast(quota_date: quota_date).tap do |broadcast|
    raise "予約を断られました" unless QuotaLedger.reserve!(broadcast, quota_date: quota_date, daily_total: 10_000)
  end
end

def day_row(quota_date)
  row = sql_rows("SELECT used_units, reserved_units, common_used_units FROM quota_days WHERE quota_date = '#{quota_date}'").first
  row && { used: row[0], reserved: row[1], common: row[2] }
end

# 明細と配信の残額から、独立に再計算した台帳の 1 日（SQL）
def recomputed_day(quota_date)
  {
    used: sql("SELECT COALESCE(SUM(units), 0) FROM quota_entries WHERE quota_date = '#{quota_date}' AND bucket IN ('prep', 'settle')"),
    reserved: sql("SELECT COALESCE(SUM(prep_reserved_units + settle_reserved_units), 0) FROM broadcasts WHERE quota_date = '#{quota_date}'"),
    common: sql("SELECT COALESCE(SUM(units), 0) FROM quota_entries WHERE quota_date = '#{quota_date}' AND bucket = 'common'")
  }
end

def ledger_consistent?(*dates)
  dates.all? do |date|
    stored = day_row(date)
    stored.nil? ? recomputed_day(date).values.all?(&:zero?) : stored == recomputed_day(date)
  end
end

def noon_of(date)
  ActiveSupport::TimeZone["America/Los_Angeles"].local(date.year, date.month, date.day, 12).utc
end

# 場面ごとに、重ならない日付（この実行の使い捨ての DB の中で、場面ごとに分ける）
BASE_DATE = Date.new(2026, 12, 1)

def day(offset)
  BASE_DATE + offset
end

SETTINGS = Settings.defaults

puts "== 接続のプール #{pool_size}・同時の幅 #{WIDTH}（DB: #{database}）"

puts "== 予約・利用枠・開始試行"
check("reserve!: #{WIDTH} 本が同時に予約を求めても、成功は 16 本（9,000 ÷ 550）。予約中は 8,800。台帳が整合する") do
  date = day(0)
  broadcasts = Array.new(WIDTH) { new_broadcast(quota_date: date) }
  results = race(WIDTH) { |index| QuotaLedger.reserve!(fresh(broadcasts[index]), quota_date: date, daily_total: 10_000) }
  puts "  (結果: #{values_of(results).tally}・予約中 #{day_row(date)&.fetch(:reserved)}・例外 #{errors_of(results).tally})" if errors_of(results).any?
  errors_of(results).empty? && values_of(results).count(true) == 16 && day_row(date)[:reserved] == 16 * 550 && ledger_consistent?(date)
end
check("reserve!: 残りが 1 本分のとき、#{WIDTH} 本が同時に予約を求めると、1 本だけ成功する") do
  date = day(1)
  QuotaDay.create!(quota_date: date, used_units: 8_450)
  QuotaEntry.create!(quota_day: QuotaDay.find(date), method: "liveBroadcasts.list", units: 8_450, result: "ok", bucket: "prep", called_at: Time.current)
  broadcasts = Array.new(WIDTH) { new_broadcast(quota_date: date) }
  results = race(WIDTH) { |index| QuotaLedger.reserve!(fresh(broadcasts[index]), quota_date: date, daily_total: 10_000) }
  errors_of(results).empty? && values_of(results).count(true) == 1 && day_row(date)[:reserved] == 550 && ledger_consistent?(date)
end
check("consume!: 同じ配信への #{WIDTH} 本の同時の消費は、1 回だけ（二重に消費しない）") do
  user = new_user
  usage = new_usage(user, day(2))
  broadcast = new_broadcast(quota_date: day(2), user: user, usage: usage)
  results = race(WIDTH) { DailyAllowance.consume!(fresh(broadcast), settings: SETTINGS) }
  errors_of(results).empty? && values_of(results).count(true) == 1 && usage.reload.consumed_count == 1
end
check("consume!: 利用枠 1 回の利用日に、2 つの配信が #{WIDTH} 本で同時に消費を求めると、消費は 1 回だけ（上限を超えない）") do
  user = new_user
  usage = new_usage(user, day(3))
  ended = new_broadcast(quota_date: day(3), user: user, usage: usage, state: "ended", end_reason: "user_stop", ended_at: Time.current)
  live = new_broadcast(quota_date: day(3), user: user, usage: usage)
  results = race(WIDTH) { |index| DailyAllowance.consume!(fresh(index.even? ? ended : live), settings: SETTINGS) }
  exhausted = values_of(results).count(DailyAllowance::AllowanceExhausted)
  usage.reload.consumed_count == 1 && values_of(results).count(true) == 1 && exhausted.positive? && (values_of(results) - [ true, false, DailyAllowance::AllowanceExhausted ]).empty?
end
check("count_attempt!: 上限 3 回の利用日に、4 つの配信が #{WIDTH} 本で同時に計上を求めると、計上は合計 3 回（4 つ目は AttemptLimitReached）") do
  user = new_user
  usage = new_usage(user, day(4))
  broadcasts = Array.new(3) { new_broadcast(quota_date: day(4), user: user, usage: usage, state: "ended", end_reason: "user_stop", ended_at: Time.current) } +
               [ new_broadcast(quota_date: day(4), user: user, usage: usage) ]
  results = race(WIDTH) { |index| DailyAllowance.count_attempt!(fresh(broadcasts[index % 4]), settings: SETTINGS) }
  counted = Broadcast.where(id: broadcasts.map(&:id), attempt_counted: true).count
  usage.reload.attempt_count == 3 && counted == 3 && values_of(results).count(true) == 3 &&
    (values_of(results) - [ true, false, DailyAllowance::AttemptLimitReached ]).empty?
end
check("grant_extra!: #{WIDTH} 本の同時の付与が、1 つも失われない（追加 #{WIDTH}・行は 1 件・開始試行 0）") do
  user = new_user
  results = race(WIDTH) { DailyAllowance.grant_extra!(user_id: user.id, usage_date: day(5)).id }
  row = DailyUsage.owned_by(user).where(usage_date: day(5))
  errors_of(results).empty? && row.count == 1 && row.first.extra_grants == WIDTH && row.first.attempt_count.zero?
end
check("ensure_for!: #{WIDTH} 本の同時の最初の呼び出しが重なっても、行は 1 件で、全員が同じ行を得る") do
  user = new_user
  results = race(WIDTH) { DailyAllowance.ensure_for!(user_id: user.id, usage_date: day(6)).id }
  errors_of(results).empty? && values_of(results).uniq.size == 1 && DailyUsage.owned_by(user).where(usage_date: day(6)).count == 1
end

puts "== 記帳・共通枠・解放・移し替え"
check("spend!: 同じ配信への #{WIDTH} 本の同時の支出（50 × #{WIDTH}）で、準備・確認枠 340 を超えず、成功は 6 回。終了・清算枠は 210 のまま") do
  date = day(10)
  broadcast = reserved_broadcast(quota_date: date)
  results = race(WIDTH) { QuotaLedger.spend!(fresh(broadcast), method: "liveBroadcasts.insert", units: 50, bucket: :prep, result: "ok", now: noon_of(date)) }
  row = sql_rows("SELECT prep_reserved_units, settle_reserved_units FROM broadcasts WHERE id = '#{broadcast.id}'").first
  errors_of(results).empty? && values_of(results).count(true) == 6 && row == [ 40, 210 ] && day_row(date) == { used: 300, reserved: 250, common: 0 } && ledger_consistent?(date)
end
check("spend_common!: #{WIDTH} 本の同時の支出（25 × #{WIDTH}）で、共通枠 500 を超えず、成功は 20 回") do
  date = day(11)
  results = race(WIDTH) { QuotaLedger.spend_common!(method: "channels.list", units: 25, quota_date: date, now: noon_of(date)) }
  errors_of(results).empty? && values_of(results).count(true) == 20 && day_row(date)[:common] == 500 && ledger_consistent?(date)
end
check("release!: 同じ配信の #{WIDTH} 本の同時の解放は、1 回だけ（二重に解放しない）。別の配信の予約は残る") do
  date = day(12)
  broadcast = reserved_broadcast(quota_date: date)
  other = reserved_broadcast(quota_date: date)
  results = race(WIDTH) { QuotaLedger.release!(fresh(broadcast)) }
  errors_of(results).empty? && values_of(results).count(true) == 1 && day_row(date)[:reserved] == 550 && fresh(other).prep_reserved_units == 340 && ledger_consistent?(date)
end
check("carry_over!: 同じ配信の #{WIDTH} 本の同時の移し替えは、1 回だけ") do
  date = day(13)
  broadcast = reserved_broadcast(quota_date: date)
  results = race(WIDTH) { QuotaLedger.carry_over!(fresh(broadcast), quota_date: date + 1) }
  errors_of(results).empty? && values_of(results).count(true) == 1 && day_row(date)[:reserved].zero? && day_row(date + 1)[:reserved] == 550 && ledger_consistent?(date, date + 1)
end
check("spend!: 割り当て日をまたぐ #{WIDTH} 本の同時の支出（10 × #{WIDTH}）は、予約を 1 回だけ新しい日へ移し、すべて記帳する") do
  date = day(16) # 前の場面の移し替え（day(13) から day(14) へ）と、日付を重ねない
  broadcast = reserved_broadcast(quota_date: date)
  results = race(WIDTH) { QuotaLedger.spend!(fresh(broadcast), method: "liveBroadcasts.list", units: 10, bucket: :prep, result: "ok", now: noon_of(date + 1)) }
  errors_of(results).empty? && values_of(results).count(true) == WIDTH && day_row(date)[:reserved].zero? &&
    day_row(date + 1) == { used: 10 * WIDTH, reserved: 550 - (10 * WIDTH), common: 0 } && ledger_consistent?(date, date + 1)
end

puts "== 転送量・設定"
check("add_for_broadcast!: 同じ配信の #{WIDTH * 2} 回の同時の報告が、1 つも失われない（配信・月次とも、合計と一致する）") do
  user = new_user
  broadcast = new_broadcast(quota_date: day(20), user: user, sent_bytes: 1_000)
  now = Time.utc(2031, 6, 15, 3, 0, 0)
  results = waves(WIDTH * 2) { |index| TransferBudget.add_for_broadcast!(fresh(broadcast), delta_bytes: 100 + index, now: now) }
  total = (0...(WIDTH * 2)).sum { |index| 100 + index }
  errors_of(results).empty? && fresh(broadcast).sent_bytes == 1_000 + total && TransferMonth.find("2031-06").sent_bytes == total
end
check("SettingsStore.update!: #{WIDTH} 本の同時の更新が重なっても、行は 1 件（一意制約と競合しない）") do
  results = race(WIDTH) { |index| SettingsStore.update!(key: "attempt_limit", value: index + 1) }
  errors_of(results).empty? && sql("SELECT COUNT(*) FROM system_settings WHERE key = 'attempt_limit'") == 1 &&
    (1..WIDTH).cover?(SettingsStore.current.attempt_limit)
end

puts "== 入り混じった操作（デッドロックしない・台帳が整合する）"
check("予約・支出（割り当て日をまたぐものを含む）・移し替え・解放・共通枠が、入り混じって #{WIDTH} 本ずつ重なっても、例外が無く、台帳が整合する") do
  first = day(30)
  second = day(31)
  third = day(32)
  holders = Array.new(10) { reserved_broadcast(quota_date: first) } + Array.new(6) { reserved_broadcast(quota_date: second) }
  newcomers = Array.new(40) { new_broadcast(quota_date: second) }
  rng = Random.new(20_261_009)
  kinds = %i[ spend_first spend_second spend_third carry release common reserve ]
  plan = Array.new(WIDTH * 20) { kinds.sample(random: rng) }
  reserve_slots = plan.each_index.select { |index| plan.fetch(index) == :reserve }
  reserve_slots.drop(newcomers.size).each { |index| plan[index] = :common }
  newcomer_of = reserve_slots.first(newcomers.size).each_with_index.to_h { |plan_index, position| [ plan_index, newcomers.fetch(position) ] }
  pick = ->(index) { holders.sample(random: Random.new(index)) }
  spend = lambda do |index, date|
    QuotaLedger.spend!(fresh(pick.call(index)), method: "liveBroadcasts.list", units: 1 + (index % 4), bucket: index.even? ? :prep : :settle, result: "ok", now: noon_of(date))
  end

  results = waves(plan.size) do |index|
    case plan.fetch(index)
    when :spend_first then spend.call(index, first)
    when :spend_second then spend.call(index, second)
    when :spend_third then spend.call(index, third)
    when :carry then QuotaLedger.carry_over!(fresh(pick.call(index)), quota_date: third) # 最も新しい日へ（予約の割り当て日より前への移し替えは、例外）
    when :release then QuotaLedger.release!(fresh(pick.call(index)))
    when :common then QuotaLedger.spend_common!(method: "channels.list", units: 1 + (index % 3), quota_date: [ first, second, third ][index % 3], now: noon_of(first))
    when :reserve then QuotaLedger.reserve!(fresh(newcomer_of.fetch(index)), quota_date: second, daily_total: 10_000)
    end
  end
  errors = errors_of(results)
  puts "  (例外: #{errors.tally})" unless errors.empty?
  errors.empty? && ledger_consistent?(first, second, third)
end

puts "== 全体の整合（この実行で作った、すべての割り当て日）"
check("台帳の used・reserved・common が、すべての日で、明細と配信の残額から再計算した値と一致し、負の値が無い") do
  dates = sql_rows("SELECT quota_date FROM quota_days").flatten
  negative = sql("SELECT COUNT(*) FROM quota_days WHERE used_units < 0 OR reserved_units < 0 OR common_used_units < 0")
  puts "  (台帳の日数: #{dates.size})"
  dates.size >= 10 && negative.zero? && ledger_consistent?(*dates)
end

puts
puts "確認した項目 #{CHECKED.size} 件、失敗 #{FAILURES.size} 件"
if FAILURES.empty?
  puts "PASS 同時の操作の負荷確認はすべて成功しました"
  exit 0
end
FAILURES.each { |label| puts "  - #{label}" }
exit 1
