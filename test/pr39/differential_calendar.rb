# frozen_string_literal: true

# 暦の差分検査（issue #5 の UsageCalendar）。UsageCalendar（TZInfo のタイムゾーン定義）を、OS の libc のタイムゾーン処理
# （TZ 環境変数 + Time#localtime・Time.local）を基準にした、独立の算出と、多数の時刻で突き合わせる。
# 夏時間の切り替え・日付の境界の近傍の時刻（秒単位）を、重点的に含める。固定の時差（UTC-8・UTC-7）の誤りを、広い範囲で検出する。
#   対象: usage_date・quota_date・next_usage_date_start・next_quota_date_start・month_key・next_month_start
#   時刻: 2024-01-01 から 2031-01-01 までの一様な乱数（固定の種）と、夏時間の切り替え・日付の境界の前後 2 時間
#
# 使い方（run_all.sh が実行する。ISSUE05_DIFF_SAMPLES で、乱数の時刻の数を変えられる。既定 20,000）:
#   scripts/dc.sh exec -T backend bundle exec ruby - < test/pr39/differential_calendar.rb
# 終了コード: 0 = 差分なし / 1 = 差分あり
require "date"
require "time"
require "zeitwerk"

ROOT = ENV.fetch("ISSUE05_APP_ROOT", "/app")
SAMPLES = Integer(ENV.fetch("ISSUE05_DIFF_SAMPLES", "20000"))

loader = Zeitwerk::Loader.new
loader.push_dir("#{ROOT}/app/domain")
loader.setup

LA = "America/Los_Angeles"
JST = "Asia/Tokyo"

def with_tz(zone)
  previous = ENV.fetch("TZ", nil)
  ENV["TZ"] = zone
  yield
ensure
  ENV["TZ"] = previous
end

def local_date(time)
  Date.new(time.year, time.month, time.day)
end

# libc を基準にした、独立の算出
def ref_quota_date(epoch)
  with_tz(LA) { local_date(Time.at(epoch)) }
end

def ref_usage_date(epoch)
  with_tz(JST) { local_date(Time.at(epoch) - (3 * 3600)) }
end

# 太平洋時間の翌日 0 時の epoch（libc の Time.local は、夏時間を考慮する）
def ref_next_quota_start(epoch)
  with_tz(LA) do
    next_date = local_date(Time.at(epoch)) + 1
    Time.local(next_date.year, next_date.month, next_date.day, 0, 0, 0).to_i
  end
end

def ref_next_usage_start(epoch)
  with_tz(JST) do
    next_date = local_date(Time.at(epoch) - (3 * 3600)) + 1
    Time.local(next_date.year, next_date.month, next_date.day, 3, 0, 0).to_i
  end
end

def ref_month_key(epoch)
  with_tz(JST) do
    local = Time.at(epoch)
    format("%04d-%02d", local.year, local.month)
  end
end

def ref_next_month_start(epoch)
  with_tz(JST) do
    first = Date.new(Time.at(epoch).year, Time.at(epoch).month, 1).next_month
    Time.local(first.year, first.month, first.day, 0, 0, 0).to_i
  end
end

random = Random.new(20_261_007)
range = (Time.utc(2024, 1, 1).to_i...Time.utc(2031, 1, 1).to_i)
samples = Array.new(SAMPLES) { random.rand(range) }

# 夏時間の切り替え（2025・2026・2027 の春と秋）と、日付の境界（JST 03:00・太平洋時間 0 時・JST 月初）の前後 2 時間
centers = [
  Time.utc(2025, 3, 9, 10, 0, 0), Time.utc(2025, 11, 2, 9, 0, 0), Time.utc(2026, 3, 8, 10, 0, 0), Time.utc(2026, 11, 1, 9, 0, 0),
  Time.utc(2027, 3, 14, 10, 0, 0), Time.utc(2027, 11, 7, 9, 0, 0), Time.utc(2026, 3, 8, 8, 0, 0), Time.utc(2026, 3, 9, 7, 0, 0),
  Time.utc(2026, 11, 1, 7, 0, 0), Time.utc(2026, 11, 2, 8, 0, 0), Time.utc(2026, 10, 6, 18, 0, 0), Time.utc(2026, 9, 30, 15, 0, 0)
].map(&:to_i)
centers.each { |center| (-7200..7200).step(13) { |offset| samples << (center + offset) } }

count = 0
mismatches = []
samples.each do |epoch|
  time = Time.at(epoch).utc
  {
    quota_date: [ UsageCalendar.quota_date(time), ref_quota_date(epoch) ],
    usage_date: [ UsageCalendar.usage_date(time), ref_usage_date(epoch) ],
    next_quota_date_start: [ UsageCalendar.next_quota_date_start(time).to_i, ref_next_quota_start(epoch) ],
    next_usage_date_start: [ UsageCalendar.next_usage_date_start(time).to_i, ref_next_usage_start(epoch) ],
    month_key: [ UsageCalendar.month_key(time), ref_month_key(epoch) ],
    next_month_start: [ UsageCalendar.next_month_start(time).to_i, ref_next_month_start(epoch) ]
  }.each do |name, (actual, expected)|
    count += 1
    mismatches << [ name, time.iso8601, actual, expected ] unless actual == expected
  end
end

puts "時刻 #{samples.size} 点 x 6 関数 = #{count} 件を、libc のタイムゾーン処理と突き合わせました"
if mismatches.empty?
  puts "PASS 差分なし"
  exit 0
end
puts "FAIL 差分 #{mismatches.size} 件（先頭 10 件）:"
mismatches.first(10).each { |entry| puts "  #{entry.inspect}" }
exit 1
