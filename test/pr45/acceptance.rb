# frozen_string_literal: true

# 受け入れの確認（issue #9「アプリケーション: 利用枠・開始試行・割り当て台帳・転送量・設定の DB 実装」）。
# 黒箱: RSpec を使わず、公開の API（DailyAllowance・QuotaLedger・TransferBudget・SettingsStore）だけを呼び、
# issue の受け入れ条件を、1 項目ずつ確かめる。台帳の値は、モデルを介さない SQL で読み、明細と配信の残額から独立に再計算して比べる。
# 実装担当のスペックとは別に、issue の本文から書き起こしたもの。
#
# 対象は、開発サーバーの backend コンテナの中の、使い捨てのテスト用 DB（run_all.sh が、DATABASE_URL をそちらへ向けて実行する）。
# どの確認も、トランザクションの中で行い、最後に巻き戻す（DB に残さない）。同時の操作は、stress.rb が確かめる。
#
# 使い方（run_all.sh が実行する）:
#   scripts/dc.sh exec -T -e ... backend bundle exec ruby - < test/pr45/acceptance.rb
# 終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 前提を満たさない（DB が、テスト用でない など）
require "securerandom"

ENV["RAILS_ENV"] = "test"
ROOT = ENV.fetch("ISSUE09_APP_ROOT", "/app")
require "#{ROOT}/config/environment"

database = ActiveRecord::Base.connection_db_config.database
unless database.to_s.match?(/\Abl_test_[a-z0-9_]+\z/)
  warn "FAIL 接続先の DB（#{database.inspect}）が、テスト用の名前（bl_test_...）ではありません。中止します"
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

def raises?(klass = StandardError)
  yield
  false
rescue klass
  true
end

# ブロックを、トランザクションの中で実行し、最後に必ず巻き戻す（DB に残さない）
def scratch
  ActiveRecord::Base.transaction do
    yield
    raise ActiveRecord::Rollback
  end
end

# モデルを介さない SQL（台帳の値の読み取り）
def sql(statement)
  ActiveRecord::Base.with_connection { |connection| connection.select_value(statement) }
end

def sql_rows(statement)
  ActiveRecord::Base.with_connection { |connection| connection.select_rows(statement) }
end

# ブロックの中で実行された SQL の文（トランザクションの制御を含む）
def sql_log
  statements = []
  callback = ->(*, payload) { statements << payload.fetch(:sql) unless payload[:name] == "SCHEMA" }
  ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
  statements
end

def new_user
  User.create!(google_sub: "dummy-acceptance-#{SecureRandom.hex(8)}", last_login_at: Time.current)
end

def new_usage(user, date)
  DailyUsage.create!(user: user, usage_date: date)
end

# 受理直後の配信（状態 reserved・予約の枠 0・0）。アカウントと利用日の行は、新しく作る
def new_broadcast(quota_date:, user: new_user, usage_date: quota_date, usage: nil, **extra)
  usage ||= new_usage(user, usage_date)
  Broadcast.create!(
    { user: user, daily_usage: usage, state: "reserved", usage_date: usage.usage_date, quota_date: quota_date,
      privacy_status: "unlisted", made_for_kids: false, accepted_at: Time.current }.merge(extra)
  )
end

def reserved_broadcast(quota_date:, daily_total: 10_000)
  new_broadcast(quota_date: quota_date).tap do |broadcast|
    raise "予約を断られました" unless QuotaLedger.reserve!(broadcast, quota_date: quota_date, daily_total: daily_total)
  end
end

# 保存された台帳の 1 日（SQL）
def day_row(quota_date)
  row = sql_rows("SELECT used_units, reserved_units, common_used_units, exhausted FROM quota_days WHERE quota_date = '#{quota_date}'").first
  row && { used: row[0], reserved: row[1], common: row[2], exhausted: row[3] }
end

# 明細と配信の残額から、独立に再計算した台帳の 1 日（SQL）
def recomputed_day(quota_date)
  used = sql("SELECT COALESCE(SUM(units), 0) FROM quota_entries WHERE quota_date = '#{quota_date}' AND bucket IN ('prep', 'settle')")
  common = sql("SELECT COALESCE(SUM(units), 0) FROM quota_entries WHERE quota_date = '#{quota_date}' AND bucket = 'common'")
  reserved = sql("SELECT COALESCE(SUM(prep_reserved_units + settle_reserved_units), 0) FROM broadcasts WHERE quota_date = '#{quota_date}'")
  { used: used, reserved: reserved, common: common }
end

def ledger_consistent?(*dates)
  dates.all? do |date|
    stored = day_row(date)
    stored.nil? ? recomputed_day(date).values.all?(&:zero?) : stored.slice(:used, :reserved, :common) == recomputed_day(date)
  end
end

def broadcast_row(broadcast)
  row = sql_rows("SELECT prep_reserved_units, settle_reserved_units, quota_date FROM broadcasts WHERE id = '#{broadcast.id}'").first
  { prep: row[0], settle: row[1], quota_date: row[2].to_s }
end

def usage_row(usage)
  row = sql_rows("SELECT consumed_count, attempt_count, extra_grants FROM daily_usages WHERE id = '#{usage.id}'").first
  { consumed: row[0], attempts: row[1], extra: row[2] }
end

def signature?(owner, name, positional:, required:, optional: [])
  parameters = owner.method(name).parameters
  parameters.count { |type, _| type == :req } == positional &&
    parameters.select { |type, _| type == :keyreq }.map(&:last).sort == required.sort &&
    parameters.select { |type, _| type == :key }.map(&:last).sort == optional.sort &&
    parameters.none? { |type, _| %i[opt rest keyrest block].include?(type) }
end

SETTINGS = Settings.defaults
DAY = Date.new(2026, 10, 7) # 割り当て日（太平洋時間の日付。夏時間）
NEXT_DAY = DAY + 1

def noon_of(date)
  ActiveSupport::TimeZone["America/Los_Angeles"].local(date.year, date.month, date.day, 12).utc
end

puts "== 公開の API の形（issue の受け入れ条件のシグネチャ）"
check("DailyAllowance: remaining・attempts_remaining(user_id:, usage_date:, settings:)") do
  %i[remaining attempts_remaining].all? { |name| signature?(DailyAllowance, name, positional: 0, required: %i[user_id usage_date settings]) }
end
check("DailyAllowance: ensure_for!・grant_extra!(user_id:, usage_date:)") do
  %i[ensure_for! grant_extra!].all? { |name| signature?(DailyAllowance, name, positional: 0, required: %i[user_id usage_date]) }
end
check("DailyAllowance: consume!・count_attempt!(broadcast)（設定は、省くと毎回 DB から読む）") do
  %i[consume! count_attempt!].all? { |name| signature?(DailyAllowance, name, positional: 1, required: [], optional: %i[settings]) }
end
check("QuotaLedger: reserve!(broadcast, quota_date:, units:, daily_total:)") do
  signature?(QuotaLedger, :reserve!, positional: 1, required: %i[quota_date daily_total], optional: %i[units])
end
check("QuotaLedger: spend!(broadcast, method:, units:, bucket:, result:)") do
  signature?(QuotaLedger, :spend!, positional: 1, required: %i[method units bucket result], optional: %i[now])
end
check("QuotaLedger: spend_common!(method:, units:, quota_date:)") do
  signature?(QuotaLedger, :spend_common!, positional: 0, required: %i[method units quota_date], optional: %i[result now])
end
check("QuotaLedger: carry_over!(broadcast, quota_date:)・release!(broadcast)・mark_exhausted!(quota_date:)") do
  signature?(QuotaLedger, :carry_over!, positional: 1, required: %i[quota_date]) &&
    signature?(QuotaLedger, :release!, positional: 1, required: []) &&
    signature?(QuotaLedger, :mark_exhausted!, positional: 0, required: %i[quota_date])
end
check("TransferBudget: add!(month_key:, bytes:)・exceeded?(month_key:, settings:)・add_for_broadcast!(broadcast, delta_bytes:, now:)") do
  signature?(TransferBudget, :add!, positional: 0, required: %i[month_key bytes]) &&
    signature?(TransferBudget, :exceeded?, positional: 0, required: %i[month_key settings]) &&
    signature?(TransferBudget, :add_for_broadcast!, positional: 1, required: %i[delta_bytes now])
end
check("SettingsStore: current・update!(key:, value:)") do
  signature?(SettingsStore, :current, positional: 0, required: []) && signature?(SettingsStore, :update!, positional: 0, required: %i[key value])
end

puts "== DailyAllowance（利用枠・開始試行）"
check("remaining: 行が無ければ 0 件（既定の利用枠 1 回）。読み取りは、行を作らない") do
  scratch do
    user = new_user
    return_value = DailyAllowance.remaining(user_id: user.id, usage_date: DAY, settings: SETTINGS)
    raise "残りが違う: #{return_value}" unless return_value == 1 && sql("SELECT COUNT(*) FROM daily_usages WHERE user_id = '#{user.id}'").zero?
  end
  true
end
check("remaining: 利用枠 + 追加の付与 - 消費（下限 0）") do
  scratch do
    user = new_user
    usage = new_usage(user, DAY)
    usage.update!(consumed_count: 1)
    values = [ DailyAllowance.remaining(user_id: user.id, usage_date: DAY, settings: SETTINGS) ]
    usage.update!(extra_grants: 1)
    values << DailyAllowance.remaining(user_id: user.id, usage_date: DAY, settings: SETTINGS)
    usage.update!(consumed_count: 5)
    values << DailyAllowance.remaining(user_id: user.id, usage_date: DAY, settings: SETTINGS)
    raise "残り: #{values.inspect}" unless values == [ 0, 1, 0 ]
  end
  true
end
check("attempts_remaining: 上限（既定 3）- 計上数（下限 0）。行が無ければ 3") do
  scratch do
    user = new_user
    values = [ DailyAllowance.attempts_remaining(user_id: user.id, usage_date: DAY, settings: SETTINGS) ]
    usage = new_usage(user, DAY)
    [ 2, 3, 7 ].each do |count|
      usage.update!(attempt_count: count)
      values << DailyAllowance.attempts_remaining(user_id: user.id, usage_date: DAY, settings: SETTINGS)
    end
    raise "残り: #{values.inspect}" unless values == [ 3, 1, 0, 0 ]
  end
  true
end
check("ensure_for!: 行が無ければ作り、あれば同じ行を返す（行は 1 件）。FOR UPDATE で確保する") do
  scratch do
    user = new_user
    statements = sql_log { @first = DailyAllowance.ensure_for!(user_id: user.id, usage_date: DAY) }
    second = DailyAllowance.ensure_for!(user_id: user.id, usage_date: DAY)
    raise "同じ行でない" unless second.id == @first.id
    raise "行が 1 件でない" unless sql("SELECT COUNT(*) FROM daily_usages WHERE user_id = '#{user.id}' AND usage_date = '#{DAY}'") == 1
    raise "ON CONFLICT DO NOTHING が無い" unless statements.any? { |s| s.include?("ON CONFLICT") && s.include?("DO NOTHING") }
    raise "FOR UPDATE が無い" unless statements.any? { |s| s.match?(/FROM "daily_usages".* FOR UPDATE/m) }
  end
  true
end
check("consume!: 配信の利用日の消費数を 1 増やし、印を立てる。同じ配信で 2 回呼んでも、1 回だけ（二重の消費をしない）") do
  scratch do
    user = new_user
    usage = new_usage(user, DAY)
    broadcast = new_broadcast(quota_date: DAY, user: user, usage: usage)
    results = [ DailyAllowance.consume!(broadcast, settings: SETTINGS), DailyAllowance.consume!(broadcast, settings: SETTINGS) ]
    raise "結果: #{results.inspect}" unless results == [ true, false ]
    raise "消費数: #{usage_row(usage)}" unless usage_row(usage)[:consumed] == 1
    raise "印が立っていない" unless sql("SELECT allowance_consumed FROM broadcasts WHERE id = '#{broadcast.id}'") == true
  end
  true
end
check("consume!: 消費先は、受理時の利用日（別の利用日の行に触れない）") do
  scratch do
    user = new_user
    accepted_day = new_usage(user, DAY)
    other_day = new_usage(user, DAY + 1)
    broadcast = new_broadcast(quota_date: DAY, user: user, usage: accepted_day)
    DailyAllowance.consume!(broadcast, settings: SETTINGS)
    raise "消費先が違う" unless usage_row(accepted_day)[:consumed] == 1 && usage_row(other_day)[:consumed].zero?
  end
  true
end
check("consume!: 利用枠が無ければ例外（黙って成功させない）。何も変えない。追加の付与があれば消費できる") do
  scratch do
    user = new_user
    usage = new_usage(user, DAY)
    usage.update!(consumed_count: 1)
    broadcast = new_broadcast(quota_date: DAY, user: user, usage: usage)
    raise "例外にならない" unless raises?(DailyAllowance::AllowanceExhausted) { DailyAllowance.consume!(broadcast, settings: SETTINGS) }
    raise "変更された" unless usage_row(usage)[:consumed] == 1 && sql("SELECT allowance_consumed FROM broadcasts WHERE id = '#{broadcast.id}'") == false
    usage.update!(extra_grants: 1)
    raise "追加の付与があっても、消費できない" unless DailyAllowance.consume!(broadcast, settings: SETTINGS) == true
  end
  true
end
check("consume!: 設定を省くと、毎回 DB から設定を読む（受付の次から、変えた値が適用される）") do
  scratch do
    user = new_user
    usage = new_usage(user, DAY)
    broadcast = new_broadcast(quota_date: DAY, user: user, usage: usage)
    SettingsStore.update!(key: "daily_allowance", value: 0)
    raise "例外にならない" unless raises?(DailyAllowance::AllowanceExhausted) { DailyAllowance.consume!(broadcast) }
    SettingsStore.update!(key: "daily_allowance", value: 1)
    raise "消費できない" unless DailyAllowance.consume!(broadcast) == true
  end
  true
end
check("count_attempt!: 同じ配信で二重に計上しない（冪等）。上限（3）に達していれば例外。手動リセットのあとは計上できる") do
  scratch do
    user = new_user
    usage = new_usage(user, DAY)
    broadcast = new_broadcast(quota_date: DAY, user: user, usage: usage)
    results = [ DailyAllowance.count_attempt!(broadcast, settings: SETTINGS), DailyAllowance.count_attempt!(broadcast, settings: SETTINGS) ]
    raise "結果: #{results.inspect}" unless results == [ true, false ] && usage_row(usage)[:attempts] == 1
    usage.update!(attempt_count: 3)
    again = new_broadcast(quota_date: DAY, user: user, usage: usage, state: "ended", end_reason: "user_stop", ended_at: Time.current, pending_title: nil)
    raise "上限で、例外にならない" unless raises?(DailyAllowance::AttemptLimitReached) { DailyAllowance.count_attempt!(again, settings: SETTINGS) }
    DailyAllowance.grant_extra!(user_id: user.id, usage_date: DAY)
    raise "リセットのあとに、計上できない" unless DailyAllowance.count_attempt!(again, settings: SETTINGS) == true
  end
  true
end
check("grant_extra!: 行が無ければ作る（追加 1）。あれば追加を 1 増やし、開始試行を 0 に戻す。消費数は変えない。1 つの upsert 文") do
  scratch do
    user = new_user
    statements = sql_log { @created = DailyAllowance.grant_extra!(user_id: user.id, usage_date: DAY) }
    raise "作成: #{@created.attributes}" unless @created.extra_grants == 1 && @created.attempt_count.zero?
    raise "upsert 文が 1 つでない" unless statements.grep(/\A(INSERT|UPDATE) /).size == 1
    @created.update!(consumed_count: 1, attempt_count: 3)
    again = DailyAllowance.grant_extra!(user_id: user.id, usage_date: DAY)
    raise "更新: #{again.attributes}" unless again.extra_grants == 2 && again.attempt_count.zero? && again.consumed_count == 1
  end
  true
end

puts "== QuotaLedger（割り当て台帳）: 予約"
check("reserve!: 予約 550（準備・確認枠 340 + 終了・清算枠 210）を計上し、配信の枠と割り当て日を設定する") do
  scratch do
    broadcast = new_broadcast(quota_date: NEXT_DAY)
    raise "予約を断られた" unless QuotaLedger.reserve!(broadcast, quota_date: DAY, daily_total: 10_000) == true
    raise "台帳: #{day_row(DAY)}" unless day_row(DAY).slice(:used, :reserved, :common) == { used: 0, reserved: 550, common: 0 }
    raise "配信: #{broadcast_row(broadcast)}" unless broadcast_row(broadcast) == { prep: 340, settle: 210, quota_date: DAY.to_s }
    raise "整合しない" unless ledger_consistent?(DAY)
  end
  true
end
check("reserve!: 16 本まで成功し、17 本目は予約しない（配信に使える上限 9,000 ÷ 550）。断られた配信は変わらない") do
  scratch do
    results = Array.new(17) { QuotaLedger.reserve!(new_broadcast(quota_date: DAY), quota_date: DAY, daily_total: 10_000) }
    raise "結果: #{results.tally}" unless results == [ true ] * 16 + [ false ]
    raise "台帳: #{day_row(DAY)}" unless day_row(DAY)[:reserved] == 16 * 550
    raise "整合しない" unless ledger_consistent?(DAY)
  end
  true
end
check("reserve!: 配信に使える上限の境界（使用済み 8,450 は予約できる。8,451 は予約しない。1 日の割り当て 1,550 は 1 本。1,549 は 0 本）") do
  scratch do
    QuotaDay.create!(quota_date: DAY, used_units: 8_450)
    QuotaDay.create!(quota_date: DAY + 1, used_units: 8_451)
    results = [
      QuotaLedger.reserve!(new_broadcast(quota_date: DAY), quota_date: DAY, daily_total: 10_000),
      QuotaLedger.reserve!(new_broadcast(quota_date: DAY + 1), quota_date: DAY + 1, daily_total: 10_000),
      QuotaLedger.reserve!(new_broadcast(quota_date: DAY + 2), quota_date: DAY + 2, daily_total: 1_550),
      QuotaLedger.reserve!(new_broadcast(quota_date: DAY + 3), quota_date: DAY + 3, daily_total: 1_549)
    ]
    raise "結果: #{results.inspect}" unless results == [ true, false, true, false ]
  end
  true
end
check("reserve!: 割り当て超過の印がある日は予約しない（false）。別の日は予約できる") do
  scratch do
    QuotaLedger.mark_exhausted!(quota_date: DAY)
    first = QuotaLedger.reserve!(new_broadcast(quota_date: DAY), quota_date: DAY, daily_total: 10_000)
    second = QuotaLedger.reserve!(new_broadcast(quota_date: NEXT_DAY), quota_date: NEXT_DAY, daily_total: 10_000)
    raise "結果: #{[ first, second ].inspect}" unless [ first, second ] == [ false, true ]
    raise "印が付いていない" unless day_row(DAY)[:exhausted] == true && day_row(NEXT_DAY)[:exhausted] == false
  end
  true
end
check("reserve!: 予約額は固定値（550 以外は ArgumentError）。予約済み・状態が reserved でない配信は、例外（二重の予約をしない）") do
  scratch do
    broadcast = new_broadcast(quota_date: DAY)
    raise "550 以外が通る" unless raises?(ArgumentError) { QuotaLedger.reserve!(broadcast, quota_date: DAY, units: 551, daily_total: 10_000) }
    QuotaLedger.reserve!(broadcast, quota_date: DAY, daily_total: 10_000)
    raise "二重の予約が通る" unless raises?(QuotaLedger::NotReservable) { QuotaLedger.reserve!(broadcast, quota_date: DAY, daily_total: 10_000) }
    live = new_broadcast(quota_date: DAY, state: "live")
    raise "reserved でない配信が通る" unless raises?(QuotaLedger::NotReservable) { QuotaLedger.reserve!(live, quota_date: DAY, daily_total: 10_000) }
    raise "台帳が二重になった: #{day_row(DAY)}" unless day_row(DAY)[:reserved] == 550
  end
  true
end
check("reserve!: 台帳の行を SELECT ... FOR UPDATE で確保する。外側のトランザクションに参加し（SAVEPOINT を作らない）、巻き戻すと取り消される") do
  scratch do
    broadcast = new_broadcast(quota_date: DAY)
    Broadcast.exists?(broadcast.id)
    statements = sql_log { QuotaLedger.reserve!(broadcast, quota_date: DAY, daily_total: 10_000) }
    raise "FOR UPDATE が無い" unless statements.any? { |s| s.match?(/FROM "quota_days".* FOR UPDATE/m) }
    raise "SAVEPOINT がある" if statements.any? { |s| s.include?("SAVEPOINT") }
    another = new_broadcast(quota_date: DAY)
    ActiveRecord::Base.transaction(requires_new: true) do
      QuotaLedger.reserve!(another, quota_date: DAY, daily_total: 10_000)
      raise ActiveRecord::Rollback
    end
    raise "巻き戻しが効かない: #{day_row(DAY)}" unless day_row(DAY)[:reserved] == 550 && broadcast_row(another)[:prep].zero?
  end
  true
end

puts "== QuotaLedger: 記帳・共通枠"
check("spend!: 準備・確認枠から支出する（使用済み +、予約中 -、配信の枠 -、明細 1 件）。実費は error でも記帳する") do
  scratch do
    broadcast = reserved_broadcast(quota_date: DAY)
    ok = QuotaLedger.spend!(broadcast, method: "liveBroadcasts.insert", units: 50, bucket: :prep, result: "ok", now: noon_of(DAY))
    failed = QuotaLedger.spend!(broadcast, method: "liveBroadcasts.bind", units: 50, bucket: "prep", result: :error, now: noon_of(DAY))
    raise "結果: #{[ ok, failed ].inspect}" unless [ ok, failed ] == [ true, true ]
    raise "台帳: #{day_row(DAY)}" unless day_row(DAY).slice(:used, :reserved) == { used: 100, reserved: 450 }
    raise "配信: #{broadcast_row(broadcast)}" unless broadcast_row(broadcast).slice(:prep, :settle) == { prep: 240, settle: 210 }
    entries = sql_rows("SELECT method, units, result, bucket FROM quota_entries WHERE broadcast_id = '#{broadcast.id}' ORDER BY method")
    raise "明細: #{entries}" unless entries == [ [ "liveBroadcasts.bind", 50, "error", "prep" ], [ "liveBroadcasts.insert", 50, "ok", "prep" ] ]
    raise "整合しない" unless ledger_consistent?(DAY)
  end
  true
end
check("spend!: 終了・清算枠は、settle 以外の用途では取り崩せない（準備・確認枠が足りなくても、終了・清算枠から取らず、false）") do
  scratch do
    broadcast = reserved_broadcast(quota_date: DAY)
    raise "340 が使えない" unless QuotaLedger.spend!(broadcast, method: "liveBroadcasts.insert", units: 340, bucket: :prep, result: "ok", now: noon_of(DAY))
    refused = QuotaLedger.spend!(broadcast, method: "liveBroadcasts.list", units: 1, bucket: :prep, result: "ok", now: noon_of(DAY))
    raise "準備・確認枠の不足で、true になった" unless refused == false
    raise "終了・清算枠が取り崩された: #{broadcast_row(broadcast)}" unless broadcast_row(broadcast).slice(:prep, :settle) == { prep: 0, settle: 210 }
    raise "終了・清算枠が使えない" unless QuotaLedger.spend!(broadcast, method: "liveBroadcasts.transition", units: 210, bucket: :settle, result: "ok", now: noon_of(DAY))
    entries = sql("SELECT COUNT(*) FROM quota_entries WHERE broadcast_id = '#{broadcast.id}'")
    raise "断られた支出が記帳された（明細 #{entries} 件）" unless entries == 2
    raise "整合しない" unless ledger_consistent?(DAY)
  end
  true
end
check("spend!: 8.4 の単価表の最大の支出（準備・確認 321 ≦ 340・終了・清算 204 ≦ 210）が、予約に収まる") do
  scratch do
    broadcast = reserved_broadcast(quota_date: DAY)
    preparation = [ 1, 50, 50, 1, 1, 50, 50, 50 ] + [ 1 ] * 24 + [ 2 ] * 12 + [ 2 ] * 10
    settlement = [ 1, 50 ] + [ 51 ] * 3
    results = preparation.map { |u| QuotaLedger.spend!(broadcast, method: "liveBroadcasts.list", units: u, bucket: :prep, result: "ok", now: noon_of(DAY)) } +
              settlement.map { |u| QuotaLedger.spend!(broadcast, method: "liveBroadcasts.list", units: u, bucket: :settle, result: "ok", now: noon_of(DAY)) }
    raise "断られた支出がある" unless results.all?(true)
    raise "残額: #{broadcast_row(broadcast)}" unless broadcast_row(broadcast).slice(:prep, :settle) == { prep: 19, settle: 6 }
  end
  true
end
check("spend!: 明細の method は、呼び出しの種別だけ（タイトル・配信キー・トークンの形は、ArgumentError。何も記帳しない）") do
  scratch do
    broadcast = reserved_broadcast(quota_date: DAY)
    bad = [ "ライブ配信のタイトル", "live broadcast title", "dummy-stream-key-1234", "ya29.dummy-token", "1//dummy-refresh", "<b>x</b>", "x" * 65, "", nil ]
    rejected = bad.all? do |kind|
      raises?(ArgumentError) { QuotaLedger.spend!(broadcast, method: kind, units: 1, bucket: :prep, result: "ok", now: noon_of(DAY)) }
    end
    raise "通ってしまう種別がある" unless rejected
    raise "記帳された" unless sql("SELECT COUNT(*) FROM quota_entries WHERE broadcast_id = '#{broadcast.id}'").zero?
    columns = sql_rows("SELECT column_name FROM information_schema.columns WHERE table_name = 'quota_entries' ORDER BY column_name").flatten
    raise "明細の列: #{columns}" unless columns == %w[broadcast_id bucket called_at id method quota_date result units]
  end
  true
end
check("spend!: 割り当て超過の印がある日にも、進行中の配信の記帳は続けられる") do
  scratch do
    broadcast = reserved_broadcast(quota_date: DAY)
    QuotaLedger.mark_exhausted!(quota_date: DAY)
    raise "断られた" unless QuotaLedger.spend!(broadcast, method: "liveBroadcasts.list", units: 1, bucket: :prep, result: "ok", now: noon_of(DAY))
  end
  true
end
check("spend_common!: 共通枠（500）から支出する（明細は枠 common・配信なし）。500 ちょうどまで。尽きたら false（その日の終わりまで）") do
  scratch do
    first = QuotaLedger.spend_common!(method: "channels.list", units: 450, quota_date: DAY, now: noon_of(DAY))
    exact = QuotaLedger.spend_common!(method: "channels.list", units: 50, quota_date: DAY, now: noon_of(DAY))
    over = QuotaLedger.spend_common!(method: "channels.list", units: 1, quota_date: DAY, now: noon_of(DAY))
    next_day = QuotaLedger.spend_common!(method: "channels.list", units: 1, quota_date: NEXT_DAY, now: noon_of(NEXT_DAY))
    raise "結果: #{[ first, exact, over, next_day ].inspect}" unless [ first, exact, over, next_day ] == [ true, true, false, true ]
    raise "台帳: #{day_row(DAY)}" unless day_row(DAY).slice(:used, :reserved, :common) == { used: 0, reserved: 0, common: 500 }
    entry = sql_rows("SELECT broadcast_id, bucket FROM quota_entries WHERE quota_date = '#{DAY}' ORDER BY units DESC").first
    raise "明細: #{entry}" unless entry == [ nil, "common" ]
    raise "整合しない" unless ledger_consistent?(DAY, NEXT_DAY)
  end
  true
end

puts "== QuotaLedger: 移し替え・解放"
check("割り当て日をまたいだ配信は、またいだ後の最初の支出で、予約の残額を新しい日へ移してから記帳する（使用済みは移さない）") do
  scratch do
    broadcast = reserved_broadcast(quota_date: DAY)
    QuotaLedger.spend!(broadcast, method: "liveBroadcasts.insert", units: 50, bucket: :prep, result: "ok", now: noon_of(DAY))
    QuotaLedger.spend!(broadcast, method: "liveBroadcasts.bind", units: 50, bucket: :prep, result: "ok", now: noon_of(NEXT_DAY))
    raise "旧い日: #{day_row(DAY)}" unless day_row(DAY).slice(:used, :reserved) == { used: 50, reserved: 0 }
    raise "新しい日: #{day_row(NEXT_DAY)}" unless day_row(NEXT_DAY).slice(:used, :reserved) == { used: 50, reserved: 450 } # 残額 500 を移して、50 を支出
    raise "配信: #{broadcast_row(broadcast)}" unless broadcast_row(broadcast) == { prep: 240, settle: 210, quota_date: NEXT_DAY.to_s }
    raise "整合しない" unless ledger_consistent?(DAY, NEXT_DAY)
  end
  true
end
check("割り当て日の境目は、太平洋時間のタイムゾーン定義（UTC 0 時でも、固定の時差でもない。夏時間・標準時の両方）") do
  scratch do
    cases = [
      [ DAY, Time.utc(2026, 10, 8, 6, 59, 59), false ], # 夏時間: 太平洋時間 23:59:59
      [ DAY, Time.utc(2026, 10, 8, 0, 0, 0), false ], # UTC の 0 時: 太平洋時間では前日の夕方
      [ DAY, Time.utc(2026, 10, 8, 7, 0, 0), true ], # 夏時間: 太平洋時間 00:00:00
      [ Date.new(2026, 11, 1), Time.utc(2026, 11, 2, 7, 30, 0), false ], # 標準時: 太平洋時間 23:30（UTC-7 の固定なら翌日になってしまう）
      [ Date.new(2026, 11, 1), Time.utc(2026, 11, 2, 8, 0, 0), true ] # 標準時: 太平洋時間 00:00
    ]
    cases.each do |date, time, crossed|
      broadcast = reserved_broadcast(quota_date: date)
      QuotaLedger.spend!(broadcast, method: "liveBroadcasts.list", units: 1, bucket: :prep, result: "ok", now: time)
      moved = broadcast_row(broadcast)[:quota_date] == (date + 1).to_s
      raise "#{date} #{time.iso8601}: 移し替え #{moved}（期待 #{crossed}）" unless moved == crossed
    end
  end
  true
end
check("carry_over!: 残額だけを移す。すでにその日の予約・残額の無い予約は false（冪等）。予約の割り当て日より前は ArgumentError") do
  scratch do
    broadcast = reserved_broadcast(quota_date: DAY)
    QuotaLedger.spend!(broadcast, method: "liveBroadcasts.list", units: 50, bucket: :prep, result: "ok", now: noon_of(DAY))
    raise "移せない" unless QuotaLedger.carry_over!(broadcast, quota_date: NEXT_DAY) == true
    raise "冪等でない" unless QuotaLedger.carry_over!(broadcast, quota_date: NEXT_DAY) == false
    raise "後戻りが通る" unless raises?(ArgumentError) { QuotaLedger.carry_over!(broadcast, quota_date: DAY) }
    raise "残額: #{day_row(NEXT_DAY)}" unless day_row(NEXT_DAY)[:reserved] == 500 && day_row(DAY).slice(:used, :reserved) == { used: 50, reserved: 0 }
    QuotaLedger.release!(broadcast)
    raise "空の予約を移した" unless QuotaLedger.carry_over!(broadcast, quota_date: NEXT_DAY + 1) == false
    raise "整合しない" unless ledger_consistent?(DAY, NEXT_DAY, NEXT_DAY + 1)
  end
  true
end
check("release!: 残額を解放する。2 回目は false（二重に解放しない。予約中が負にならない）。使い切った配信・予約前の配信も false") do
  scratch do
    broadcast = reserved_broadcast(quota_date: DAY)
    other = reserved_broadcast(quota_date: DAY)
    QuotaLedger.spend!(broadcast, method: "liveBroadcasts.list", units: 50, bucket: :settle, result: "ok", now: noon_of(DAY))
    results = [ QuotaLedger.release!(broadcast), QuotaLedger.release!(broadcast), QuotaLedger.release!(new_broadcast(quota_date: DAY)) ]
    raise "結果: #{results.inspect}" unless results == [ true, false, false ]
    raise "台帳: #{day_row(DAY)}" unless day_row(DAY).slice(:used, :reserved) == { used: 50, reserved: 550 }
    raise "別の配信の予約が変わった: #{broadcast_row(other)}" unless broadcast_row(other).slice(:prep, :settle) == { prep: 340, settle: 210 }
    raise "解放のあとの支出が通る" unless QuotaLedger.spend!(broadcast, method: "liveBroadcasts.list", units: 1, bucket: :prep, result: "ok", now: noon_of(DAY)) == false
    raise "整合しない" unless ledger_consistent?(DAY)
  end
  true
end
check("mark_exhausted!: 行が無ければ作り、印だけを付ける（値は変えない）。冪等") do
  scratch do
    QuotaLedger.mark_exhausted!(quota_date: DAY)
    QuotaLedger.mark_exhausted!(quota_date: DAY)
    raise "印: #{day_row(DAY)}" unless day_row(DAY) == { used: 0, reserved: 0, common: 0, exhausted: true }
    raise "行が複数" unless sql("SELECT COUNT(*) FROM quota_days WHERE quota_date = '#{DAY}'") == 1
  end
  true
end
check("ランダムな操作列（固定のシード）のあと、台帳の used・reserved・common が、明細と配信の残額から再計算した値と一致する") do
  scratch do
    rng = Random.new(20_261_009)
    dates = [ DAY, NEXT_DAY, NEXT_DAY + 1 ]
    holders = []
    today = 0
    200.times do
      case rng.rand(10)
      when 0..2
        broadcast = new_broadcast(quota_date: dates[today])
        holders << broadcast if QuotaLedger.reserve!(broadcast, quota_date: dates[today], daily_total: [ 10_000, 3_000 ].sample(random: rng))
      when 3..6
        next if holders.empty?

        QuotaLedger.spend!(holders.sample(random: rng), method: "liveBroadcasts.list", units: [ 1, 50, 51, 100, 340 ].sample(random: rng),
                                                         bucket: %i[prep settle].sample(random: rng), result: %w[ok error].sample(random: rng), now: noon_of(dates[today]))
      when 7 then QuotaLedger.spend_common!(method: "channels.list", units: [ 1, 50, 250 ].sample(random: rng), quota_date: dates[today], now: noon_of(dates[today]))
      when 8
        QuotaLedger.release!(holders.sample(random: rng)) unless holders.empty?
      else today += 1 if today < dates.size - 1
      end
    end
    raise "操作列が空" unless holders.size >= 5 && sql("SELECT COUNT(*) FROM quota_entries").positive?
    raise "整合しない: #{dates.map { |d| [ d, day_row(d), recomputed_day(d) ] }}" unless ledger_consistent?(*dates)
  end
  true
end

puts "== TransferBudget（送信転送量）"
check("add!: 月の行を upsert して原子的に加算する（行が無ければ作る）。exceeded?: 積算が予算（10 GB = 100 億バイト）に達したら true") do
  scratch do
    raise "最初の加算" unless TransferBudget.add!(month_key: "2026-10", bytes: 9_999_999_999) == 9_999_999_999
    raise "予算の手前で true" if TransferBudget.exceeded?(month_key: "2026-10", settings: SETTINGS)
    TransferBudget.add!(month_key: "2026-10", bytes: 1)
    raise "予算ちょうどで false" unless TransferBudget.exceeded?(month_key: "2026-10", settings: SETTINGS)
    raise "行が複数" unless sql("SELECT COUNT(*) FROM transfer_months WHERE month = '2026-10'") == 1
    raise "別の月に影響した" if TransferBudget.exceeded?(month_key: "2026-11", settings: SETTINGS)
  end
  true
end
check("add_for_broadcast!: 配信の sent_bytes と月次の積算を同時に加算する。暦月は JST（00:00 区切り。03:00 区切りではない）") do
  scratch do
    broadcast = new_broadcast(quota_date: DAY, sent_bytes: 100)
    TransferBudget.add_for_broadcast!(broadcast, delta_bytes: 1_000, now: Time.utc(2026, 10, 31, 14, 59, 59)) # JST 10 月 31 日 23:59:59
    TransferBudget.add_for_broadcast!(broadcast, delta_bytes: 2_000, now: Time.utc(2026, 10, 31, 17, 59, 0)) # JST 11 月 1 日 02:59（利用日は前日。暦月は 11 月）
    months = sql_rows("SELECT month, sent_bytes FROM transfer_months ORDER BY month")
    raise "月次: #{months}" unless months == [ [ "2026-10", 1_000 ], [ "2026-11", 2_000 ] ]
    raise "配信: #{sql("SELECT sent_bytes FROM broadcasts WHERE id = '#{broadcast.id}'")}" unless sql("SELECT sent_bytes FROM broadcasts WHERE id = '#{broadcast.id}'") == 3_100
  end
  true
end

puts "== SettingsStore（設定値の読み書き）"
check("current: 行が無ければ既定値（契約の limits.json）。毎回 DB を読む（キャッシュしない）") do
  scratch do
    defaults = JSON.parse(File.read("/contracts/limits.json")).fetch("setting_defaults").except("bot_score_threshold_note", "setting_defaults_note")
    typed = SettingsStore.current.to_h.transform_keys(&:to_s)
    raise "既定値: #{typed}" unless typed == defaults
    SettingsStore.update!(key: "attempt_limit", value: 5)
    raise "反映されない" unless SettingsStore.current.attempt_limit == 5
    ActiveRecord::Base.with_connection { |connection| connection.execute("UPDATE system_settings SET value = '7' WHERE key = 'attempt_limit'") }
    raise "キャッシュしている" unless SettingsStore.current.attempt_limit == 7
  end
  true
end
check("current: 壊れた値は、既定値へ黙って戻さず、例外（SettingsStore::CorruptSetting）") do
  scratch do
    ActiveRecord::Base.with_connection do |connection|
      connection.execute("INSERT INTO system_settings (key, value, updated_at) VALUES ('daily_allowance', 'abc', NOW())")
    end
    raise "例外にならない" unless raises?(SettingsStore::CorruptSetting) { SettingsStore.current }
  end
  true
end
check("update!: 検証して upsert する。未知のキー・範囲外・型違いは例外（保存しない）。受付停止（intake_paused）を読み書きできる") do
  scratch do
    raise "未知のキー" unless raises?(Settings::InvalidSetting) { SettingsStore.update!(key: "no_such_key", value: 1) }
    raise "範囲外" unless raises?(Settings::InvalidSetting) { SettingsStore.update!(key: "daily_quota_units", value: 999) }
    raise "型違い" unless raises?(Settings::InvalidSetting) { SettingsStore.update!(key: "concurrent_limit", value: "many") }
    raise "不正な値が保存された" unless sql("SELECT COUNT(*) FROM system_settings").zero?
    SettingsStore.update!(key: "intake_paused", value: true)
    raise "受付停止にならない" unless SettingsStore.current.intake_paused == true
    SettingsStore.update!(key: :intake_paused, value: "false")
    raise "解除されない" unless SettingsStore.current.intake_paused == false
    raise "操作の記録を書いた" unless sql("SELECT COUNT(*) FROM admin_actions").zero?
  end
  true
end

puts
puts "確認した項目 #{CHECKED.size} 件、失敗 #{FAILURES.size} 件"
if FAILURES.empty?
  puts "PASS 受け入れの確認はすべて成功しました"
  exit 0
end
FAILURES.each { |label| puts "  - #{label}" }
exit 1
