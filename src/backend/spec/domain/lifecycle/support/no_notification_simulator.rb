# frozen_string_literal: true

# 「全状態 × 通知なし」のシミュレーター（requirements.md 27 章の終端性）。
#
# 配信（BroadcastSnapshot）に、事象（中継の通知・心拍・ブラウザの操作）を一切与えず、時刻だけを進める。
# 各時刻で、期限の評価（DeadlineEvaluator）の指示を、状態へ反映する。
#   end                      終了処理（TerminationPlanner）で、終了と清算状態を定め、YouTube 資源があれば、最初の清算の試行を直ちに行う
#   interrupt                中断（中断の時刻 = 評価の時刻。中継の通知なし）
#   poll_live_confirmation   YouTube はまだライブでない（確認の時刻だけを更新）
#   poll_live_health         YouTube はライブのまま（確認の時刻だけを更新）
#   time_limit_notice        予告を送出済みにする
#   retry_settlement         清算の再試行（結果は、YouTube の代役 youtube が決める）
# 清算が終端（不要・清算済み・清算不能）に達したら、終わり。
#
# rspec（termination_simulation_spec.rb）と、システムテスト（test/pr<番号>/simulate_no_notification.rb）が使う。
# Domain Core の定数は、メソッドの中で参照する（読み込みの時点で参照しない）。
module NoNotificationSimulator
  # 期限の評価が、時間内に終端へ導かなかった。
  class DidNotTerminate < StandardError; end

  # 評価の指示が、状態遷移の表（BroadcastStateMachine）と食い違う。
  class InconsistentDirective < StandardError; end

  # 清算の呼び出しの結果を返す、YouTube の代役。引数は、その試行の前の試行の回数（最初の試行は 0）。
  ALWAYS_FAIL = ->(_attempts_before) { :failed }
  SUCCEEDS = ->(_attempts_before) { :success }

  # final: 最後の配信。elapsed_seconds: 開始からの経過（秒）。attempt_times: 清算の試行の時刻（開始からの秒）。
  # trace: [経過の秒, 指示の種別] の配列
  Result = Struct.new(:final, :elapsed_seconds, :attempt_times, :trace, keyword_init: true)

  module_function

  # snapshot を、start_at から step_seconds ずつ進め、終端（終了済みで、清算が終端）に達するまで評価する。
  # limit_seconds を超えても達しなければ、DidNotTerminate。
  def run(snapshot:, start_at:, settings:, youtube:, limit_seconds:, step_seconds: 1)
    current = snapshot
    elapsed = 0
    attempt_times = []
    trace = []

    until terminal?(current)
      raise DidNotTerminate, "not terminal after #{elapsed}s: state=#{current.state} settlement=#{current.settlement_state} (broadcast_id=#{current.id})" if elapsed > limit_seconds

      DeadlineEvaluator.evaluate(broadcast: current, now: start_at + elapsed, settings: settings).each do |directive|
        before = current.settlement_attempts
        current = apply(current, directive, start_at + elapsed, youtube)
        trace << [ elapsed, directive.kind ]
        attempt_times << elapsed if current.settlement_attempts > before
      end
      elapsed += step_seconds unless terminal?(current)
    end

    Result.new(final: current, elapsed_seconds: elapsed, attempt_times: attempt_times, trace: trace)
  end

  # 終了済みで、清算が終端か。
  def terminal?(snapshot)
    snapshot.ended? && SettlementRules.terminal?(snapshot.settlement_state)
  end

  # 指示を、配信へ反映した、新しい配信。状態遷移の表と食い違う指示は、InconsistentDirective。
  def apply(snapshot, directive, now, youtube)
    case directive.kind
    when :end then finish(snapshot, directive.args.fetch(:reason), now, youtube)
    when :interrupt then interrupt(snapshot, now)
    when :poll_live_confirmation, :poll_live_health then snapshot.with(last_checked_at: now)
    when :time_limit_notice then snapshot.with(time_limit_notice_sent: true)
    when :retry_settlement then attempt(snapshot, now, youtube)
    else raise InconsistentDirective, "unknown directive kind: #{directive.kind.inspect}"
    end
  end

  def finish(snapshot, reason, now, youtube)
    transition = BroadcastStateMachine.transition(state: snapshot.state, event: reason)
    raise InconsistentDirective, "end reason #{reason} is not defined for state #{snapshot.state}" unless transition.next_state == Contract::BroadcastState::ENDED

    plan = TerminationPlanner.plan(broadcast: snapshot, reason: reason)
    ended = snapshot.with(
      state: Contract::BroadcastState::ENDED, end_reason: reason, ended_at: now,
      settlement_state: plan.settlement_state, settlement_attempts: 0, settlement_attempted_at: nil
    )
    plan.settle? ? attempt(ended, now, youtube) : ended
  end

  def interrupt(snapshot, now)
    transition = BroadcastStateMachine.transition(state: snapshot.state, event: Contract::BroadcastEventType::INTERRUPTED)
    raise InconsistentDirective, "interrupt is not defined for state #{snapshot.state}" unless transition.next_state == Contract::BroadcastState::INTERRUPTED

    snapshot.with(state: Contract::BroadcastState::INTERRUPTED, interrupted_at: now, relay_notified_at: nil)
  end

  # 清算の試行 1 回。結果を SettlementRules で反映する。
  def attempt(snapshot, now, youtube)
    result = youtube.call(snapshot.settlement_attempts)
    outcome = SettlementRules.apply_result(
      settlement_state: snapshot.settlement_state, attempts: snapshot.settlement_attempts, result: result
    )
    snapshot.with(settlement_state: outcome.settlement_state, settlement_attempts: outcome.attempts, settlement_attempted_at: now)
  end
end
