# frozen_string_literal: true

# 変異テスト（issue #9 のサービス）。コンテナの /tmp に、アプリケーションの複製を 1 つ作り、サービスの実装を 1 か所ずつ壊して、
# 対応するスペックが失敗する（変異を検出する）ことを確かめる。スペックが、振る舞いの退行（ロックの欠落・冪等性の欠落・枠の取り崩し・
# 暦月や割り当て日の誤り・フォールバックなど）を見逃さないことの確認。
# 共有の作業ツリー（/app）は書き換えない。変異は、複製の中だけに入れる。作業用の複製は、コンテナの /tmp に残す（削除しない）。
#
# 使い方（run_all.sh --with-mutation が実行する。数分かかる）:
#   scripts/dc.sh exec -T -e ISSUE09_MUTATION_DB=bl_test_... backend ruby - < test/pr45/mutate_services.rb
# 前提: ISSUE09_MUTATION_DB は、スキーマを読み込み済みのテスト用 DB の名前（bl_test_ で始まる）。複製のスペックは、そこへ書く
#       （同時の操作のスペックは、実際にコミットし、各例の前後で、自分の行を整理する）。
# 終了コード: 0 = すべての変異を検出 / 1 = 見逃し、または適用できない変異がある / 2 = 前提を満たさない
require "fileutils"
require "open3"

ROOT = ENV.fetch("ISSUE09_APP_ROOT", "/app")
DATABASE = ENV.fetch("ISSUE09_MUTATION_DB", "")
unless DATABASE.match?(/\Abl_test_[a-z0-9_]+\z/)
  warn "FAIL ISSUE09_MUTATION_DB（#{DATABASE.inspect}）が、テスト用の DB の名前（bl_test_...）ではありません"
  exit 2
end
base_url = ENV.fetch("DATABASE_URL", "")
unless base_url.end_with?("/bl_development")
  warn "FAIL コンテナの DATABASE_URL が、開発 DB（.../bl_development）を指していません。テスト用の URL は、これを元に組み立てます"
  exit 2
end
DATABASE_URL = "#{base_url.delete_suffix('/bl_development')}/#{DATABASE}".freeze

STAMP = Time.now.strftime("%H%M%S")
COPY = "/tmp/issue9_mut_#{STAMP}"

# 複製に含めるもの（依存の gem は、/app の Gemfile と vendor を、そのまま使う）
FileUtils.mkdir_p(COPY)
%w[ app config db lib bin spec ].each do |entry|
  source = "#{ROOT}/#{entry}"
  FileUtils.cp_r(source, "#{COPY}/") if File.exist?(source)
end
%w[ Gemfile Gemfile.lock Rakefile config.ru .rspec .rubocop.yml ].each do |name|
  FileUtils.cp("#{ROOT}/#{name}", "#{COPY}/#{name}") if File.exist?("#{ROOT}/#{name}")
end
FileUtils.mkdir_p("#{COPY}/tmp")
FileUtils.mkdir_p("#{COPY}/log")

ENVIRONMENT = { "RAILS_ENV" => "test", "DATABASE_URL" => DATABASE_URL, "BUNDLE_GEMFILE" => "#{ROOT}/Gemfile" }.freeze

def run_rspec(files)
  output, = Open3.capture2e(ENVIRONMENT, "bundle", "exec", "rspec", *files, "--no-color", "--seed", "1", chdir: COPY)
  summary = output.lines.reverse.find { |line| line.match?(/\d+ examples?, \d+ failures?/) }
  load_error = output.include?("error occurred outside of examples") || output.include?("errors occurred outside of examples")
  [ summary&.strip || "NO SUMMARY: #{output.lines.last(3).join.strip}", load_error, output ]
end

SPEC = lambda do |*names|
  names.map { |name| "spec/services/#{name}.rb" }
end

# [ 説明, app/services からの相対パス, 置換前, 置換後, 実行するスペック ]
MUTATIONS = [
  [ "spend! が、枠の指定を無視して、常に準備・確認枠から取り崩す", "quota_ledger.rb",
    "QuotaPolicy.spend(Rows.reservation_value(locked), bucket: bucket, units: units, day: Rows.day_value(day_row))",
    "QuotaPolicy.spend(Rows.reservation_value(locked), bucket: :prep, units: units, day: Rows.day_value(day_row))",
    SPEC.call("quota_ledger_spend_spec") ],
  [ "release! が、残額の無い配信でも解放として扱う（二重の解放）", "quota_ledger.rb",
    "      return false if reservation.remaining_units.zero?\n\n      day_row = Rows.lock_day!(locked.quota_date)\n      outcome = QuotaPolicy.release",
    "      day_row = Rows.lock_day!(locked.quota_date)\n      outcome = QuotaPolicy.release",
    SPEC.call("quota_ledger_carry_release_spec") ],
  [ "解放が、台帳の予約中から引かない", "quota_ledger.rb",
    "      outcome = QuotaPolicy.release(reservation, day: Rows.day_value(day_row))\n\n      Rows.store_day!(day_row, outcome.day)\n",
    "      outcome = QuotaPolicy.release(reservation, day: Rows.day_value(day_row))\n\n",
    SPEC.call("quota_ledger_carry_release_spec", "quota_ledger_invariants_spec") ],
  [ "予約が、時計のずれで、後戻りする（移し替えの条件を緩める）", "quota_ledger.rb",
    "      return false unless target_date > locked.quota_date\n", "      return false if target_date == locked.quota_date\n",
    SPEC.call("quota_ledger_carry_release_spec") ],
  [ "spend! が、割り当て日をまたいでも、移し替えない", "quota_ledger.rb",
    "        move_reservation!(locked, UsageCalendar.quota_date(now))\n", "",
    SPEC.call("quota_ledger_carry_release_spec") ],
  [ "割り当て日を、UTC の日付で決める（太平洋時間でない）", "quota_ledger.rb",
    "move_reservation!(locked, UsageCalendar.quota_date(now))", "move_reservation!(locked, now.utc.to_date)",
    SPEC.call("quota_ledger_carry_release_spec") ],
  [ "reserve! が、状態 reserved の検査を省く", "quota_ledger.rb",
    "      unless locked.state == Contract::BroadcastState::RESERVED\n", "      if false\n",
    SPEC.call("quota_ledger_reserve_spec") ],
  [ "reserve! が、配信に使える上限を 1 本分大きく見る", "quota_ledger.rb",
    "QuotaPolicy.reserve(Rows.day_value(day_row), daily_total: daily_total)",
    "QuotaPolicy.reserve(Rows.day_value(day_row), daily_total: daily_total + QuotaPolicy::RESERVATION_UNITS)",
    SPEC.call("quota_ledger_reserve_spec") ],
  [ "共通枠の明細を、準備・確認枠として記帳する", "quota_ledger.rb",
    "bucket: Arguments::COMMON_BUCKET, called_at: now)", "bucket: \"prep\", called_at: now)",
    SPEC.call("quota_ledger_spend_spec") ],
  [ "台帳の行を、ロックせずに読む（同時の予約・記帳が、更新を失う）", "quota_ledger/rows.rb",
    "QuotaDay.lock.find(quota_date)", "QuotaDay.find(quota_date)",
    SPEC.call("quota_ledger_concurrency_spec") ],
  [ "配信の行を、ロックせずに読む（同じ配信への同時の支出・解放・移し替えが、二重になる）", "quota_ledger/rows.rb",
    "Broadcast.owned_by(broadcast.user_id).lock.find(broadcast.id)", "Broadcast.owned_by(broadcast.user_id).find(broadcast.id)",
    SPEC.call("quota_ledger_concurrency_spec") ],
  [ "明細の method の形の検査を緩める（タイトル・トークンの形を通す）", "quota_ledger/arguments.rb",
    "METHOD_PATTERN = /\\A[A-Za-z][A-Za-z0-9_.]{0,63}\\z/", "METHOD_PATTERN = /\\A.{1,200}\\z/m",
    SPEC.call("quota_ledger_spend_spec") ],
  [ "配信の行を確保するトランザクションが、保存点を作る（requires_new）", "quota_ledger.rb",
    "      result = ApplicationRecord.transaction do\n        locked = Rows.lock_broadcast!(broadcast)\n",
    "      result = ApplicationRecord.transaction(requires_new: true) do\n        locked = Rows.lock_broadcast!(broadcast)\n",
    SPEC.call("quota_ledger_reserve_spec", "service_sources_spec") ],
  [ "実時計（Time.now）を読む", "quota_ledger.rb",
    "      QuotaDay.upsert_all(\n", "      Time.now\n      QuotaDay.upsert_all(\n",
    SPEC.call("service_sources_spec") ],
  [ "契約の固定値 550 を直書きする", "quota_ledger/arguments.rb",
    "return units if units == QuotaPolicy::RESERVATION_UNITS", "return units if units == 550",
    SPEC.call("service_sources_spec") ],
  [ "consume! が、消費済みの印を見ない（二重の消費）", "daily_allowance.rb",
    "      return false if locked.allowance_consumed\n", "",
    SPEC.call("daily_allowance_spec", "daily_allowance_concurrency_spec") ],
  [ "count_attempt! が、開始試行の上限を見ない", "daily_allowance.rb",
    "      left = attempts_left(usage, settings)\n      if left < 1", "      left = attempts_left(usage, settings)\n      if false",
    SPEC.call("daily_allowance_spec") ],
  [ "consume!・count_attempt! が、利用枠の行をロックせずに読む（上限の同時の判定）", "daily_allowance.rb",
    "        usage = DailyUsage.owned_by(broadcast.user_id).lock.find(broadcast.daily_usage_id)\n        locked = lock_broadcast!(broadcast, usage)\n        yield locked, usage",
    "        usage = DailyUsage.owned_by(broadcast.user_id).find(broadcast.daily_usage_id)\n        locked = lock_broadcast!(broadcast, usage)\n        yield locked, usage",
    SPEC.call("daily_allowance_concurrency_spec") ],
  [ "ensure_for! が、行をロックしない", "daily_allowance.rb",
    "DailyUsage.owned_by(owner).lock.find_by!(usage_date: usage_date)", "DailyUsage.owned_by(owner).find_by!(usage_date: usage_date)",
    SPEC.call("daily_allowance_spec") ],
  [ "grant_extra! が、開始試行を 0 に戻さない", "daily_allowance.rb",
    "extra_grants = daily_usages.extra_grants + 1, attempt_count = 0", "extra_grants = daily_usages.extra_grants + 1",
    SPEC.call("daily_allowance_spec") ],
  [ "TransferBudget.add! が、加算でなく上書きする", "transfer_budget.rb",
    "sent_bytes = transfer_months.sent_bytes + EXCLUDED.sent_bytes", "sent_bytes = EXCLUDED.sent_bytes",
    SPEC.call("transfer_budget_spec", "transfer_budget_concurrency_spec") ],
  [ "add_for_broadcast! が、UTC の暦月を使う（JST でない）", "transfer_budget.rb",
    "month_key = UsageCalendar.month_key(now)", "month_key = now.utc.strftime(\"%Y-%m\")",
    SPEC.call("transfer_budget_spec") ],
  [ "exceeded? が、積算より 1 バイト少なく判定する", "transfer_budget.rb",
    "sent_bytes: sent_bytes(month_key: month_key),", "sent_bytes: sent_bytes(month_key: month_key) - 1,",
    SPEC.call("transfer_budget_spec") ],
  [ "SettingsStore.current が、結果を覚える（キャッシュ）", "settings_store.rb",
    "      Settings.from_raw(SystemSetting.pluck(:key, :value).to_h)\n    rescue", "      @cache ||= Settings.from_raw(SystemSetting.pluck(:key, :value).to_h)\n    rescue",
    SPEC.call("settings_store_spec") ],
  [ "SettingsStore.current が、壊れた値を既定値へ戻す（フォールバック）", "settings_store.rb",
    "    rescue Settings::InvalidSetting => e\n      raise CorruptSetting.new(key: e.key, reason: e.reason)", "    rescue Settings::InvalidSetting\n      Settings.defaults",
    SPEC.call("settings_store_spec") ]
].freeze

# 複製の中のファイルを書き換える。見つからなければ、適用できない変異
def apply(relative_path, old, new)
  path = "#{COPY}/app/services/#{relative_path}"
  text = File.read(path, encoding: "UTF-8")
  return nil unless text.include?(old)

  File.write(path, text.sub(old) { new })
  text
end

baseline_files = MUTATIONS.flat_map(&:last).uniq
baseline, baseline_load_error, baseline_output = run_rspec(baseline_files)
puts "baseline（変異を入れる前の複製）: #{baseline}"
unless baseline.match?(/ 0 failures/) && !baseline_load_error
  puts baseline_output.lines.last(30).join
  puts "FAIL 変異を入れる前の複製で、スペックが失敗しています。変異の検査を中止します"
  exit 1
end

survivors = []
MUTATIONS.each_with_index do |(label, relative_path, old, new, files), index|
  number = format("M%02d", index + 1)
  original = apply(relative_path, old, new)
  if original.nil?
    puts "#{number} #{label}: 変異を適用できません（#{relative_path} に該当の文字列がありません）"
    survivors << "#{number} #{label}（適用できない）"
    next
  end
  begin
    result, load_error, = run_rspec(files)
  ensure
    File.write("#{COPY}/app/services/#{relative_path}", original)
  end
  failures = result[/(\d+) failures?/, 1].to_i
  detected = failures.positive? || load_error
  puts "#{number} #{label}: #{detected ? "検出（#{failures} 件失敗）" : '見逃し'}  [#{result}]"
  survivors << "#{number} #{label}（見逃し）" unless detected
end

puts
puts "変異 #{MUTATIONS.size} 件のうち、検出 #{MUTATIONS.size - survivors.size} 件、見逃し・適用不可 #{survivors.size} 件（作業用の複製: #{COPY}。削除しません）"
if survivors.empty?
  puts "PASS すべての変異を検出しました"
  exit 0
end
survivors.each { |line| puts "  - #{line}" }
exit 1
