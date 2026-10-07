# frozen_string_literal: true

# 受け入れの確認（issue #5「アプリケーション Domain Core（1）」）。黒箱: RSpec を使わず、公開の API だけを呼び、
# issue の受け入れ条件を、1 項目ずつ確かめる。実装担当のスペックとは別に、issue の本文から書き起こしたもの。
# 対象は、開発サーバーの backend コンテナの中の app/domain（素の Zeitwerk で読み込む。Rails は起動しない）。
#
# 使い方（run_all.sh が実行する）:
#   scripts/dc.sh exec -T backend bundle exec ruby - < test/pr39/acceptance.rb
# 終了コード: 0 = すべて成功 / 1 = 失敗がある
require "date"
require "json"
require "time"
require "zeitwerk"

# 対象の app/domain の置き場（mutate_domain.rb が、壊した複製に向けるときだけ、環境変数で変える）
ROOT = ENV.fetch("ISSUE05_APP_ROOT", "/app")
CONTRACTS = "/contracts"

loader = Zeitwerk::Loader.new
loader.push_dir("#{ROOT}/app/domain")
loader.setup

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

def raises?(klass = StandardError)
  yield
  false
rescue klass
  true
end

def utc(*parts)
  Time.utc(*parts)
end

def jst(year, month, day, hour = 0, minute = 0, second = 0)
  Time.utc(year, month, day, hour, minute, second) - (9 * 3600)
end

puts "== 日付の算出（UsageCalendar）"
check("usage_date: JST 02:59:59 は前日、03:00:00 は当日") do
  UsageCalendar.usage_date(jst(2026, 10, 7, 2, 59, 59)) == Date.new(2026, 10, 6) &&
    UsageCalendar.usage_date(jst(2026, 10, 7, 3, 0, 0)) == Date.new(2026, 10, 7)
end
check("quota_date: 春の切り替え（2026-03-08）の前後で、固定の時差では誤る時刻を正しく扱う") do
  UsageCalendar.quota_date(utc(2026, 3, 9, 7, 0, 0)) == Date.new(2026, 3, 9) && # UTC-8 の固定なら 03-08
    UsageCalendar.quota_date(utc(2026, 3, 9, 7, 30, 0)) == Date.new(2026, 3, 9) &&
    UsageCalendar.quota_date(utc(2026, 3, 8, 7, 59, 59)) == Date.new(2026, 3, 7) # UTC-7 の固定なら 03-08
end
check("quota_date: 秋の切り替え（2026-11-01）の前後で、固定の時差では誤る時刻を正しく扱う") do
  UsageCalendar.quota_date(utc(2026, 11, 1, 7, 0, 0)) == Date.new(2026, 11, 1) && # UTC-8 の固定なら 10-31
    UsageCalendar.quota_date(utc(2026, 11, 2, 7, 30, 0)) == Date.new(2026, 11, 1) && # UTC-7 の固定なら 11-02
    UsageCalendar.quota_date(utc(2026, 11, 2, 8, 0, 0)) == Date.new(2026, 11, 2)
end
check("next_usage_date_start: 次の JST 03:00（03:00:00 ちょうどの次は翌日）") do
  UsageCalendar.next_usage_date_start(jst(2026, 10, 7, 2, 59, 59)).iso8601 == "2026-10-07T03:00:00+09:00" &&
    UsageCalendar.next_usage_date_start(jst(2026, 10, 7, 3, 0, 0)).iso8601 == "2026-10-08T03:00:00+09:00"
end
check("next_quota_date_start: 夏時間の日は 23 時間（2026-03-08）・25 時間（2026-11-01）") do
  march = utc(2026, 3, 8, 8, 0, 0)
  november = utc(2026, 11, 1, 7, 0, 0)
  UsageCalendar.next_quota_date_start(march) - march == 23 * 3600 &&
    UsageCalendar.next_quota_date_start(november) - november == 25 * 3600 &&
    UsageCalendar.next_quota_date_start(utc(2026, 3, 8, 10, 0, 0)).iso8601 == "2026-03-09T16:00:00+09:00" &&
    UsageCalendar.next_quota_date_start(utc(2026, 11, 1, 9, 30, 0)).iso8601 == "2026-11-02T17:00:00+09:00"
end
check("month_key・next_month_start: JST の暦月（03:00 区切りではない）") do
  UsageCalendar.month_key(jst(2026, 10, 1, 2, 59, 59)) == "2026-10" &&
    UsageCalendar.month_key(jst(2026, 9, 30, 23, 59, 59)) == "2026-09" &&
    UsageCalendar.next_month_start(jst(2026, 10, 31, 23, 59, 59)).iso8601 == "2026-11-01T00:00:00+09:00" &&
    UsageCalendar.next_month_start(jst(2026, 12, 15)).iso8601 == "2027-01-01T00:00:00+09:00"
end
check("実時計を呼ばない: Time.now・Date.today を失敗させても、すべて動く") do
  time_singleton = Time.singleton_class
  date_singleton = Date.singleton_class
  time_singleton.send(:alias_method, :real_now_for_acceptance, :now)
  date_singleton.send(:alias_method, :real_today_for_acceptance, :today)
  time_singleton.send(:define_method, :now) { |*| raise "Time.now が呼ばれました" }
  date_singleton.send(:define_method, :today) { |*| raise "Date.today が呼ばれました" }
  begin
    time = jst(2026, 10, 7, 12)
    [ UsageCalendar.usage_date(time), UsageCalendar.quota_date(time), UsageCalendar.next_usage_date_start(time),
      UsageCalendar.next_quota_date_start(time), UsageCalendar.month_key(time), UsageCalendar.next_month_start(time) ].size == 6
  ensure
    time_singleton.send(:alias_method, :now, :real_now_for_acceptance)
    date_singleton.send(:alias_method, :today, :real_today_for_acceptance)
  end
end

puts "== 設定値（Settings）"
limits_json = JSON.parse(File.read("#{CONTRACTS}/limits.json"))
enums_json = JSON.parse(File.read("#{CONTRACTS}/enums.json"))
rejections_json = JSON.parse(File.read("#{CONTRACTS}/http-rejections.json"))
check("9 設定（契約の setting_key）を持ち、既定値は契約の limits.json のとおり（値も型も）") do
  keys = enums_json.fetch("enums").fetch("setting_key").fetch("values")
  defaults = limits_json.fetch("setting_defaults")
  Settings.members.map(&:to_s) == keys && keys.size == 9 &&
    keys.all? { |key| Settings.defaults.public_send(key).eql?(defaults.fetch(key)) }
end
check("文字列の入力を型変換して検証する（管理画面・DB から）") do
  s = Settings.from_raw("daily_allowance" => "2", "attempt_limit" => "5", "bot_score_threshold" => "0.7", "intake_paused" => "true")
  s.daily_allowance == 2 && s.attempt_limit == 5 && s.bot_score_threshold == 0.7 && s.intake_paused == true && s.time_limit_minutes == 60
end
check("範囲外・型違いは例外（既定値へ黙って戻さない）") do
  [
    { "daily_allowance" => "-1" }, { "daily_allowance" => "abc" }, { "time_limit_minutes" => "0" }, { "daily_quota_units" => "999" },
    { "bot_score_threshold" => "1.5" }, { "intake_paused" => "yes" }, { "unknown_setting" => "1" }
  ].all? { |raw| raises?(ArgumentError) { Settings.from_raw(raw) } }
end
check("不変（凍結され、書き込みのメソッドを持たない）") do
  s = Settings.defaults
  s.frozen? && Settings.members.none? { |member| s.respond_to?("#{member}=") }
end

puts "== 転送量の判定（TransferBudgetPolicy）"
check("積算が予算に達した月は不可（>=）。1 GB = 1,000,000,000 バイト") do
  TransferBudgetPolicy.exceeded?(sent_bytes: 9_999_999_999, budget_gb: 10) == false &&
    TransferBudgetPolicy.exceeded?(sent_bytes: 10_000_000_000, budget_gb: 10) == true &&
    TransferBudgetPolicy.exceeded?(sent_bytes: 999_999_999, budget_gb: 1) == false &&
    TransferBudgetPolicy.exceeded?(sent_bytes: 1_000_000_000, budget_gb: 1) == true
end

puts "== 割り当て台帳の規則（QuotaPolicy）"
def quota_day(used: 0, reserved: 0, common: 0, date: Date.new(2026, 10, 6))
  QuotaPolicy::Day.new(quota_date: date, used_units: used, reserved_units: reserved, common_used_units: common)
end

check("can_reserve?: ちょうど 9,000 は可、9,001 は不可") do
  QuotaPolicy.can_reserve?(quota_day(reserved: 8_450), units: 550, daily_total: 10_000) == true &&
    QuotaPolicy.can_reserve?(quota_day(reserved: 8_451), units: 550, daily_total: 10_000) == false
end
check("17 本目の予約は拒否される（550 x 16 = 8,800。17 本目は 9,350）") do
  day = quota_day
  granted = 0
  17.times do
    outcome = QuotaPolicy.reserve(day, daily_total: 10_000)
    next unless outcome.granted?

    day = outcome.day
    granted += 1
  end
  granted == 16 && day.reserved_units == 8_800
end
check("準備・確認枠（340）と終了・清算枠（210）を分ける。準備・確認が 340 を超えても、終了・清算枠は減らない") do
  booked = QuotaPolicy.reserve(quota_day, daily_total: 10_000)
  day = booked.day
  held = booked.reservation
  6.times do
    outcome = QuotaPolicy.spend(held, bucket: :prep, units: 50, day: day)
    day = outcome.day
    held = outcome.reservation
  end
  over = QuotaPolicy.spend(held, bucket: :prep, units: 50, day: day)
  held.prep_remaining_units == 40 && !over.granted? && held.settle_remaining_units == 210 &&
    QuotaPolicy.spend(held, bucket: :settle, units: 210, day: day).granted?
end
check("実費を使用済みへ、同額を該当枠の予約から取り崩す（使用済み + 予約中は変わらない）") do
  booked = QuotaPolicy.reserve(quota_day, daily_total: 10_000)
  spent = QuotaPolicy.spend(booked.reservation, bucket: :settle, units: 51, day: booked.day)
  spent.day.used_units == 51 && spent.day.reserved_units == 499 && spent.reservation.settle_remaining_units == 159 &&
    spent.reservation.prep_remaining_units == 340
end
check("割り当て日をまたぐ移し替え（またいだ後の最初の支出時）") do
  booked = QuotaPolicy.reserve(quota_day(reserved: 300), daily_total: 10_000)
  next_day = quota_day(date: Date.new(2026, 10, 7), reserved: 1_000)
  carried = QuotaPolicy.carry_over(booked.reservation, from: booked.day, to: next_day)
  carried.from.reserved_units == 300 && carried.to.reserved_units == 1_550 &&
    carried.reservation.quota_date == Date.new(2026, 10, 7) &&
    QuotaPolicy.spend(carried.reservation, bucket: :prep, units: 10, day: carried.to).granted? &&
    raises?(ArgumentError) { QuotaPolicy.spend(carried.reservation, bucket: :prep, units: 10, day: carried.from) }
end
check("共通枠 500 の枯渇（501 ユニット目で拒否。尽きたあとは 1 ユニットも不可）") do
  day = quota_day
  500.times { day = QuotaPolicy.spend_common(day, units: 1).day }
  day.common_used_units == 500 && !QuotaPolicy.spend_common(day, units: 1).granted?
end
check("解放: 予約の残額を台帳へ戻す（冪等）") do
  booked = QuotaPolicy.reserve(quota_day, daily_total: 10_000)
  once = QuotaPolicy.release(booked.reservation, day: booked.day)
  twice = QuotaPolicy.release(once.reservation, day: once.day)
  once.day.reserved_units == 0 && twice.day == once.day
end
check("割り当て超過が返った日（exhausted）は、空きがあっても新規の予約を受け付けない（8.4）。進行中の配信の記帳・解放は続く") do
  exhausted = quota_day(reserved: 550).with(exhausted: true)
  held = QuotaPolicy::Reservation.new(quota_date: exhausted.quota_date, prep_remaining_units: 340, settle_remaining_units: 210)
  !QuotaPolicy.can_reserve?(exhausted, units: 550, daily_total: 10_000) && !QuotaPolicy.reserve(exhausted, daily_total: 10_000).granted? &&
    QuotaPolicy.spend(held, bucket: :prep, units: 10, day: exhausted).granted? && QuotaPolicy.release(held, day: exhausted).granted?
end
check("すべての配信が上限まで支出しても枠を超えない（8.4 の表: 準備・確認 321 / 340、終了・清算 204 / 210。16 本を交互に）") do
  costs = limits_json.fetch("quota").fetch("unit_costs")
  prep = [ [ %w[list], 1 ], [ %w[transition], 1 ], [ %w[insert], 1 ], [ %w[list], 1 ], [ %w[list], 1 ], [ %w[insert], 1 ], [ %w[bind], 1 ],
           [ %w[insert], 1 ], [ %w[list], 24 ], [ %w[list list], 12 ], [ %w[list list], 10 ] ]
  settle = [ [ %w[list], 1 ], [ %w[transition], 1 ], [ %w[list transition], 3 ] ]
  expand = ->(table) { table.flat_map { |keys, count| Array.new(count) { keys.sum { |key| costs.fetch(key) } } } }
  prep_calls = expand.call(prep)
  settle_calls = expand.call(settle)
  day = quota_day
  held = Array.new(16) do
    outcome = QuotaPolicy.reserve(day, daily_total: 10_000)
    day = outcome.day
    outcome.reservation
  end
  all_granted = true
  (prep_calls.map { |u| [ :prep, u ] } + settle_calls.map { |u| [ :settle, u ] }).each do |bucket, units|
    held = held.map do |reservation|
      outcome = QuotaPolicy.spend(reservation, bucket: bucket, units: units, day: day)
      all_granted &&= outcome.granted?
      day = outcome.day if outcome.granted?
      outcome.granted? ? outcome.reservation : reservation
    end
  end
  prep_calls.sum == 321 && settle_calls.sum == 204 && all_granted && day.used_units == 16 * 525 && day.used_units <= 9_000
end

puts "== 開始受付判定（StartAdmission）"
REASONS = %w[
  invalid_input not_logged_in rate_limited bot_check_failed broadcast_in_progress youtube_not_connected authorization_revoked
  live_not_enabled allowance_consumed attempts_exhausted intake_paused transfer_budget_exceeded capacity_full quota_insufficient
].freeze
NOW = utc(2026, 10, 7, 4, 30, 0)
RATE_RETRY = utc(2026, 10, 7, 4, 45, 0)

class Lazy
  attr_reader :calls

  def initialize(value)
    @value = value
    @calls = 0
  end

  def call
    @calls += 1
    @value
  end
end

# 基準（すべて通る）。reason を指定して、その理由が該当するように変える
class Case
  attr_accessor :input, :session_valid, :rate_limit, :verdict, :attrs, :quota, :settings
  attr_reader :bot, :snap

  def initialize
    @input = StartAdmission::Input.new(title: "live", privacy_status: "unlisted", made_for_kids: false)
    @session_valid = true
    @rate_limit = StartAdmission::RateLimit.within_limit
    @verdict = :pass
    @attrs = {
      usage_date: Date.new(2026, 10, 7), month_key: "2026-10", broadcast_in_progress: false, connection_state: "connected",
      consumed_count: 0, extra_grants: 0, attempt_count: 0, concurrent_count: 0, transfer_sent_bytes: 0
    }
    @quota = { quota_date: Date.new(2026, 10, 6), used_units: 0, reserved_units: 0, common_used_units: 0 }
    @settings = Settings.defaults
  end

  def violate(reason)
    case reason
    when "invalid_input" then @input = StartAdmission::Input.new(title: "", privacy_status: "unlisted", made_for_kids: false)
    when "not_logged_in" then @session_valid = false
    when "rate_limited" then @rate_limit = StartAdmission::RateLimit.exceeded_until(RATE_RETRY)
    when "bot_check_failed" then @verdict = :indeterminate
    when "broadcast_in_progress" then @attrs[:broadcast_in_progress] = true
    when "youtube_not_connected" then @attrs[:connection_state] = "not_connected"
    when "authorization_revoked" then @attrs[:connection_state] = "revoked"
    when "live_not_enabled" then @attrs[:connection_state] = "live_not_enabled"
    when "allowance_consumed" then @attrs[:consumed_count] = 1
    when "attempts_exhausted" then @attrs[:attempt_count] = 3
    when "intake_paused" then @settings = Settings.from_raw("intake_paused" => "true")
    when "transfer_budget_exceeded" then @attrs[:transfer_sent_bytes] = 10_000_000_000
    when "capacity_full" then @attrs[:concurrent_count] = 3
    when "quota_insufficient" then @quota[:reserved_units] = 8_451
    end
    self
  end

  def decide(now: NOW)
    @bot = Lazy.new(@verdict)
    @snap = Lazy.new(AccountSnapshot.new(**@attrs, quota_day: QuotaPolicy::Day.new(**@quota)))
    StartAdmission.decide(input: @input, session_valid: @session_valid, rate_limit: @rate_limit, bot_verdict: @bot,
                          snapshot: @snap, settings: @settings, now: now)
  end

  def calls
    [ @bot.calls, @snap.calls ]
  end
end

def expected_calls(index)
  return [ 0, 0 ] if index <= 2

  index == 3 ? [ 1, 0 ] : [ 1, 1 ]
end

check("判定順は、契約の rejection_reason（9.2 の順 0〜13）と同じ") do
  REASONS == enums_json.fetch("enums").fetch("rejection_reason").fetch("values") &&
    REASONS.each_with_index.all? { |reason, index| rejections_json.fetch("rejections").fetch(reason).fetch("order") == index }
end
check("受理: 利用日・割り当て日・予約額 550・適用される上限（時間上限 3,600 秒・プロファイルの範囲）") do
  accepted = Case.new.decide
  accepted.is_a?(Admission::Accepted) && accepted.usage_date == Date.new(2026, 10, 7) && accepted.quota_date == Date.new(2026, 10, 6) &&
    accepted.reservation_units == 550 && accepted.limits.time_limit_seconds == 3_600 &&
    accepted.limits.profiles.fetch("720p").fetch("video_bitrate_max_kbps") == 6_000 &&
    accepted.limits.profiles.fetch("480p").fetch("video_bitrate_min_kbps") == 800
end
check("14 の拒否理由: その理由だけが該当する入力で、その理由・区分（契約）・再試行の目安時刻が返る") do
  expected_retry = {
    "rate_limited" => "2026-10-07T13:45:00+09:00", "allowance_consumed" => "2026-10-08T03:00:00+09:00",
    "attempts_exhausted" => "2026-10-08T03:00:00+09:00", "transfer_budget_exceeded" => "2026-11-01T00:00:00+09:00",
    "quota_insufficient" => "2026-10-07T16:00:00+09:00"
  }
  REASONS.all? do |reason|
    result = Case.new.violate(reason).decide
    result.is_a?(Admission::Rejected) && result.reason == reason &&
      result.resolution == rejections_json.fetch("rejections").fetch(reason).fetch("resolution") &&
      result.retry_at&.iso8601 == expected_retry[reason]
  end
end
check("遅延評価: 順 0〜2 の拒否では bot 判定も現況も呼ばない。順 3 の拒否では現況を呼ばない。順 4 以降は 1 回ずつ") do
  REASONS.each_with_index.all? do |reason, index|
    scenario = Case.new.violate(reason)
    scenario.decide
    scenario.calls == expected_calls(index)
  end
end
check("複数該当は、最も早い順を返す（14 の理由の 2 つの組み合わせ 91 組から、同時に成り立たない 3 組を除く 88 組。呼び出し回数も）") do
  connection = %w[youtube_not_connected authorization_revoked live_not_enabled]
  pairs = (0...REASONS.size).to_a.combination(2).reject { |a, b| connection.include?(REASONS[a]) && connection.include?(REASONS[b]) }
  pairs.size == 88 && pairs.all? do |a, b|
    scenario = Case.new.violate(REASONS[b]).violate(REASONS[a])
    scenario.decide.reason == REASONS[a] && scenario.calls == expected_calls(a)
  end
end
check("順の入れ替わり: 満員（順 12）より利用枠消費済み（順 8）が先、API 割り当て不足（順 13）より満員が先") do
  Case.new.violate("capacity_full").violate("allowance_consumed").decide.reason == "allowance_consumed" &&
    Case.new.violate("quota_insufficient").violate("capacity_full").decide.reason == "capacity_full"
end
check("入力の検証（順 0）: 不備のある項目名を、すべて返す") do
  emoji = [ 0x1F600 ].pack("U")
  ideographic_space = [ 0x3000 ].pack("U")
  input = ->(title, privacy = "public", kids = true) { StartAdmission::Input.new(title: title, privacy_status: privacy, made_for_kids: kids) }
  fields = ->(candidate) { candidate.invalid_fields }
  fields.call(input.call("a")) == [] && fields.call(input.call("a" * 100)) == [] && fields.call(input.call(emoji * 100)) == [] &&
    fields.call(input.call(emoji * 101)) == %w[title] && fields.call(input.call("a<b")) == %w[title] &&
    fields.call(input.call("a>b")) == %w[title] && fields.call(input.call(" ")) == %w[title] &&
    fields.call(input.call(ideographic_space)) == %w[title] && fields.call(input.call("")) == %w[title] &&
    fields.call(input.call("a", "friends")) == %w[privacy_status] && fields.call(input.call("a", "private")) == [] &&
    fields.call(input.call("a", "unlisted", nil)) == %w[made_for_kids] &&
    fields.call(input.call("", "x", nil)) == %w[title privacy_status made_for_kids] &&
    Case.new.tap { |c| c.input = input.call("", "x", nil) }.decide.fields == %w[title privacy_status made_for_kids]
end
check("bot 判定: :pass 以外は拒否（判定不能を受理側へ倒さない）") do
  %i[fail indeterminate].all? do |verdict|
    scenario = Case.new
    scenario.verdict = verdict
    scenario.decide.reason == "bot_check_failed"
  end
end
check("各規則の境界: 利用枠（設定 + 追加 - 消費 <= 0）・開始試行（>= 上限）・同時配信数（>= 上限）・転送量（>= 予算）・API 割り当て（9,000）") do
  with = lambda do |attrs = {}, quota = {}, settings = {}|
    scenario = Case.new
    scenario.attrs.merge!(attrs)
    scenario.quota.merge!(quota)
    scenario.settings = Settings.from_raw(settings)
    scenario.decide
  end
  rejected = ->(result, reason) { result.is_a?(Admission::Rejected) && result.reason == reason }
  with.call.is_a?(Admission::Accepted) &&
    rejected.call(with.call({ consumed_count: 1 }), "allowance_consumed") &&
    with.call({ consumed_count: 1, extra_grants: 1 }).is_a?(Admission::Accepted) &&
    with.call({ attempt_count: 2 }).is_a?(Admission::Accepted) && rejected.call(with.call({ attempt_count: 3 }), "attempts_exhausted") &&
    with.call({ concurrent_count: 2 }).is_a?(Admission::Accepted) && rejected.call(with.call({ concurrent_count: 3 }), "capacity_full") &&
    with.call({ transfer_sent_bytes: 9_999_999_999 }).is_a?(Admission::Accepted) &&
    rejected.call(with.call({ transfer_sent_bytes: 10_000_000_000 }), "transfer_budget_exceeded") &&
    with.call({}, { reserved_units: 8_450 }).is_a?(Admission::Accepted) &&
    rejected.call(with.call({}, { reserved_units: 8_451 }), "quota_insufficient")
end
check("割り当て超過が返った日（exhausted）の開始受付は、API 割り当て不足（次の割り当て日の始まりを目安にする）") do
  scenario = Case.new
  scenario.quota[:exhausted] = true
  result = scenario.decide
  result.is_a?(Admission::Rejected) && result.reason == "quota_insufficient" && result.retry_at.iso8601 == "2026-10-07T16:00:00+09:00"
end
check("現況の日付: 判定の時刻の利用日・暦月・割り当て日のものでなければ、例外（古い現況で判定しない）") do
  scenario = Case.new
  scenario.attrs[:usage_date] = Date.new(2026, 10, 6)
  raises?(ArgumentError) { scenario.decide }
end
check("日付の境界: JST 02:59:59（利用日は前日）の利用枠消費済みは、1 秒後の JST 03:00 を目安にする") do
  scenario = Case.new.violate("allowance_consumed")
  scenario.attrs[:usage_date] = Date.new(2026, 10, 6)
  result = scenario.decide(now: jst(2026, 10, 7, 2, 59, 59))
  result.reason == "allowance_consumed" && result.retry_at.iso8601 == "2026-10-07T03:00:00+09:00"
end
check("出力は、ユーザーの識別情報・タイトルを含まない（受理・拒否・入力不備）") do
  secret = "SECRET-TITLE-0123456789"
  accepted = Case.new.tap { |c| c.input = StartAdmission::Input.new(title: secret, privacy_status: "unlisted", made_for_kids: false) }.decide
  rejected = Case.new.violate("capacity_full").tap { |c| c.input = StartAdmission::Input.new(title: secret, privacy_status: "unlisted", made_for_kids: false) }.decide
  invalid = Case.new.tap { |c| c.input = StartAdmission::Input.new(title: "<#{secret}>", privacy_status: "unlisted", made_for_kids: false) }.decide
  input_text = StartAdmission::Input.new(title: secret, privacy_status: "unlisted", made_for_kids: false).inspect
  [ accepted, rejected, invalid ].none? { |result| result.inspect.include?("SECRET") || result.to_h.to_s.include?("SECRET") } &&
    !input_text.include?("SECRET")
end

puts "== 不変・純粋"
check("結果と値オブジェクトは凍結されている") do
  case_result = Case.new.decide
  [ case_result, Settings.defaults, quota_day, QuotaPolicy.reserve(quota_day, daily_total: 10_000), UsageCalendar.usage_date(NOW),
    UsageCalendar.next_usage_date_start(NOW), UsageCalendar.month_key(NOW) ].all?(&:frozen?)
end
check("同じ入力に同じ出力（受理・拒否）") do
  Case.new.decide == Case.new.decide && Case.new.violate("capacity_full").decide == Case.new.violate("capacity_full").decide
end

puts
puts "確認した項目: #{CHECKED.size} 件、失敗: #{FAILURES.size} 件"
if FAILURES.empty?
  puts "PASS 受け入れの確認はすべて成功しました"
  exit 0
end
puts "FAIL 失敗した項目:"
FAILURES.each { |label| puts "  - #{label}" }
exit 1
