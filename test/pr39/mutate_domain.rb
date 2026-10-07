# frozen_string_literal: true

# 変異テスト（issue #5 の Domain Core）。コンテナの /tmp に、app/domain とスペックの複製を作り、実装を 1 か所ずつ壊して、
# スペックが失敗する（変異を検出する）ことを確かめる。スペックが、振る舞いの退行を見逃さないことの確認。
# 変異ごとに、新しい名前の複製を作る（作業用の複製は、削除しない。コンテナの /tmp にある）。
#   例: 割り当て日を UTC-8 の固定にする・判定順を入れ替える・境界の不等号を変える・枠の取り崩しを許す・フォールバックを入れる
#
# 使い方（run_all.sh --with-mutation が実行する。数分かかる）:
#   scripts/dc.sh exec -T backend ruby - < test/pr39/mutate_domain.rb
# 終了コード: 0 = すべての変異を検出 / 1 = 見逃し、または適用できない変異がある
require "fileutils"
require "open3"

ROOT = ENV.fetch("ISSUE05_APP_ROOT", "/app")
STAMP = Time.now.strftime("%H%M%S")
BASE = "/tmp/mut_#{STAMP}_base"

MY_APP = %w[preconditions.rb usage_calendar.rb settings.rb settings transfer_budget_policy.rb quota_policy.rb quota_policy
            account_snapshot.rb admission.rb admission start_admission.rb start_admission contract].freeze

# この issue のスペック（ほかの issue のスペックは、複製に含めない）
MY_SPECS = %w[domain_loader_spec.rb usage_calendar_spec.rb settings_spec.rb transfer_budget_policy_spec.rb quota_policy_spec.rb
              quota_policy_simulation_spec.rb account_snapshot_spec.rb admission_spec.rb start_admission_input_spec.rb
              start_admission_spec.rb domain_rules_spec.rb domain_core_rules_spec.rb app_domain_loading_spec.rb].freeze

FileUtils.mkdir_p("#{BASE}/app/domain")
FileUtils.mkdir_p("#{BASE}/spec/domain")
FileUtils.mkdir_p("#{BASE}/tmp")
MY_APP.each { |entry| FileUtils.cp_r("#{ROOT}/app/domain/#{entry}", "#{BASE}/app/domain/") }
FileUtils.cp_r("#{ROOT}/spec/domain/support", "#{BASE}/spec/domain/")
FileUtils.cp_r("#{ROOT}/spec/domain/contract", "#{BASE}/spec/domain/")
MY_SPECS.each { |name| FileUtils.cp("#{ROOT}/spec/domain/#{name}", "#{BASE}/spec/domain/") }
FileUtils.cp("#{ROOT}/spec/spec_helper.rb", "#{BASE}/spec/")
FileUtils.cp("#{ROOT}/.rspec", BASE)

def run_rspec(dir)
  env = { "BUNDLE_GEMFILE" => "#{ROOT}/Gemfile" }
  output, = Open3.capture2e(env, "bundle", "exec", "rspec", "spec/domain", "--no-color", "--seed", "1", chdir: dir)
  line = output.lines.reverse.find { |l| l.match?(/\d+ examples?, \d+ failures?/) }
  line ? line.strip : "NO SUMMARY: #{output.lines.last(3).join}"
end

baseline = run_rspec(BASE)
puts "baseline: #{baseline}"
unless baseline.match?(/ 0 failures/)
  puts "FAIL 変異を入れる前の複製で、スペックが失敗しています。変異の検査を中止します"
  exit 1
end

MUTATIONS = [
  [ "usage_date の区切りを 2 時にする", "usage_calendar.rb", "local.hour < USAGE_DAY_START_HOUR", "local.hour < 2" ],
  [ "割り当て日を UTC-8 の固定で計算する", "usage_calendar.rb", "calendar_date(QUOTA_ZONE.to_local(utc_of(time))).freeze", "calendar_date(utc_of(time) - 28_800).freeze" ],
  [ "割り当て日を UTC-7 の固定で計算する", "usage_calendar.rb", "calendar_date(QUOTA_ZONE.to_local(utc_of(time))).freeze", "calendar_date(utc_of(time) - 25_200).freeze" ],
  [ "次の利用日の始まりを同じ日にする", "usage_calendar.rb", "local_start(JST, usage_date(time).next_day, USAGE_DAY_START_HOUR)", "local_start(JST, usage_date(time), USAGE_DAY_START_HOUR)" ],
  [ "暦月を 03:00 区切りにする", "usage_calendar.rb", "local = JST.to_local(utc_of(time))\n      format(", "local = JST.to_local(utc_of(time) - 10_800)\n      format(" ],
  [ "次の割り当て日の始まりを 2 日後にする", "usage_calendar.rb", "local_start(QUOTA_ZONE, quota_date(time).next_day, 0)", "local_start(QUOTA_ZONE, quota_date(time).next_day.next_day, 0)" ],
  [ "実時計を呼ぶ", "usage_calendar.rb", "def to_jst(time)\n      jst_time(utc_of(time))", "def to_jst(time)\n      Time.now\n      jst_time(utc_of(time))" ],
  [ "規則を逆順に評価する（最後に該当した理由を返す）", "start_admission/state_rules.rb", "RULES.find {", "RULES.reverse.find {" ],
  [ "満員（順 12）と API 割り当て不足（順 13）の順を入れ替える", "start_admission/state_rules.rb", "RULES.find {", "RULES.values_at(0, 1, 2, 3, 4, 5, 6, 7, 9, 8).find {" ],
  [ "利用枠消費済み（順 8）と満員（順 12）の順を入れ替える", "start_admission/state_rules.rb", "RULES.find {", "RULES.values_at(0, 1, 2, 3, 8, 5, 6, 7, 4, 9).find {" ],
  [ "利用枠の判定を < 0 にする", "start_admission/state_rules.rb", "snapshot.consumed_count <= 0", "snapshot.consumed_count < 0" ],
  [ "開始試行の判定を > にする", "start_admission/state_rules.rb", "snapshot.attempt_count >= settings.attempt_limit", "snapshot.attempt_count > settings.attempt_limit" ],
  [ "同時配信数の判定を > にする", "start_admission/state_rules.rb", "snapshot.concurrent_count >= settings.concurrent_limit", "snapshot.concurrent_count > settings.concurrent_limit" ],
  [ "転送量の判定を > にする", "transfer_budget_policy.rb", "sent_bytes >= budget_gb * BYTES_PER_GB", "sent_bytes > budget_gb * BYTES_PER_GB" ],
  [ "1 GB を 2 進（1,073,741,824）にする", "transfer_budget_policy.rb", "BYTES_PER_GB = 1_000_000_000", "BYTES_PER_GB = 1_073_741_824" ],
  [ "予約の判定を < にする", "quota_policy.rb", "units <= usable_units(daily_total: daily_total)", "units < usable_units(daily_total: daily_total)" ],
  [ "予約の判定に共通枠の使用済みを含める", "quota_policy.rb", "day.used_units + day.reserved_units + units <=", "day.used_units + day.reserved_units + day.common_used_units + units <=" ],
  [ "支出で、枠の残額ではなく、予約の残額の合計と比べる（別の枠から取り崩す）", "quota_policy.rb", "if units > reservation.remaining(bucket)", "if units > reservation.remaining_units" ],
  [ "解放で、予約中から引かない", "quota_policy.rb", "day: day.with(reserved_units: day.reserved_units - reservation.remaining_units),", "day: day,", ],
  [ "移し替えで、新しい割り当て日へ足さない", "quota_policy.rb", "to: to.with(reserved_units: to.reserved_units + remaining),", "to: to," ],
  [ "共通枠の判定を >= にする", "quota_policy.rb", "day.common_used_units + units > COMMON_UNITS", "day.common_used_units + units >= COMMON_UNITS" ],
  [ "割り当て日の不一致を検査しない", "quota_policy.rb", "return if reservation.quota_date == day.quota_date", "return" ],
  [ "現況の日付の検査をしない", "start_admission.rb", "check_fresh!(account, now)\n      account", "account" ],
  [ "判定不能（:indeterminate）を合格として扱う", "start_admission.rb", "verdict == :pass", "verdict != :fail" ],
  [ "bot 判定を、セッションの検査より前に呼ぶ", "start_admission.rb", "      return reject(Contract::RejectionReason::NOT_LOGGED_IN, now, rate_limit) unless session_valid\n", "      bot_passed?(bot_verdict)\n      return reject(Contract::RejectionReason::NOT_LOGGED_IN, now, rate_limit) unless session_valid\n" ],
  [ "受理の予約額を準備・確認枠だけにする", "start_admission.rb", "reservation_units: QuotaPolicy::RESERVATION_UNITS,", "reservation_units: QuotaPolicy::PREP_UNITS," ],
  [ "タイトルの上限を 101 文字にする", "start_admission/input.rb", "TITLE_LENGTH = (1..100)", "TITLE_LENGTH = (1..101)" ],
  [ "山括弧の > を検査しない", "start_admission/input.rb", "ANGLE_BRACKETS = /[<>]/", "ANGLE_BRACKETS = /[<]/" ],
  [ "公開範囲から private を外す", "start_admission/input.rb", "PRIVACY_STATUSES = %w[public unlisted private].freeze", "PRIVACY_STATUSES = %w[public unlisted].freeze" ],
  [ "空白だけのタイトルを許す", "start_admission/input.rb", "&& !title.match?(BLANK)", "" ],
  [ "設定の利用枠の下限を -1 にする", "settings/rules.rb", "DAILY_ALLOWANCE => Rule.new(type: :integer, min: 0, max: INT32_MAX)", "DAILY_ALLOWANCE => Rule.new(type: :integer, min: -1, max: INT32_MAX)" ],
  [ "bot 判定の閾値の上限を 2.0 にする", "settings/rules.rb", "Rule.new(type: :float, min: 0.0, max: 1.0)", "Rule.new(type: :float, min: 0.0, max: 2.0)" ],
  [ "設定の不正な値を既定値へ戻す（フォールバック）", "settings.rb", "Rules.check!(key, value)\n        [ key.to_sym, value ]", "begin\n          Rules.check!(key, value)\n        rescue InvalidSetting\n          value = default_values.fetch(key.to_sym)\n        end\n        [ key.to_sym, value ]" ],
  [ "拒否の再試行の目安時刻を JST にそろえない", "admission/rejected.rb", "UsageCalendar.to_jst(retry_at)", "retry_at" ],
  [ "利用枠消費済みの再試行の目安を翌月 1 日にする", "start_admission/retry_at.rb", "\"next_usage_day_start\" => ->(now, _rate_limit) { UsageCalendar.next_usage_date_start(now) }", "\"next_usage_day_start\" => ->(now, _rate_limit) { UsageCalendar.next_month_start(now) }" ],
  [ "暦月の形で 13 月を許す", "account_snapshot.rb", "(0[1-9]|1[0-2])", "(0[1-9]|1[0-3])" ],
  [ "割り当て超過の日（exhausted）でも予約できるようにする", "quota_policy.rb", "return false if day.exhausted", "" ],
  [ "契約の固定値 550 を直書きする", "quota_policy.rb", "RESERVATION_UNITS = Contract::Limits::QUOTA.fetch(\"broadcast_reservation_units\")", "RESERVATION_UNITS = 550" ]
].freeze

survivors = []
MUTATIONS.each_with_index do |(label, file, old, new), index|
  dir = "#{BASE.sub('_base', '')}_m#{format('%02d', index + 1)}"
  FileUtils.cp_r(BASE, dir)
  path = "#{dir}/app/domain/#{file}"
  text = File.read(path, encoding: "UTF-8")
  unless text.include?(old)
    puts "M#{index + 1} #{label}: 変異を適用できません（#{file} に該当の文字列がありません）"
    survivors << "M#{index + 1} #{label}（適用できない）"
    next
  end
  File.write(path, text.sub(old) { new })
  result = run_rspec(dir)
  failures = result[/(\d+) failures?/, 1].to_i
  status = failures.positive? ? "検出（#{failures} 件失敗）" : "見逃し"
  puts "M#{index + 1} #{label}: #{status}  [#{result}]"
  survivors << "M#{index + 1} #{label}（見逃し）" unless failures.positive?
end

puts
puts "変異 #{MUTATIONS.size} 件のうち、検出 #{MUTATIONS.size - survivors.size} 件、見逃し・適用不可 #{survivors.size} 件"
if survivors.empty?
  puts "PASS すべての変異を検出しました"
  exit 0
end
survivors.each { |line| puts "  - #{line}" }
puts "FAIL 見逃し・適用できない変異があります"
exit 1
