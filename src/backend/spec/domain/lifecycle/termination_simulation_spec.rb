require "spec_helper"
require_relative "../support/domain_loader"
require_relative "support/lifecycle_helpers"
require_relative "support/no_notification_simulator"

# 終端性（requirements.md 27 章「すべての配信レコードが、通知の有無に関わらず有限時間で終了へ到達すること」・13.2）。
# 全状態 × 通知なし: 事象（中継の通知・心拍・ブラウザの操作）を一切与えずに、時刻だけを進めて、期限の評価（DeadlineEvaluator）の指示を
# 状態へ反映する（終了 → TerminationPlanner、清算 → SettlementRules）。有限時間で、終了し、清算が終端（不要・清算済み・清算不能）に達すること。
#
# 時刻は、基準（LifecycleSpecHelpers::T0）からの秒数。1 秒ずつ進める。
RSpec.describe "全状態 × 通知なし: 有限時間で終端へ進む" do
  include LifecycleSpecHelpers

  t0 = LifecycleSpecHelpers::T0

  # 状態 => [開始の時刻（T0 から）, 上書きする値]。既定の配信（lifecycle_helpers）は、各状態の起点が、この開始の時刻より前
  starts = {
    "reserved" => [ 0, {} ],
    "awaiting_media" => [ 20, {} ],
    "confirming" => [ 40, {} ],
    "live" => [ 60, {} ],
    "interrupted" => [ 100, {} ]
  }

  def run_simulation(snapshot, start:, minutes: 60, youtube: NoNotificationSimulator::ALWAYS_FAIL, limit: 2000)
    NoNotificationSimulator.run(
      snapshot: snapshot,
      start_at: LifecycleSpecHelpers::T0 + start,
      settings: settings(time_limit_minutes: minutes),
      youtube: youtube,
      limit_seconds: limit
    )
  end

  describe "終了の時刻（13.2 の表の期限どおり。清算の経過を除く）" do
    # [見出し, 状態, 上書き, 開始, 上限の分, 終了の時刻（T0 から）, 終了理由]
    [
      [ "受理済み: 受理（T0）から 90 秒", "reserved", {}, 0, 60, 90, "start_timeout" ],
      [ "送出待ち: 準備の完了（T0+20）から 30 秒", "awaiting_media", {}, 20, 60, 50, "start_timeout" ],
      [ "確定待ち: 送出開始（T0+40）から 120 秒", "confirming", {}, 40, 60, 160, "confirm_timeout" ],
      [ "ライブ（心拍が届かない）: 10 秒の途絶（T0+70）で中断 → 75 秒後（T0+145）に接続喪失", "live", {}, 60, 60, 145, "connection_lost" ],
      [ "ライブ: 上限が 1 分（T0+120）なら、中断の期限（T0+145）より先に、時間上限", "live", {}, 60, 1, 120, "time_limit" ],
      [ "中断（心拍の途絶。T0+100）: 75 秒後", "interrupted", {}, 100, 60, 175, "connection_lost" ],
      [ "中断（中継の通知。T0+100）: 30 秒後", "interrupted", { relay_notified_at: t0 + 100 }, 100, 60, 130, "connection_lost" ],
      [ "中断（復帰が 10 回を超える）: 直ちに", "interrupted", { resume_count: 10 }, 100, 60, 100, "connection_lost" ]
    ].each do |label, state, overrides, start, minutes, ended_at, reason|
      it "#{label}" do
        result = run_simulation(snapshot(state, **overrides), start: start, minutes: minutes)

        expect(result.final.state).to eq("ended")
        expect(result.final.end_reason).to eq(reason)
        expect(result.final.ended_at).to eq(t0 + ended_at)
      end
    end
  end

  describe "清算の経過（YouTube 資源を持つ配信。10.4・25.2）" do
    let(:broadcast) { snapshot("awaiting_media") } # 終了は T0+50（開始タイムアウト）。資源あり

    it "最初の試行で清算できれば、終了と同時に清算済み（予約の解放）" do
      result = run_simulation(broadcast, start: 20, youtube: NoNotificationSimulator::SUCCEEDS)

      expect(result.final.settlement_state).to eq("settled")
      expect(result.final.settlement_attempts).to eq(1)
      expect(result.elapsed_seconds).to eq(30) # 開始 T0+20 から、終了 T0+50 まで
    end

    it "清算が失敗し続ければ、1・2・4 分の間隔で 3 回再試行し、清算不能になる（終了の 420 秒後）" do
      result = run_simulation(broadcast, start: 20, youtube: NoNotificationSimulator::ALWAYS_FAIL)

      expect(result.final.settlement_state).to eq("abandoned")
      expect(result.final.settlement_attempts).to eq(4) # 最初の試行 + 再試行 3 回
      expect(result.elapsed_seconds).to eq(30 + 60 + 120 + 240)
      expect(result.attempt_times).to eq([ 50, 110, 230, 470 ].map { |seconds| seconds - 20 })
    end

    it "2 回目の再試行で清算できれば、その時点で清算済み（終了の 180 秒後）" do
      youtube = ->(attempts_before) { attempts_before >= 2 ? :success : :failed }
      result = run_simulation(broadcast, start: 20, youtube: youtube)

      expect(result.final.settlement_state).to eq("settled")
      expect(result.elapsed_seconds).to eq(30 + 60 + 120)
    end

    it "「存在しない」「すでに終端」は清算済み（再試行しない）" do
      %i[not_found already_terminal].each do |kind|
        result = run_simulation(broadcast, start: 20, youtube: ->(_attempts) { kind })

        expect(result.final.settlement_state).to eq("settled")
        expect(result.final.settlement_attempts).to eq(1)
      end
    end

    it "遷移・削除できない（終端ではない）が続けば、清算済みにせず、再試行ののち清算不能" do
      result = run_simulation(broadcast, start: 20, youtube: ->(_attempts) { :not_transitionable })

      expect(result.final.settlement_state).to eq("abandoned")
    end

    it "最初の試行が記録されないまま（終了処理の途中でアプリケーションが停止）でも、期限監視が、終了の 1 分後から清算する" do
      stuck = ended_snapshot(settlement_state: "pending", settlement_attempts: 0, settlement_attempted_at: nil)
      result = run_simulation(stuck, start: 200, youtube: NoNotificationSimulator::ALWAYS_FAIL)

      expect(result.final.settlement_state).to eq("abandoned")
      expect(result.attempt_times).to eq([ 60, 120, 240, 480 ].map { |seconds| seconds + 0 })
    end
  end

  describe "YouTube 資源を持たない配信（準備の前に終了）" do
    it "清算状態は不要。終了と同時に終端（清算の経過は無い）" do
      result = run_simulation(snapshot("reserved"), start: 0)

      expect(result.final.settlement_state).to eq("none")
      expect(result.elapsed_seconds).to eq(90)
      expect(result.attempt_times).to eq([])
    end
  end

  describe "全状態 × 資源の有無 × 清算の結果 × 上限（性質: 必ず、有限時間で、終端へ進む）" do
    # 上限（分）。短いものから、長いものまで
    minutes_list = [ 1, 3, 5, 30, 60, 600 ]
    youtubes = { "常に失敗" => :ALWAYS_FAIL, "成功" => :SUCCEEDS }

    starts.each do |state, (start, overrides)|
      [ true, false ].each do |with_resource|
        youtubes.each do |youtube_label, youtube_name|
          it "#{state}・資源#{with_resource ? "あり" : "なし"}・清算#{youtube_label}: 上限 #{minutes_list.join('・')} 分のどれでも、終端へ進む" do
            resource = with_resource ? {} : { youtube_broadcast_id: nil, youtube_stream_id: nil }
            youtube = NoNotificationSimulator.const_get(youtube_name)

            minutes_list.each do |minutes|
              result = run_simulation(snapshot(state, **overrides, **resource), start: start, minutes: minutes, youtube: youtube, limit: 800)
              final = result.final

              expect(final.state).to eq("ended"), "#{state} #{minutes} 分: 終了しない"
              expect(%w[none settled abandoned]).to include(final.settlement_state), "#{state} #{minutes} 分: 清算が終端に達しない"
              expect(result.elapsed_seconds).to be <= 800
            end
          end
        end
      end
    end

    it "開始の時刻が、起点より遅くても（期限監視が、長く止まっていた）、評価を始めた時点で、終端へ進む" do
      starts.each do |state, (start, overrides)|
        result = run_simulation(snapshot(state, **overrides), start: start + 5000, limit: 500)

        expect(result.final.state).to eq("ended"), state
        expect(%w[none settled abandoned]).to include(result.final.settlement_state), state
      end
    end
  end

  describe "シミュレーターの検査（このスペックの前提）" do
    it "終了の指示は、状態遷移の表（BroadcastStateMachine）が、その状態から終了へ遷移させる理由だけ。違えば、シミュレーターが例外にする" do
      broadcast = snapshot("reserved")
      directive = Directive.of(:end, reason: "time_limit") # 受理済みから時間上限は、表に無い

      expect { NoNotificationSimulator.apply(broadcast, directive, LifecycleSpecHelpers::T0, NoNotificationSimulator::SUCCEEDS) }
        .to raise_error(NoNotificationSimulator::InconsistentDirective, /time_limit/)
    end

    it "終端へ進まなければ、DidNotTerminate（期限の評価が、終端へ導かない場合の検知）" do
      stuck = ended_snapshot(settlement_state: "pending", settlement_attempts: 0)

      expect { run_simulation(stuck, start: 200, limit: 10) }.to raise_error(NoNotificationSimulator::DidNotTerminate)
    end
  end
end
