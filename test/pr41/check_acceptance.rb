# issue #6（配信の生命周期の Domain Core）の受け入れ条件を、公開された API だけで、独立に確かめる（rspec とは別の実行）。
#
# backend のコンテナの中で、標準入力から実行する（test/pr41/run_all.sh が呼ぶ）。
#   scripts/dc.sh exec -T backend bundle exec ruby - < test/pr41/check_acceptance.rb
#
# rspec が例ごとに確かめるのに対し、ここでは、全体の性質（件数・到達性・網羅・不変）を確かめる。
# 数値は、requirements.md の値（13.2・10.4・10.5・8.4・20.3）を、このファイルに書く（契約の定数との一致も確かめる）。
require "zeitwerk"

loader = Zeitwerk::Loader.new
loader.push_dir("/app/app/domain")
loader.setup

T0 = Time.utc(2026, 10, 7, 12, 0, 0)
DAY = 86_400
STATES = Contract::BroadcastState::ALL
NON_ENDED = STATES - [ "ended" ]
PROGRESS_EVENTS = %w[provision_done publish_started live_confirmed interrupted resumed].freeze
END_REASONS = Contract::EndReason::ALL
VOCABULARY = PROGRESS_EVENTS + END_REASONS
Fake = Struct.new(:time_limit_minutes)

@failures = 0
@section = nil

def section(title)
  puts
  puts "== #{title}"
end

def check(ok, label)
  puts "#{ok ? 'PASS' : 'FAIL'} #{label}"
  @failures += 1 unless ok
end

def snap(state, **overrides)
  base = { id: "dummy-broadcast-1", user_id: "dummy-user-1", state: state, accepted_at: T0 }
  extra = {
    "reserved" => {},
    "awaiting_media" => { provisioned_at: T0 + 20 },
    "confirming" => { publish_started_at: T0 + 40, last_checked_at: T0 + 40 },
    "live" => { live_at: T0 + 60, last_heartbeat_at: T0 + 60, last_checked_at: T0 + 60 },
    "interrupted" => { live_at: T0 + 60, interrupted_at: T0 + 100 },
    "ended" => { ended_at: T0 + 200, end_reason: "user_stop", settlement_state: "pending", settlement_attempts: 1, settlement_attempted_at: T0 + 200 }
  }.fetch(state)
  BroadcastSnapshot.new(**base.merge(extra).merge(overrides))
end

def with_resource(state, **overrides)
  snap(state, youtube_broadcast_id: "dummy-youtube-broadcast-1", youtube_stream_id: "dummy-stream-A", **overrides)
end

def evaluate(snapshot, at:, minutes: 60)
  DeadlineEvaluator.evaluate(broadcast: snapshot, now: T0 + at, settings: Fake.new(minutes))
end

def transition(state, event)
  BroadcastStateMachine.transition(state: state, event: event)
end

# ---------------------------------------------------------------------------------------------------------------
section "状態遷移（BroadcastStateMachine。25.1）"

defined = STATES.product(VOCABULARY).select { |state, event| transition(state, event).next_state != state }
check(defined.size == 35, "定義のある遷移は 35 本（進行 5 + 終了 30）。状態 6 × 事象 18 = 108 の組のうち、残り 73 組は、状態を変えない（実測: #{defined.size} 本）")
check(STATES.product(VOCABULARY).all? { |state, event| transition(state, event).effects.empty? || defined.include?([ state, event ]) }, "定義のない組は、効果も無い")

reachable = [ "reserved" ]
reachable |= defined.select { |state, _event| reachable.include?(state) }.map { |state, event| transition(state, event).next_state } while (reachable | defined.select { |state, _| reachable.include?(state) }.map { |state, event| transition(state, event).next_state }).size > reachable.size
check(reachable.sort == STATES.sort, "受理済みから、6 つすべての状態へ到達できる")
check(defined.none? { |state, _event| state == "ended" }, "終了から出る遷移は無い（終端）")
check(END_REASONS.all? { |reason| defined.any? { |_state, event| event == reason } }, "13 の終了理由のすべてが、少なくとも 1 つの状態から終了へ遷移させる")
check(NON_ENDED.all? { |state| transition(state, "authorization_revoked").next_state == "ended" }, "認可失効は、終了していないすべての状態から終了へ遷移する（10.6）")
check(%w[reserved awaiting_media confirming].all? { |state| transition(state, "user_stop").next_state == state }, "ライブ確定前の状態から、利用者の停止は定義が無い")
check(%w[live interrupted].all? { |state| transition(state, "user_cancel").next_state == state }, "ライブ後の状態から、利用者の取り消しは定義が無い")
check(NON_ENDED.select { |state| transition(state, "insufficient_bandwidth").next_state == "ended" } == [ "reserved" ], "回線不足は、受理済みからだけ")
check(END_REASONS.all? { |reason| transition("ended", reason) == BroadcastStateMachine::Transition.new(next_state: "ended", effects: []) }, "終了済みに対する終了の事象は冪等（終了のまま・効果なし）")

with_effects = STATES.product(VOCABULARY).reject { |state, event| transition(state, event).effects.empty? }
kinds = with_effects.to_h { |state, event| [ [ state, event ], transition(state, event).effects.map(&:kind) ] }
check(kinds[[ "confirming", "live_confirmed" ]] == [ :consume_allowance ] && kinds[[ "interrupted", "resumed" ]] == [ :verify_youtube_status ], "効果: ライブ確定は利用枠の消費、復帰は YouTube の状態確認")
check(with_effects.size == 32 && kinds.values.flatten.tally == { consume_allowance: 1, verify_youtube_status: 1, terminate: 30 }, "効果を持つのは 32 本（利用枠の消費 1・状態確認 1・終了処理の開始 30）。実行はしない（値だけ）")

timer_events = %w[start_timeout confirm_timeout time_limit connection_lost interrupted] # 期限の評価が出す事象
walk = lambda do |from|
  seen = [ from ]
  frontier = [ from ]
  until frontier.empty?
    frontier = frontier.flat_map { |state| timer_events.map { |event| transition(state, event).next_state } }.uniq - seen
    seen |= frontier
  end
  seen
end
check(NON_ENDED.all? { |state| walk.call(state).include?("ended") }, "期限の評価が出す事象だけで、すべての状態から、終了へ到達できる（状態遷移の表の上での終端性）")

# ---------------------------------------------------------------------------------------------------------------
section "終了処理（TerminationPlanner。10.4）"

plans = END_REASONS.product(NON_ENDED, [ true, false ]).map do |reason, state, resource|
  broadcast = resource ? with_resource(state) : snap(state)
  [ resource, TerminationPlanner.plan(broadcast: broadcast, reason: reason) ]
end
check(plans.size == 130, "13 の終了理由 × 5 つの状態 × 資源の有無 = 130 通りを計画できる")
check(plans.all? { |resource, plan| plan.settlement_state == (resource ? "pending" : "none") }, "清算状態の初期値: 資源があれば未清算、無ければ不要（理由・状態によらない）")
check(plans.all? { |resource, plan| plan.release_reservation == !resource && plan.clear_title }, "予約の解放: 不要は即座に・未清算は終端に達するまで解放しない。タイトルは終了時に消去する")
check(plans.all? { |resource, plan| plan.steps.map(&:kind) == (resource ? %i[end_broadcast stop_publishing settle] : %i[end_broadcast stop_publishing]) }, "順序は、終了（清算状態を同時に確定）→ 送出停止の指示 → 清算（資源があるときだけ）")
check(TerminationPlanner.method(:plan).parameters.map(&:last) == %i[broadcast reason], "計画は、清算の結果を引数に取らない（清算の成否に依存しない）")
check((TerminationPlanner.plan(broadcast: snap("ended"), reason: "user_stop") rescue :raised) == :raised, "終了済みの配信は、計画しない（清算状態を戻さない）")

# ---------------------------------------------------------------------------------------------------------------
section "期限の評価（DeadlineEvaluator。13.2）"

# [見出し, 状態, 上書き, 期限（T0 から）, 理由, 評価の時刻の心拍を新しくするか]
rows = [
  [ "受理済み 90 秒", "reserved", {}, 90, "start_timeout", false ],
  [ "送出待ち 30 秒（準備の完了 T0+20 から）", "awaiting_media", {}, 50, "start_timeout", false ],
  [ "確定待ち 120 秒（送出開始 T0+40 から）", "confirming", {}, 160, "confirm_timeout", false ],
  [ "中断・中継の通知 30 秒", "interrupted", { relay_notified_at: T0 + 100 }, 130, "connection_lost", false ],
  [ "中断・心拍の途絶 75 秒", "interrupted", {}, 175, "connection_lost", false ],
  [ "中断・心拍の途絶が先、通知が後（130+30 < 175）", "interrupted", { relay_notified_at: T0 + 130 }, 160, "connection_lost", false ],
  [ "中断・心拍の途絶が先、通知が後（160+30 > 175）", "interrupted", { relay_notified_at: T0 + 160 }, 175, "connection_lost", false ],
  [ "ライブ確定（T0+60）から 60 分", "live", {}, 3660, "time_limit", true ],
  [ "中断中もライブ確定から 60 分", "interrupted", { interrupted_at: T0 + 3650 }, 3660, "time_limit", false ]
]
rows.each do |label, state, overrides, due, reason, fresh|
  at = ->(seconds) { snap(state, **(fresh ? overrides.merge(last_heartbeat_at: T0 + seconds - 1) : overrides)) }
  before = evaluate(at.call(due - 1), at: due - 1)
  on_time = evaluate(at.call(due), at: due)
  after = evaluate(at.call(due + 1), at: due + 1)
  expected = [ Directive.of(:end, reason: reason) ]
  check(before.none? { |d| d.kind == :end } && on_time == expected && after == expected, "#{label}: 1 秒前は終了しない・ちょうどと 1 秒後は #{reason} で終了")
end

hb_snapshot = snap("live", last_heartbeat_at: T0 + 300)
check(evaluate(hb_snapshot, at: 309).empty? && evaluate(hb_snapshot, at: 310) == [ Directive.of(:interrupt, cause: :heartbeat_lost, deadline_at: T0 + 385) ], "ライブで心拍が 10 秒途絶（T0+310）: 中断の指示（期限は 75 秒後 = T0+385）。9 秒では指示なし")
check(evaluate(snap("interrupted", resume_count: 9), at: 101).empty? && evaluate(snap("interrupted", resume_count: 10), at: 101) == [ Directive.of(:end, reason: "connection_lost") ], "復帰が 10 回を超える中断は、復帰を待たずに接続喪失で終了（9 回は待つ）")
check(evaluate(snap("live", last_heartbeat_at: T0 + 1859), at: 1859, minutes: 60).none? { |d| d.kind == :end } && evaluate(snap("live", last_heartbeat_at: T0 + 1860), at: 1860, minutes: 30) == [ Directive.of(:end, reason: "time_limit") ], "進行中の配信にも、評価の時点の設定（時間上限 30 分）を適用する")
check(evaluate(snap("live", last_heartbeat_at: T0 + 3359, last_checked_at: T0 + 3359), at: 3359).empty? && evaluate(snap("live", last_heartbeat_at: T0 + 3360, last_checked_at: T0 + 3360), at: 3360) == [ Directive.of(:time_limit_notice, notice_seconds: 300) ], "時間上限の 5 分前（T0+3360）に予告（残り 5 分）")
check(evaluate(snap("confirming", last_checked_at: T0 + 100), at: 104).empty? && evaluate(snap("confirming", last_checked_at: T0 + 100), at: 105) == [ Directive.of(:poll_live_confirmation) ], "確定待ち: ライブ確定の確認は 5 秒間隔")
fresh_live = ->(at) { snap("live", last_heartbeat_at: T0 + at - 1, last_checked_at: T0 + 60) } # 心拍は届いている
check(evaluate(fresh_live.call(359), at: 359).empty? && evaluate(fresh_live.call(360), at: 360) == [ Directive.of(:poll_live_health) ], "ライブ: 配信状態とストリームの健全性の確認は 5 分間隔（最後の確認 T0+60 の 300 秒後）")
retry_rows = [ [ 1, T0 + 200, 260 ], [ 2, T0 + 260, 380 ], [ 3, T0 + 380, 620 ] ]
check(retry_rows.all? { |attempts, attempted_at, due| ended = snap("ended", settlement_attempts: attempts, settlement_attempted_at: attempted_at, youtube_broadcast_id: "dummy-y"); evaluate(ended, at: due - 1).empty? && evaluate(ended, at: due) == [ Directive.of(:retry_settlement, attempts_made: attempts) ] }, "終了済みで未清算: 清算の再試行は、1・2・4 分の間隔（最後の試行の 60・120・240 秒後）")
check(%w[none settled abandoned].all? { |state| [ 0, 260, 100_000 ].all? { |at| evaluate(snap("ended", settlement_state: state), at: at).empty? } }, "清算が終端（不要・清算済み・清算不能）なら、終了済みの配信に指示なし")

offsets = [ 0, 50, 100, 200, 400, 1000, 3400, 4000, 100_000 ]
sweep = NON_ENDED.flat_map { |state| offsets.flat_map { |at| evaluate(with_resource(state), at: at) } }
sweep += offsets.flat_map { |at| evaluate(with_resource("live", last_heartbeat_at: T0 + at - 1, last_checked_at: T0 + 60), at: at) } # 心拍が届いているライブ
sweep += %w[none pending settled abandoned].flat_map { |state| [ 0, 260, 100_000 ].flat_map { |at| evaluate(snap("ended", settlement_state: state, youtube_broadcast_id: "dummy-y"), at: at) } }
check(sweep.map(&:kind).uniq.sort == %i[end interrupt poll_live_confirmation poll_live_health retry_settlement time_limit_notice], "指示の種別は 6 種（end・interrupt・time_limit_notice・poll_live_confirmation・poll_live_health・retry_settlement）")
check(sweep.all? { |d| d.kind != :end || END_REASONS.include?(d.args.fetch(:reason)) }, "終了の指示の理由は、契約の終了理由")

limits = Contract::Limits::DEADLINES
check(limits.values_at("reserved_seconds", "awaiting_media_seconds", "confirming_seconds", "interrupted_relay_notified_seconds", "interrupted_heartbeat_lost_seconds", "heartbeat_lost_detect_seconds", "max_resumes") == [ 90, 30, 120, 30, 75, 10, 10 ], "13.2 の数値は、契約（limits.json）から取る（90・30・120・30・75・10・10）")
check([ DeadlineEvaluator::RESERVED_SECONDS, DeadlineEvaluator::AWAITING_MEDIA_SECONDS, DeadlineEvaluator::CONFIRMING_SECONDS, DeadlineEvaluator::MAX_RESUMES ] == [ 90, 30, 120, 10 ], "期限の評価の定数は、契約の値と一致する")

# ---------------------------------------------------------------------------------------------------------------
section "清算（SettlementRules。10.4・25.2・8.4）"

expected_plan = {
  "live" => :transition_to_complete, "testing" => :transition_to_complete,
  "created" => :delete_broadcast, "ready" => :delete_broadcast, "liveStarting" => :delete_broadcast, "testStarting" => :delete_broadcast,
  "complete" => :mark_settled, "revoked" => :mark_settled, SettlementRules::NOT_FOUND => :mark_settled
}
check(expected_plan.all? { |status, kind| SettlementRules.plan(youtube_status: status) == Directive.of(kind) }, "YouTube の状態 8 値と「存在しない」: ライブ・テスト中は完了へ遷移、未開始・遷移中は削除、完了・取り消し・存在しないは清算済み")
check(SettlementRules::LifeCycleStatus::ALL.size == 8, "lifeCycleStatus は公式の 8 値")
check([ nil, "unknown", "Live", :live ].all? { |status| (SettlementRules.plan(youtube_status: status) rescue $!.class) == SettlementRules::UnknownLifeCycleStatus }, "未知の状態は、黙って清算済みにせず、例外（UnknownLifeCycleStatus）")

schedule = (0..3).map { |before| SettlementRules.apply_result(settlement_state: "pending", attempts: before, result: :failed) }
check(schedule.map(&:retry_delay_seconds) == [ 60, 120, 240, nil ] && schedule.map(&:settlement_state) == %w[pending pending pending abandoned], "失敗が続くと、再試行は 1・2・4 分間隔で 3 回。4 回目の試行の失敗で、清算不能")
check(schedule.last.directives.map(&:kind) == %i[release_reservation discard_stream_id], "清算不能になったら、予約の解放と、配信用ストリームの識別子の破棄を指示する")
check(%i[success not_found already_terminal].all? { |result| o = SettlementRules.apply_result(settlement_state: "pending", attempts: 1, result: result); o.settlement_state == "settled" && o.directives.map(&:kind) == [ :release_reservation ] }, "成功・存在しない・すでに終端は、清算済み（予約の解放）")
check(SettlementRules.apply_result(settlement_state: "pending", attempts: 0, result: :not_transitionable).settlement_state == "pending", "遷移・削除できない（invalidTransition など）は、終端ではない。未清算のまま再試行する")
check(SettlementRules.apply_result(settlement_state: "abandoned", attempts: 4, result: :success).settlement_state == "settled" && SettlementRules.apply_result(settlement_state: "abandoned", attempts: 4, result: :forbidden).settlement_state == "abandoned", "清算不能の再清算: 成功なら清算済み、権限の範囲外なら清算不能のまま")
reasons = { "redundantTransition" => :already_terminal, "invalidTransition" => :not_transitionable, "liveBroadcastDeletionNotAllowed" => :not_transitionable, "errorStreamInactive" => :not_transitionable, "liveBroadcastNotFound" => :not_found }
check(reasons.all? { |reason, result| SettlementRules.result_for_error(reason: reason) == result }, "YouTube のエラーの reason の分類（redundantTransition は終端・invalidTransition などは終端ではない）")
check(SettlementRules::ATTEMPT_COST_UNITS == 51 && SettlementRules::BUCKET == :settle && (1 + SettlementRules::MAX_RETRIES) * 51 <= Contract::Limits::QUOTA.fetch("settle_reservation_units"), "1 回の試行は 51 ユニット（終了・清算枠）。最初の試行 + 再試行 3 回 = 204 ユニットが、枠 210 に収まる")

# ---------------------------------------------------------------------------------------------------------------
section "先行配信の清算確認（PriorSettlementCheck）とストリームの取り替え（StreamReplacementPolicy）。10.5"

prior = lambda do |id, settlement_state, stream: "dummy-stream-A", **overrides|
  attempts = settlement_state == "abandoned" ? 4 : 1
  snap("ended", id: id, settlement_state: settlement_state, settlement_attempts: attempts, youtube_broadcast_id: "dummy-youtube-#{id}", youtube_stream_id: stream, **overrides)
end
plan = ->(priors, stream: "dummy-stream-A", remaining: 340, own: 202) { PriorSettlementCheck.plan(prior_broadcasts: priors, current_stream_id: stream, prep_remaining_units: remaining, own_prep_cost_units: own) }

check(plan.call([]).verdict == :clear, "先行配信が無ければ、確認は要らない")
check(plan.call([ prior.call("p1", "pending") ]).then { |p| p.verdict == :settle_required && p.confirm_targets.size == 1 && p.confirm_cost_units == 51 }, "現在のストリームへ紐づいた未清算は、確認の対象（51 ユニット）。終端にできなければ準備を中止する")
check(plan.call([ prior.call("p1", "pending") ]).on_unsettled == Directive.of(:abort_preparation, end_reason: "prior_unsettled", count_attempt: false), "中止の指示: 終了理由は先行配信が未清算。開始試行を計上しない")
check(plan.call([ prior.call("p1", "pending", stream: "dummy-stream-OLD") ]).verdict == :clear, "別のストリーム（取り替え前）へ紐づいた未清算は、対象にしない")
check(plan.call([ prior.call("p1", "pending") ], remaining: 50).verdict == :abort && plan.call([ prior.call("p1", "pending") ], remaining: 51).verdict == :settle_required, "確認に足りない残額（50 ユニット）なら、直ちに中止する（51 ユニットなら確認できる）")
check([ [ 51, 1 ], [ 50, 0 ], [ 102, 2 ], [ 1000, 5 ] ].all? { |spare, count| plan.call(Array.new(5) { |i| prior.call("a#{i}", "abandoned", ended_at: T0 + 200 + i) }, remaining: 202 + spare, own: 202).resettle_targets.size == count }, "清算不能の再清算は、残額が（確認と自配信の準備の費用）を超える範囲でのみ（余裕 51 → 1 件・50 → 0 件・102 → 2 件）")
check(plan.call([ prior.call("a1", "abandoned") ], remaining: 0, own: 0).verdict == :clear, "清算不能は、準備を妨げない")
check(plan.call([ prior.call("p1", "pending", youtube_broadcast_id: nil), prior.call("a1", "abandoned", youtube_broadcast_id: nil) ]).then { |p| p.confirm_targets.empty? && p.resettle_targets.empty? }, "YouTube の識別子を消去済みの配信は、対象外")
check((plan.call([ prior.call("p1", "pending"), prior.call("p2", "pending", user_id: "dummy-user-2") ]) rescue $!.class) == PriorSettlementCheck::MixedAccounts, "他のアカウントの配信が混ざっていたら、処理せず例外（MixedAccounts）")

triggers = { youtube_connected: true, settlement_abandoned: true, unsettled_identifier_erased: true, stream_id_expired: true, broadcast_ended: false, settlement_succeeded: false, preparation_started: false, settled_identifier_erased: false }
check(triggers.all? { |trigger, expected| StreamReplacementPolicy.discard?(trigger: trigger) == expected }, "ストリームの取り替え: YouTube 接続の成立・清算不能・識別子の消去（未清算・清算不能）・30 日の期限で破棄。それ以外は破棄しない")

# ---------------------------------------------------------------------------------------------------------------
section "保持期間（RetentionPolicy。20.3）"

periods = { youtube_broadcast_id: 30, health_samples: 30, broadcast_events: 30, relay_tickets: 1, sessions: 30, stream_id: 30 }
check(periods.all? { |subject, days| RetentionPolicy.period_seconds(subject) == days * DAY }, "期間: 配信識別子 30 日・標本と出来事 30 日・接続チケット 1 日・セッション 30 日・ストリーム識別子 30 日")
check(periods.all? { |subject, days| !RetentionPolicy.expired?(subject: subject, reference_at: T0, now: T0 + days * DAY - 1) && RetentionPolicy.expired?(subject: subject, reference_at: T0, now: T0 + days * DAY) }, "各対象の境界: 期限の 1 秒前は失効しない・ちょうどで失効する")
check(RetentionPolicy.cutoffs(now: T0 + 100 * DAY).all? { |subject, cutoff| cutoff == T0 + (100 - periods.fetch(subject)) * DAY }, "now から、削除の基準の時刻を算出する")
check(!RetentionPolicy.registration_hold_expired?(hold_usage_date: Date.new(2026, 10, 7), usage_date: Date.new(2026, 10, 7)) && RetentionPolicy.registration_hold_expired?(hold_usage_date: Date.new(2026, 10, 7), usage_date: Date.new(2026, 10, 8)), "再登録の保留: 削除時点の利用日の終わりまで（利用日は引数で受け取る）")
erasure = RetentionPolicy.broadcast_id_erasure(broadcast: snap("ended", youtube_broadcast_id: "dummy-y"), now: T0 + 200 + 30 * DAY)
check(erasure.map(&:kind) == %i[erase_youtube_broadcast_id discard_stream_id], "未清算のまま識別子を消去するときは、配信用ストリームの識別子も破棄する（10.5）")

# ---------------------------------------------------------------------------------------------------------------
section "不変・純粋性（27 章の再現性）"

samples = [
  transition("live", "user_stop"),
  TerminationPlanner.plan(broadcast: with_resource("live"), reason: "time_limit"),
  SettlementRules.apply_result(settlement_state: "pending", attempts: 3, result: :failed),
  plan.call([ prior.call("p1", "pending") ]),
  evaluate(snap("live"), at: 5000)
]
check(samples.all?(&:frozen?), "戻り値は、凍結された値（Transition・計画・結果・Directive の配列）")
check(evaluate(snap("live"), at: 5000) == evaluate(snap("live"), at: 5000) && transition("live", "user_stop") == transition("live", "user_stop"), "同じ入力に、同じ出力（時刻・設定・現況は引数）")
check(BroadcastSnapshot.new(id: "dummy-b", user_id: "dummy-u", state: "reserved", accepted_at: T0).frozen?, "配信のスナップショットは不変")

puts
if @failures.zero?
  puts "PASS 受け入れ条件の検査に、すべて成功しました"
  exit 0
end
puts "FAIL #{@failures} 件が失敗しました"
exit 1
