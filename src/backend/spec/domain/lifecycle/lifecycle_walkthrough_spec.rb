require "spec_helper"
require_relative "../support/domain_loader"
require_relative "support/lifecycle_helpers"

# 配信の生命周期の規則を、組み合わせて使う流れ（結合）。アプリケーション層のアダプタ（#13・#14・#15）が、これらの規則を
# どの順で呼ぶかの例でもある。単体の規則は、それぞれのスペックで検査している。
RSpec.describe "配信の生命周期の流れ（結合）" do
  include LifecycleSpecHelpers

  t0 = LifecycleSpecHelpers::T0

  def step(state, event)
    BroadcastStateMachine.transition(state: state, event: event)
  end

  def evaluate(broadcast, at:)
    DeadlineEvaluator.evaluate(broadcast: broadcast, now: LifecycleSpecHelpers::T0 + at, settings: settings)
  end

  it "正常な配信: 受理 → 準備の完了 → 送出開始 → ライブ確定（利用枠の消費）→ 利用者の停止 → 未清算 → 完了へ遷移 → 清算済み" do
    state = "reserved"
    consumed = nil
    [ "provision_done", "publish_started", "live_confirmed" ].each do |event|
      transition = step(state, event)
      consumed = transition.effects if event == "live_confirmed"
      state = transition.next_state
    end
    expect(state).to eq("live")
    expect(consumed).to eq([ Directive.of(:consume_allowance) ]) # 利用枠の消費は、ライブへの遷移と同一のトランザクション（14 章）

    stop = step("live", "user_stop")
    expect(stop.next_state).to eq("ended")
    reason = stop.effects.first.args.fetch(:reason)

    plan = TerminationPlanner.plan(broadcast: snapshot("live"), reason: reason)
    expect(plan.steps.map(&:kind)).to eq(%i[end_broadcast stop_publishing settle])
    expect(plan.settlement_state).to eq("pending")

    expect(SettlementRules.plan(youtube_status: "live")).to eq(Directive.of(:transition_to_complete))
    outcome = SettlementRules.apply_result(settlement_state: "pending", attempts: 0, result: :success)
    expect(outcome.settlement_state).to eq("settled")
    expect(outcome.directives).to eq([ Directive.of(:release_reservation) ]) # 終端に達した時点で、予約の残額を解放する（8.4）
  end

  it "タブを閉じた（中継が中断を通知）: 30 秒で接続喪失 → 清算に失敗し続けて清算不能 → ストリームを取り替える → 次の準備を妨げない" do
    # ライブ（T0+60）から、T0+100 に中継が中断を通知した
    interrupted = step("live", "interrupted")
    expect(interrupted.next_state).to eq("interrupted")
    broadcast = snapshot("interrupted", interrupted_at: t0 + 100, relay_notified_at: t0 + 100)

    expect(evaluate(broadcast, at: 129)).to eq([])
    ending = evaluate(broadcast, at: 130)
    expect(ending).to eq([ Directive.of(:end, reason: "connection_lost") ])

    # 期限監視が、終了の指示を事象にして、状態遷移・終了処理へ渡す
    expect(step("interrupted", ending.first.args.fetch(:reason)).next_state).to eq("ended")
    plan = TerminationPlanner.plan(broadcast: broadcast, reason: "connection_lost")
    expect(plan.settle?).to be(true)

    # 最初の試行と、1・2・4 分間隔の再試行 3 回がすべて失敗する（認可の喪失）
    state = "pending"
    outcomes = (0..3).map do |attempts|
      outcome = SettlementRules.apply_result(settlement_state: state, attempts: attempts, result: :forbidden)
      state = outcome.settlement_state
      outcome
    end
    expect(outcomes.map(&:retry_delay_seconds)).to eq([ 60, 120, 240, nil ])
    expect(state).to eq("abandoned")
    expect(outcomes.last.directives).to eq([ Directive.of(:release_reservation), Directive.of(:discard_stream_id) ])
    expect(StreamReplacementPolicy.discard?(trigger: StreamReplacementPolicy::SETTLEMENT_ABANDONED)).to be(true)

    # 次の準備: ストリームの識別子を破棄済み（nil）。清算不能の配信は、準備を妨げない（余裕があれば、再清算する）
    abandoned = ended_snapshot(settlement_state: "abandoned", settlement_attempts: 4)
    check = PriorSettlementCheck.plan(prior_broadcasts: [ abandoned ], current_stream_id: nil, prep_remaining_units: 340, own_prep_cost_units: 202)
    expect(check.verdict).to eq(:clear)
    expect(check.resettle_targets).to eq([ abandoned ])
  end

  it "先行配信が未清算で、同じストリームへ紐づいている: 確認を求め、終端にできなければ準備を中止する（開始試行を計上しない）" do
    prior = ended_snapshot(id: "dummy-prior-1", settlement_state: "pending", settlement_attempts: 1, youtube_stream_id: "dummy-youtube-stream-1")
    check = PriorSettlementCheck.plan(prior_broadcasts: [ prior ], current_stream_id: "dummy-youtube-stream-1", prep_remaining_units: 340, own_prep_cost_units: 202)

    expect(check.verdict).to eq(:settle_required)
    expect(check.confirm_targets).to eq([ prior ])

    # 確認の結果、遷移できない（終端にできない）。未清算のまま
    result = SettlementRules.apply_result(settlement_state: "pending", attempts: 1, result: SettlementRules.result_for_error(reason: "invalidTransition"))
    expect(result.settlement_state).to eq("pending")

    # 準備を中止し、配信を終了する。まだ YouTube 資源を作成していないので、清算は不要
    abort_directive = check.on_unsettled
    expect(abort_directive.args).to eq({ end_reason: "prior_unsettled", count_attempt: false })
    expect(step("reserved", abort_directive.args.fetch(:end_reason)).next_state).to eq("ended")
    plan = TerminationPlanner.plan(broadcast: snapshot("reserved"), reason: abort_directive.args.fetch(:end_reason))
    expect(plan.settlement_state).to eq("none")
    expect(plan.release_reservation).to be(true)
  end

  it "清算が終わったら、識別子を消去する期限（終了から 30 日）まで保持し、未清算のまま消去するなら、ストリームも取り替える" do
    ended = ended_snapshot(settlement_state: "pending", settlement_attempts: 1)
    due = ended.ended_at + RetentionPolicy.period_seconds(:youtube_broadcast_id)

    expect(RetentionPolicy.broadcast_id_erasure(broadcast: ended, now: due - 1)).to eq([])
    expect(RetentionPolicy.broadcast_id_erasure(broadcast: ended, now: due).map(&:kind)).to eq(%i[erase_youtube_broadcast_id discard_stream_id])
  end
end
