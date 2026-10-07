require "spec_helper"
require_relative "../support/domain_loader"
require_relative "support/lifecycle_helpers"

# 期限の評価（requirements.md 15 章「期限の評価」・13.2・10.2・10.3・10.4）。
# DeadlineEvaluator.evaluate(broadcast:, now:, settings:) が、配信レコード（BroadcastSnapshot）と時刻から、遷移の指示（Directive の配列）を返す。
# 配信レコードの終了以外のすべての状態は期限を持ち、期限監視が、中継・ブラウザからの通知が無くても、終端へ進める。
#
# 期限ちょうどの時刻は、期限切れとして扱う（now >= 期限。「期限に達した」）。各行の境界を、1 秒前・ちょうど・1 秒後で検査する。
# 時刻は、基準（LifecycleSpecHelpers::T0）からの秒数で書く。
RSpec.describe "期限の評価（DeadlineEvaluator）" do
  include LifecycleSpecHelpers

  t0 = LifecycleSpecHelpers::T0

  def evaluate(broadcast, at:, minutes: 60)
    DeadlineEvaluator.evaluate(broadcast: broadcast, now: LifecycleSpecHelpers::T0 + at, settings: settings(time_limit_minutes: minutes))
  end

  def ends(reason)
    [ Directive.of(:end, reason: reason) ]
  end

  def kinds(directives)
    directives.map(&:kind)
  end

  describe "13.2 の表の値（契約の limits.json の deadlines）" do
    it "要件の値と一致する（受理済み 90・送出待ち 30・確定待ち 120・中断 30/75・心拍の途絶 10・復帰 10 回・確認 5 秒/5 分・予告 5 分・清算 1/2/4 分）" do
      deadlines = Contract::Limits::DEADLINES

      expect(deadlines.values_at(
        "reserved_seconds", "awaiting_media_seconds", "confirming_seconds",
        "interrupted_relay_notified_seconds", "interrupted_heartbeat_lost_seconds", "heartbeat_lost_detect_seconds",
        "max_resumes", "live_confirm_poll_interval_seconds", "live_check_interval_seconds", "time_limit_notice_before_seconds"
      )).to eq([ 90, 30, 120, 30, 75, 10, 10, 5, 300, 300 ])
      expect(deadlines.fetch("settlement_retry_delays_seconds")).to eq([ 60, 120, 240 ])
    end
  end

  # 終了の指示を返す行。[見出し, 状態, 上書きする値, 期限の時刻（T0 からの秒数）, 終了理由, 評価の時刻の心拍を新しくするか]
  end_rows = [
    [ "受理済み: 受理（T0）から 90 秒以内に送出待ちへ進まない", "reserved", {}, 90, "start_timeout", false ],
    [ "送出待ち: 準備の完了（T0+20）から 30 秒以内に送出開始が無い", "awaiting_media", {}, 50, "start_timeout", false ],
    [ "確定待ち: 送出開始（T0+40）から 120 秒以内にライブにならない", "confirming", {}, 160, "confirm_timeout", false ],
    [ "中断（中継の通知。T0+100）: 通知から 30 秒以内に復帰が無い", "interrupted", { relay_notified_at: t0 + 100 }, 130, "connection_lost", false ],
    [ "中断（心拍の途絶。T0+100）: 75 秒以内に復帰が無い", "interrupted", {}, 175, "connection_lost", false ],
    [ "中断（心拍の途絶が先・T0+100。通知が後・T0+130）: 先の期限（175）より、新しい期限（130+30=160）が早ければ、新しい期限", "interrupted", { relay_notified_at: t0 + 130 }, 160, "connection_lost", false ],
    [ "中断（心拍の途絶が先・T0+100。通知が後・T0+160）: 新しい期限（190）より、先の期限（175）が早ければ、先の期限", "interrupted", { relay_notified_at: t0 + 160 }, 175, "connection_lost", false ],
    [ "ライブ: ライブ確定（T0+60）から 60 分で、時間上限", "live", {}, 3660, "time_limit", true ],
    [ "中断: ライブ確定（T0+60）から 60 分で、時間上限（中断の期限は、まだ先）", "interrupted", { interrupted_at: t0 + 3650, relay_notified_at: nil }, 3660, "time_limit", false ]
  ]

  describe "期限の境界（ちょうど・1 秒前・1 秒後）" do
    end_rows.each do |label, state, overrides, due, reason, fresh_heartbeat|
      describe label do
        build = lambda do |context, at|
          attrs = fresh_heartbeat ? overrides.merge(last_heartbeat_at: t0 + at - 1) : overrides
          context.snapshot(state, **attrs)
        end

        it "1 秒前（#{due - 1} 秒）: 終了しない" do
          expect(kinds(evaluate(build.call(self, due - 1), at: due - 1))).not_to include(:end)
        end

        it "ちょうど（#{due} 秒）: #{reason} で終了する（指示は終了だけ）" do
          expect(evaluate(build.call(self, due), at: due)).to eq(ends(reason))
        end

        it "1 秒後（#{due + 1} 秒）: #{reason} で終了する" do
          expect(evaluate(build.call(self, due + 1), at: due + 1)).to eq(ends(reason))
        end

        it "終了の理由は、状態遷移の表（BroadcastStateMachine）で、この状態から終了へ遷移できる" do
          transition = BroadcastStateMachine.transition(state: state, event: reason)

          expect(transition.next_state).to eq("ended")
        end
      end
    end
  end

  describe "受理済み・送出待ち（準備の途中）" do
    it "期限の前は、指示なし（受理済み）" do
      expect(evaluate(snapshot("reserved"), at: 45)).to eq([])
    end

    it "期限の前は、指示なし（送出待ち）" do
      expect(evaluate(snapshot("awaiting_media"), at: 30)).to eq([])
    end

    it "YouTube 資源を作成済みでも、終了の指示は同じ（清算は、終了処理 TerminationPlanner が、資源の有無から決める）" do
      broadcast = snapshot("reserved", youtube_broadcast_id: "dummy-youtube-broadcast-1")

      expect(evaluate(broadcast, at: 90)).to eq(ends("start_timeout"))
    end
  end

  describe "確定待ち: ライブ確定の確認（5 秒間隔）" do
    # 送出開始は T0+40
    {
      "最後の確認（T0+100）の 4 秒後" => [ { last_checked_at: t0 + 100 }, 104, [] ],
      "最後の確認（T0+100）の 5 秒後（ちょうど）" => [ { last_checked_at: t0 + 100 }, 105, [ [ :poll_live_confirmation, {} ] ] ],
      "最後の確認（T0+100）の 6 秒後" => [ { last_checked_at: t0 + 100 }, 106, [ [ :poll_live_confirmation, {} ] ] ],
      "まだ確認していない（送出開始の直後から確認する）" => [ { last_checked_at: nil }, 40, [ [ :poll_live_confirmation, {} ] ] ]
    }.each do |label, (overrides, at, expected)|
      it "#{label}: #{expected.empty? ? "指示なし" : "poll_live_confirmation"}" do
        directives = evaluate(snapshot("confirming", **overrides), at: at)

        expect(directives).to eq(expected.map { |kind, args| Directive.new(kind: kind, args: args) })
      end
    end

    it "120 秒の期限に達したら、確認の指示ではなく、終了だけを返す" do
      expect(evaluate(snapshot("confirming", last_checked_at: nil), at: 160)).to eq(ends("confirm_timeout"))
    end
  end

  describe "ライブ: 心拍の途絶（10 秒）→ 中断（期限 75 秒）" do
    # ライブ確定は T0+60、最後の心拍は T0+300
    it "9 秒（1 秒前）: 指示なし" do
      expect(evaluate(snapshot("live", last_heartbeat_at: t0 + 300), at: 309)).to eq([])
    end

    {
      "10 秒（ちょうど）" => 310,
      "11 秒（1 秒後）" => 311,
      "ずっと後（期限監視が止まっていた）" => 400
    }.each do |label, at|
      it "#{label}: 中断の指示（原因は心拍の途絶。期限は、評価の時刻から 75 秒）" do
        directives = evaluate(snapshot("live", last_heartbeat_at: t0 + 300), at: at)

        expect(directives).to eq([ Directive.of(:interrupt, cause: :heartbeat_lost, deadline_at: t0 + at + 75) ])
      end
    end

    it "中断の指示の期限は、中断の期限の規則（心拍の途絶: 中断の時刻から 75 秒）と同じ" do
      directive = evaluate(snapshot("live", last_heartbeat_at: t0 + 300), at: 310).first

      expect(directive.args.fetch(:deadline_at)).to eq(DeadlineEvaluator.interruption_deadline(interrupted_at: t0 + 310, relay_notified_at: nil))
    end

    it "心拍が一度も届いていなければ、ライブ確定の時刻（T0+60）から数える（有限時間で終端へ進めるため）" do
      broadcast = snapshot("live", last_heartbeat_at: nil)

      expect(evaluate(broadcast, at: 69)).to eq([])
      expect(kinds(evaluate(broadcast, at: 70))).to eq([ :interrupt ])
    end

    it "最後の心拍が、ライブ確定より前なら、ライブ確定の時刻から数える（確定の直後の心拍の途絶を、すぐに中断としない）" do
      broadcast = snapshot("live", last_heartbeat_at: t0 + 30)

      expect(evaluate(broadcast, at: 69)).to eq([])
      expect(kinds(evaluate(broadcast, at: 70))).to eq([ :interrupt ])
    end

    it "心拍の途絶と時間上限が同時に起きていたら、終了（時間上限）を優先する" do
      broadcast = snapshot("live", last_heartbeat_at: t0 + 60)

      expect(evaluate(broadcast, at: 3660)).to eq(ends("time_limit"))
    end

    it "中断の指示を返すとき、他の指示（確認・予告）は返さない" do
      broadcast = snapshot("live", last_heartbeat_at: t0 + 60, last_checked_at: t0 + 60)

      expect(kinds(evaluate(broadcast, at: 3400))).to eq([ :interrupt ])
    end
  end

  describe "中断: 期限と復帰の回数" do
    describe ".interruption_deadline（中断の期限）" do
      {
        "心拍の途絶による中断（通知なし）: 中断の時刻から 75 秒" => [ 100, nil, 175 ],
        "通知による中断（中断の時刻と通知が同じ）: 30 秒。通知のあとに心拍も途絶しても、30 秒のまま" => [ 100, 100, 130 ],
        "心拍の途絶が先・通知が後: 通知の期限（130+30=160）が早い" => [ 100, 130, 160 ],
        "心拍の途絶が先・通知が後: 先の期限（175）が早い" => [ 100, 160, 175 ],
        "心拍の途絶が先・通知が後: 2 つの期限が同じ（175）" => [ 100, 145, 175 ]
      }.each do |label, (interrupted, notified, deadline)|
        it label do
          actual = DeadlineEvaluator.interruption_deadline(
            interrupted_at: t0 + interrupted,
            relay_notified_at: notified && t0 + notified
          )

          expect(actual).to eq(t0 + deadline)
        end
      end
    end

    describe "復帰が 10 回を超える中断は、復帰を待たずに終了（接続喪失）" do
      {
        "復帰 9 回（あと 1 回復帰できる）: 期限まで待つ" => [ 9, false ],
        "復帰 10 回（11 回目の復帰は許さない）: 直ちに終了" => [ 10, true ],
        "復帰 11 回（あり得ないが、超過）: 直ちに終了" => [ 11, true ]
      }.each do |label, (resume_count, ended)|
        it "#{label}" do
          expect(evaluate(snapshot("interrupted", resume_count: resume_count), at: 101)).to eq(ended ? ends("connection_lost") : [])
        end
      end

      it "中断に入った直後（中断の時刻ちょうど）でも、終了する" do
        expect(evaluate(snapshot("interrupted", resume_count: 10), at: 100)).to eq(ends("connection_lost"))
      end

      it "ライブ状態では、復帰の回数による終了は無い（中断に入ってから）" do
        broadcast = snapshot("live", last_heartbeat_at: t0 + 100, resume_count: 10)

        expect(evaluate(broadcast, at: 101)).to eq([])
      end
    end

    describe "複数の期限が過ぎているとき、先に期限が来た理由で終了する（1 つの終了の指示）" do
      it "時間上限（T0+120）が、中断の期限（T0+175）より先なら、時間上限" do
        broadcast = snapshot("interrupted", interrupted_at: t0 + 100)

        expect(evaluate(broadcast, at: 500, minutes: 1)).to eq(ends("time_limit"))
      end

      it "中断の期限（T0+3575）が、時間上限（T0+3660）より先なら、接続喪失" do
        broadcast = snapshot("interrupted", interrupted_at: t0 + 3500)

        expect(evaluate(broadcast, at: 4000)).to eq(ends("connection_lost"))
      end

      it "復帰の回数の超過（中断の時刻）が、時間上限より先なら、接続喪失" do
        broadcast = snapshot("interrupted", interrupted_at: t0 + 100, resume_count: 10)

        expect(evaluate(broadcast, at: 5000, minutes: 1)).to eq(ends("connection_lost"))
      end

      it "期限が同じ時刻なら、表の順（接続喪失が先）。中断の期限（T0+165+75）と時間上限（T0+60+180）が同じ" do
        broadcast = snapshot("interrupted", interrupted_at: t0 + 165)

        expect(evaluate(broadcast, at: 240, minutes: 3)).to eq(ends("connection_lost"))
      end
    end

    it "中断では、確認・予告の指示は返さない（期限の前は、指示なし）" do
      expect(evaluate(snapshot("interrupted"), at: 120)).to eq([])
    end
  end

  describe "時間上限（設定 time_limit_minutes。進行中の配信にも、評価の時点の設定を適用する）" do
    {
      "1 秒前（T0+1859）" => [ 1859, false ],
      "ちょうど（T0+1860）" => [ 1860, true ],
      "1 秒後（T0+1861）" => [ 1861, true ]
    }.each do |label, (at, ended)|
      it "上限を 30 分にすれば、ライブ確定（T0+60）から 30 分（T0+1860）で終了する。#{label}: #{ended ? "終了" : "終了しない"}" do
        broadcast = snapshot("live", last_heartbeat_at: t0 + at - 1, last_checked_at: t0 + at - 1)

        expect(evaluate(broadcast, at: at, minutes: 30).include?(Directive.of(:end, reason: "time_limit"))).to eq(ended)
      end
    end

    it "同じ配信でも、評価の時点の設定で結果が変わる（設定を保存した値にしない）" do
      broadcast = snapshot("live", last_heartbeat_at: t0 + 1860, last_checked_at: t0 + 1860)

      expect(evaluate(broadcast, at: 1860, minutes: 60)).to eq([])
      expect(evaluate(broadcast, at: 1860, minutes: 30)).to eq(ends("time_limit"))
      expect(evaluate(broadcast, at: 1860, minutes: 60)).to eq([])
    end

    describe "予告（残り 5 分。ライブ確定から 60 分の 5 分前に 1 回）" do
      # ライブ確定は T0+60。予告は T0+60+3300
      {
        "1 秒前" => [ 3359, false, [] ],
        "ちょうど" => [ 3360, false, [ [ :time_limit_notice, { notice_seconds: 300 } ] ] ],
        "1 秒後" => [ 3361, false, [ [ :time_limit_notice, { notice_seconds: 300 } ] ] ],
        "予告を送出済みなら、ちょうどでも指示なし" => [ 3360, true, [] ],
        "予告を送出済みなら、期限の直前でも指示なし" => [ 3659, true, [] ]
      }.each do |label, (at, sent, expected)|
        it "#{label}: #{expected.empty? ? "指示なし" : "time_limit_notice"}" do
          broadcast = snapshot("live", last_heartbeat_at: t0 + at - 1, last_checked_at: t0 + at - 1, time_limit_notice_sent: sent)

          expect(evaluate(broadcast, at: at)).to eq(expected.map { |kind, args| Directive.new(kind: kind, args: args) })
        end
      end

      it "上限に達したら、予告ではなく終了" do
        broadcast = snapshot("live", last_heartbeat_at: t0 + 3659, last_checked_at: t0 + 3659)

        expect(evaluate(broadcast, at: 3660)).to eq(ends("time_limit"))
      end

      it "上限が 5 分以下なら、ライブ確定の直後から予告する。残りは、上限の秒数（上限を超える「残り 5 分」と言わない）" do
        broadcast = snapshot("live", last_heartbeat_at: t0 + 60, last_checked_at: t0 + 60)

        expect(evaluate(broadcast, at: 60, minutes: 3)).to eq([ Directive.of(:time_limit_notice, notice_seconds: 180) ])
        expect(evaluate(broadcast, at: 60, minutes: 5)).to eq([ Directive.of(:time_limit_notice, notice_seconds: 300) ])
      end

      it "中断では、予告の指示は返さない（ブラウザへ届かない。ライブへ復帰してから返す）" do
        broadcast = snapshot("interrupted", interrupted_at: t0 + 3350, relay_notified_at: nil)

        expect(evaluate(broadcast, at: 3360)).to eq([])
      end
    end
  end

  describe "ライブ: ライブ中の定期確認（5 分間隔）" do
    # ライブ確定・最後の確認は T0+60
    {
      "最後の確認の 299 秒後（1 秒前）" => [ { last_checked_at: t0 + 60 }, 359, [] ],
      "最後の確認の 300 秒後（ちょうど）" => [ { last_checked_at: t0 + 60 }, 360, [ [ :poll_live_health, {} ] ] ],
      "最後の確認の 301 秒後（1 秒後）" => [ { last_checked_at: t0 + 60 }, 361, [ [ :poll_live_health, {} ] ] ],
      "まだ確認していない: ライブ確定の時刻から数える（ライブ確定は、確認の 1 回）" => [ { last_checked_at: nil }, 359, [] ],
      "まだ確認していない: ライブ確定の 300 秒後に確認する" => [ { last_checked_at: nil }, 360, [ [ :poll_live_health, {} ] ] ],
      "最後の確認が、ライブ確定より前（確定待ちの確認）: ライブ確定の時刻から数える" => [ { last_checked_at: t0 + 50 }, 359, [] ]
    }.each do |label, (overrides, at, expected)|
      it "#{label}: #{expected.empty? ? "指示なし" : "poll_live_health"}" do
        broadcast = snapshot("live", last_heartbeat_at: t0 + at - 1, **overrides)

        expect(evaluate(broadcast, at: at)).to eq(expected.map { |kind, args| Directive.new(kind: kind, args: args) })
      end
    end

    it "予告と確認が同時に期限なら、両方を返す（予告、確認の順）" do
      broadcast = snapshot("live", last_heartbeat_at: t0 + 3359, last_checked_at: t0 + 60)

      expect(kinds(evaluate(broadcast, at: 3360))).to eq(%i[time_limit_notice poll_live_health])
    end
  end

  describe "終了済み: 清算の再試行だけ（1・2・4 分の間隔で最大 3 回）" do
    # 終了は T0+200
    describe "未清算（pending）" do
      # [見出し, 試行の回数, 最後の試行の時刻（T0 からの秒数。nil は無し）, 再試行の時刻（T0 からの秒数）]
      [
        [ "最初の試行（終了と同時。T0+200）のあと、1 分後に 1 回目の再試行", 1, 200, 260 ],
        [ "1 回目の再試行（T0+260）のあと、2 分後に 2 回目の再試行", 2, 260, 380 ],
        [ "2 回目の再試行（T0+380）のあと、4 分後に 3 回目（最後）の再試行", 3, 380, 620 ],
        [ "最初の試行が記録されていない（試行 0 回）: 終了（T0+200）の 1 分後", 0, nil, 260 ]
      ].each do |label, attempts, attempted_at, due|
        describe label do
          overrides = { settlement_state: "pending", settlement_attempts: attempts, settlement_attempted_at: attempted_at && t0 + attempted_at }

          it "1 秒前（#{due - 1} 秒）: 指示なし" do
            expect(evaluate(ended_snapshot(**overrides), at: due - 1)).to eq([])
          end

          it "ちょうど（#{due} 秒）: 清算の再試行" do
            expect(evaluate(ended_snapshot(**overrides), at: due)).to eq([ Directive.of(:retry_settlement, attempts_made: attempts) ])
          end

          it "1 秒後（#{due + 1} 秒）: 清算の再試行" do
            expect(evaluate(ended_snapshot(**overrides), at: due + 1)).to eq([ Directive.of(:retry_settlement, attempts_made: attempts) ])
          end
        end
      end

      it "最後の試行の時刻が、終了より前に見えても（時計のずれ）、終了の時刻より前から数えない" do
        broadcast = ended_snapshot(settlement_state: "pending", settlement_attempts: 1, settlement_attempted_at: t0 + 150)

        expect(evaluate(broadcast, at: 259)).to eq([])
        expect(kinds(evaluate(broadcast, at: 260))).to eq([ :retry_settlement ])
      end

      it "YouTube の配信の識別子を消去済みなら、清算の対象が無いので、指示なし" do
        broadcast = ended_snapshot(settlement_state: "pending", settlement_attempts: 1, youtube_broadcast_id: nil)

        expect(evaluate(broadcast, at: 100_000)).to eq([])
      end
    end

    describe "終端（不要・清算済み・清算不能）は、指示なし" do
      %w[none settled abandoned].each do |settlement_state|
        it "#{settlement_state}: 時間が経っても、指示なし" do
          broadcast = ended_snapshot(settlement_state: settlement_state, settlement_attempts: 2)

          [ 201, 300, 3600, 1_000_000 ].each { |at| expect(evaluate(broadcast, at: at)).to eq([]) }
        end
      end
    end

    it "清算の再試行以外の指示（終了・中断・確認・予告）を返さない（どの清算状態・どの時刻でも）" do
      %w[none pending settled abandoned].each do |settlement_state|
        broadcast = ended_snapshot(settlement_state: settlement_state, settlement_attempts: 1)

        [ 0, 100, 260, 3600, 1_000_000 ].each do |at|
          expect(kinds(evaluate(broadcast, at: at)) - [ :retry_settlement ]).to eq([])
        end
      end
    end

    it "再試行の上限を超えた未清算（あり得ない状態）は、黙って再試行せず、ArgumentError。メッセージに配信の識別子を載せる（期限監視のログで、どの配信かをたどれる）" do
      broadcast = ended_snapshot(settlement_state: "pending", settlement_attempts: 4)

      expect { evaluate(broadcast, at: 1000) }.to raise_error(ArgumentError, /attempts_made must be <= 3, got 4 \(broadcast_id=dummy-broadcast-1\)/)
    end
  end

  describe "状態遷移の表との整合" do
    it "終了の指示の理由は、評価した状態から終了へ遷移できる理由だけ（全状態・時間を進めて検査）" do
      %w[reserved awaiting_media confirming live interrupted].each do |state|
        [ 0, 100, 200, 400, 1000, 4000, 100_000 ].each do |at|
          evaluate(snapshot(state), at: at).select { |directive| directive.kind == :end }.each do |directive|
            reason = directive.args.fetch(:reason)

            expect(BroadcastStateMachine.transition(state: state, event: reason).next_state).to eq("ended"), "#{state} at #{at}: #{reason}"
          end
        end
      end
    end

    it "中断の指示は、ライブからの中断（心拍の途絶）の遷移と一致する" do
      expect(BroadcastStateMachine.transition(state: "live", event: "interrupted").next_state).to eq("interrupted")
    end
  end

  describe "純粋性・不変・検査" do
    it "同じ入力に、等しい出力を返す。出力は凍結された配列" do
      broadcast = snapshot("confirming", last_checked_at: nil)
      first = evaluate(broadcast, at: 100)

      expect(evaluate(broadcast, at: 100)).to eq(first)
      expect(first).to be_frozen
    end

    it "インスタンスを作らない（状態を持たない）" do
      expect { DeadlineEvaluator.new }.to raise_error(NoMethodError)
    end

    it "broadcast が BroadcastSnapshot でなければ ArgumentError" do
      expect { DeadlineEvaluator.evaluate(broadcast: {}, now: t0, settings: settings) }
        .to raise_error(ArgumentError, "broadcast must be a BroadcastSnapshot, got Hash")
    end

    it "now が Time でなければ ArgumentError" do
      expect { DeadlineEvaluator.evaluate(broadcast: snapshot("reserved"), now: "2026-10-07", settings: settings) }
        .to raise_error(ArgumentError, "now must be a Time, got String")
    end

    it "settings が time_limit_minutes に応答しなければ ArgumentError" do
      expect { DeadlineEvaluator.evaluate(broadcast: snapshot("reserved"), now: t0, settings: Object.new) }
        .to raise_error(ArgumentError, "settings must respond to time_limit_minutes")
    end

    [ 0, -1, 1.5, "60", nil ].each do |minutes|
      it "time_limit_minutes が正の整数でなければ（#{minutes.inspect}）ArgumentError" do
        expect { DeadlineEvaluator.evaluate(broadcast: snapshot("reserved"), now: t0, settings: settings(time_limit_minutes: minutes)) }
          .to raise_error(ArgumentError, /time_limit_minutes must be/)
      end
    end

    it "入力のスナップショットを変えない" do
      broadcast = snapshot("live")

      expect { evaluate(broadcast, at: 5000) }.not_to(change { broadcast })
    end
  end
end
