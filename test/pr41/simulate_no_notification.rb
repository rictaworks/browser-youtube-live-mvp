# 全状態 × 通知なし: すべての配信が、有限時間で、終了し、清算が終端へ進むことを、シミュレーションで確かめる
# （requirements.md 27 章の終端性・13.2・10.4・25.2）。
#
# backend のコンテナの中で、標準入力から実行する（test/pr41/run_all.sh が呼ぶ）。
#   scripts/dc.sh exec -T backend bundle exec ruby - < test/pr41/simulate_no_notification.rb
#
# 配信（BroadcastSnapshot）に、事象（中継の通知・心拍・ブラウザの操作）を一切与えず、時刻だけを 1 秒ずつ進める。
# 各時刻で、期限の評価（DeadlineEvaluator）の指示を、状態へ反映する（終了 → TerminationPlanner、清算 → SettlementRules）。
# シミュレーターは、spec/domain/lifecycle/support/no_notification_simulator.rb（rspec と共通）。
#
#   1. 13.2 の表の期限どおりに終了すること（8 つの場合。期限は、要件の数値を、このファイルに書く）
#   2. 清算の経過（最初の試行・1・2・4 分の再試行・清算不能・成功）
#   3. 乱数（種を固定）で作った 600 の配信（状態・時刻・上限・清算の結果）が、すべて 600 秒以内に終端へ進むこと
require "zeitwerk"

DOMAIN_DIR = "/app/app/domain".freeze
SUPPORT_DIR = "/app/spec/domain/lifecycle/support".freeze

loader = Zeitwerk::Loader.new
loader.push_dir(DOMAIN_DIR)
loader.setup
require "#{SUPPORT_DIR}/lifecycle_helpers"
require "#{SUPPORT_DIR}/no_notification_simulator"

T0 = LifecycleSpecHelpers::T0
SimSettings = Struct.new(:time_limit_minutes)
helper = Object.new.extend(LifecycleSpecHelpers)

failures = 0
check = lambda do |ok, label|
  puts "#{ok ? 'PASS' : 'FAIL'} #{label}"
  failures += 1 unless ok
end

simulate = lambda do |snapshot, start:, minutes: 60, youtube: NoNotificationSimulator::ALWAYS_FAIL, limit: 600|
  NoNotificationSimulator.run(
    snapshot: snapshot, start_at: T0 + start, settings: SimSettings.new(minutes), youtube: youtube, limit_seconds: limit
  )
end

puts "== 1. 13.2 の表の期限どおりに終了する（事象なし）"
puts "状態            開始   上限   終了（T0+秒）  理由"
[
  # 状態, 上書き, 開始（T0 から）, 上限（分）, 終了の時刻（T0 から）, 理由。数値は requirements.md 13.2 の値
  [ "reserved", {}, 0, 60, 90, "start_timeout" ], # 受理（T0）から 90 秒
  [ "awaiting_media", {}, 20, 60, 50, "start_timeout" ], # 準備の完了（T0+20）から 30 秒
  [ "confirming", {}, 40, 60, 160, "confirm_timeout" ], # 送出開始（T0+40）から 120 秒
  [ "live", {}, 60, 60, 145, "connection_lost" ], # 心拍なし: 10 秒で中断（T0+70）、75 秒後
  [ "live", {}, 60, 1, 120, "time_limit" ], # 上限 1 分（T0+120）が、中断の期限（T0+145）より先
  [ "interrupted", {}, 100, 60, 175, "connection_lost" ], # 心拍の途絶による中断: 75 秒
  [ "interrupted", { relay_notified_at: T0 + 100 }, 100, 60, 130, "connection_lost" ], # 中継の通知による中断: 30 秒
  [ "interrupted", { resume_count: 10 }, 100, 60, 100, "connection_lost" ] # 復帰が 10 回を超える: 復帰を待たずに終了
].each do |state, overrides, start, minutes, ended_at, reason|
  result = simulate.call(helper.snapshot(state, **overrides), start: start, minutes: minutes)
  final = result.final
  ok = final.ended_at == T0 + ended_at && final.end_reason == reason
  puts format("%-15s %4d %5d   %12d  %s", state, start, minutes, final.ended_at - T0, final.end_reason)
  check.call(ok, "#{state}（開始 T0+#{start}・上限 #{minutes} 分）: T0+#{ended_at} に #{reason} で終了する")
end

puts
puts "== 2. 清算の経過（YouTube 資源あり。送出待ちが T0+50 に開始タイムアウトで終了）"
resource = helper.snapshot("awaiting_media")

fail_result = simulate.call(resource, start: 20, youtube: NoNotificationSimulator::ALWAYS_FAIL)
check.call(fail_result.attempt_times == [ 30, 90, 210, 450 ], "清算が失敗し続ける: 最初の試行（終了と同時）→ 1 分 → 2 分 → 4 分後に再試行（試行の時刻 #{fail_result.attempt_times}）")
check.call(fail_result.final.settlement_state == "abandoned" && fail_result.final.settlement_attempts == 4, "再試行が 3 回に到達して、清算不能（試行 4 回）")

ok_result = simulate.call(resource, start: 20, youtube: NoNotificationSimulator::SUCCEEDS)
check.call(ok_result.final.settlement_state == "settled" && ok_result.elapsed_seconds == 30, "最初の試行で成功: 終了と同時に清算済み")

retry_result = simulate.call(resource, start: 20, youtube: ->(before) { before >= 2 ? :success : :failed })
check.call(retry_result.final.settlement_state == "settled" && retry_result.elapsed_seconds == 210, "2 回目の再試行で成功: 終了の 180 秒後に清算済み")

none_result = simulate.call(helper.snapshot("reserved"), start: 0)
check.call(none_result.final.settlement_state == "none" && none_result.attempt_times.empty? && none_result.elapsed_seconds == 90, "YouTube 資源なし: 清算状態は不要。終了と同時に終端")

crashed = helper.ended_snapshot(settlement_state: "pending", settlement_attempts: 0, settlement_attempted_at: nil)
crashed_result = simulate.call(crashed, start: 200)
check.call(crashed_result.attempt_times == [ 60, 120, 240, 480 ], "最初の試行が記録されないまま（アプリケーションの停止）: 終了の 1 分後から、期限監視が清算する")

puts
puts "== 3. 乱数（種 20261007）で作った 600 の配信が、すべて 600 秒以内に終端へ進む"
random = Random.new(20_261_007)
start = 1_000
youtubes = {
  "常に失敗" => NoNotificationSimulator::ALWAYS_FAIL,
  "成功" => NoNotificationSimulator::SUCCEEDS,
  "2 回目の再試行で成功" => ->(before) { before >= 2 ? :success : :failed }
}
generate = lambda do |state|
  case state
  when "reserved" then { accepted_at: T0 + start - random.rand(0..200) }
  when "awaiting_media" then { accepted_at: T0 + start - 400, provisioned_at: T0 + start - random.rand(0..100) }
  when "confirming"
    { accepted_at: T0 + start - 600, provisioned_at: T0 + start - 500, publish_started_at: T0 + start - random.rand(0..200),
      last_checked_at: [ nil, T0 + start - random.rand(0..10) ].sample(random: random) }
  when "live"
    { live_at: T0 + start - random.rand(0..4000), last_heartbeat_at: [ nil, T0 + start - random.rand(0..30) ].sample(random: random),
      last_checked_at: [ nil, T0 + start - random.rand(0..400) ].sample(random: random),
      resume_count: random.rand(0..10), time_limit_notice_sent: random.rand(2).zero? }
  when "interrupted"
    interrupted_at = T0 + start - random.rand(0..100)
    { live_at: T0 + start - random.rand(100..4000), interrupted_at: interrupted_at,
      relay_notified_at: [ nil, interrupted_at + random.rand(0..100) ].sample(random: random), resume_count: random.rand(0..11) }
  end
end

summary = Hash.new { |hash, key| hash[key] = { runs: 0, max_elapsed: 0, reasons: Hash.new(0), settlements: Hash.new(0) } }
worst = 0
failed_runs = 0
states = %w[reserved awaiting_media confirming live interrupted]
600.times do |index|
  state = states[index % states.size]
  overrides = generate.call(state)
  # 資源の有無を変える（受理済みは、既定では資源が無い。準備の途中で資源を作成済みの場合も試す）
  if state == "reserved"
    overrides = overrides.merge(youtube_broadcast_id: "dummy-youtube-broadcast-1") if random.rand(2).zero?
  elsif random.rand(4).zero?
    overrides = overrides.merge(youtube_broadcast_id: nil, youtube_stream_id: nil)
  end
  minutes = [ 1, 3, 5, 30, 60, 600 ].sample(random: random)
  youtube_label, youtube = youtubes.to_a.sample(random: random)
  begin
    result = simulate.call(helper.snapshot(state, **overrides), start: start, minutes: minutes, youtube: youtube, limit: 600)
  rescue NoNotificationSimulator::DidNotTerminate => error
    failed_runs += 1
    puts "  - 終端へ進まない: #{state} 上限 #{minutes} 分・清算#{youtube_label}: #{error.message}"
    next
  end
  entry = summary[state]
  entry[:runs] += 1
  entry[:max_elapsed] = [ entry[:max_elapsed], result.elapsed_seconds ].max
  entry[:reasons][result.final.end_reason] += 1
  entry[:settlements][result.final.settlement_state] += 1
  worst = [ worst, result.elapsed_seconds ].max
end

puts "状態            件数  最大の経過(秒)  終了理由                      清算状態"
summary.each do |state, entry|
  puts format("%-15s %4d  %14d  %-28s  %s", state, entry[:runs], entry[:max_elapsed], entry[:reasons].sort.to_h, entry[:settlements].sort.to_h)
end
check.call(failed_runs.zero? && summary.values.sum { |entry| entry[:runs] } == 600, "600 の配信のすべてが、終端へ進む（最大 #{worst} 秒）")
check.call(worst <= 600, "最大の経過は 600 秒以内（中断の期限 75 秒 + 清算の再試行 420 秒に収まる）")

puts
if failures.zero?
  puts "PASS 全状態 × 通知なし: すべて、有限時間で終端へ進みました"
  exit 0
end
puts "FAIL #{failures} 件が失敗しました"
exit 1
