require "spec_helper"
require_relative "../support/domain_loader"
require_relative "support/lifecycle_helpers"

# 終了処理（requirements.md 15 章「終了処理」・10.4）。TerminationPlanner.plan(broadcast:, reason:)。
# どの起点（利用者の停止・取り消し・期限・YouTube 側の終了・管理者による停止・中継による切断など）でも、同じ規則で計画する。
#   1. 配信レコードを終了とし、同時に清算状態を定める（YouTube 資源があれば未清算、無ければ不要）
#   2. 心拍の応答で、中継へ送出の停止を指示する
#   3. YouTube 資源を清算する（資源があるときだけ）
# 計画は、清算の結果に依存しない（清算の成否に関わらず、配信レコードは終了。利用者の次の操作を妨げない）。
RSpec.describe "終了処理（TerminationPlanner）" do
  include LifecycleSpecHelpers

  # 13 の終了理由と、その起点（requirements.md 13.2・13.3 の表）
  origins = {
    "user_stop" => "利用者の停止",
    "user_cancel" => "利用者の取り消し",
    "time_limit" => "期限（時間上限）",
    "start_timeout" => "期限（開始タイムアウト）",
    "confirm_timeout" => "期限（確定タイムアウト）",
    "connection_lost" => "期限（接続喪失）",
    "youtube_ended" => "YouTube 側の終了",
    "admin_stop" => "管理者による停止",
    "relay_disconnect" => "中継による切断",
    "authorization_revoked" => "認可失効",
    "prepare_failed" => "準備の失敗",
    "prior_unsettled" => "先行配信が未清算",
    "insufficient_bandwidth" => "回線不足"
  }

  # YouTube 資源（配信の識別子）を持つ配信と、持たない配信
  def with_resource(state)
    snapshot(state, youtube_broadcast_id: "dummy-youtube-broadcast-1", youtube_stream_id: "dummy-youtube-stream-1")
  end

  def without_resource(state)
    snapshot(state, youtube_broadcast_id: nil, youtube_stream_id: nil)
  end

  def plan_for(broadcast, reason)
    TerminationPlanner.plan(broadcast: broadcast, reason: reason)
  end

  describe "契約との対応" do
    it "終了理由 13 種すべてを、このスペックの表が持つ" do
      expect(origins.keys).to match_array(Contract::EndReason::ALL)
      expect(origins.size).to eq(13)
    end
  end

  describe ".plan: YouTube 資源（配信の識別子）を持つ配信" do
    origins.each do |reason, origin|
      it "#{reason}（#{origin}）: 清算状態は未清算。終了 → 送出停止の指示 → 清算の順。予約は解放しない。タイトルを消去する" do
        plan = plan_for(snapshot("live"), reason)

        expect(plan.end_reason).to eq(reason)
        expect(plan.settlement_state).to eq("pending")
        expect(plan.steps).to eq(
          [
            Directive.of(:end_broadcast, reason: reason, settlement_state: "pending"),
            Directive.of(:stop_publishing),
            Directive.of(:settle, bucket: :settle)
          ]
        )
        expect(plan.release_reservation).to be(false)
        expect(plan.clear_title).to be(true)
      end
    end
  end

  describe ".plan: YouTube 資源を持たない配信" do
    origins.each do |reason, origin|
      it "#{reason}（#{origin}）: 清算状態は不要。清算の指示は無い。終端なので、予約を即座に解放する。タイトルを消去する" do
        plan = plan_for(snapshot("reserved"), reason)

        expect(plan.end_reason).to eq(reason)
        expect(plan.settlement_state).to eq("none")
        expect(plan.steps).to eq(
          [
            Directive.of(:end_broadcast, reason: reason, settlement_state: "none"),
            Directive.of(:stop_publishing)
          ]
        )
        expect(plan.release_reservation).to be(true)
        expect(plan.clear_title).to be(true)
      end
    end
  end

  describe ".plan: どの起点でも、同じ規則（終了理由の違いだけが、計画の違い）" do
    {
      "YouTube 資源を持つ" => [ :with_resource, "pending" ],
      "YouTube 資源を持たない" => [ :without_resource, "none" ]
    }.each do |label, (build, settlement_state)|
      it "#{label}: 13 の終了理由で、終了理由を除いた計画が同じ" do
        plans = origins.keys.map { |reason| plan_for(public_send(build, "live"), reason) }
        normalized = plans.map { |plan| [ plan.settlement_state, plan.release_reservation, plan.clear_title, plan.steps.map(&:kind) ] }

        expect(normalized.uniq.size).to eq(1)
        expect(plans.map(&:settlement_state).uniq).to eq([ settlement_state ])
        expect(plans.map(&:end_reason)).to eq(origins.keys)
      end
    end

    %w[reserved awaiting_media confirming live interrupted].each do |state|
      it "#{state}: 配信の識別子があれば未清算・無ければ不要（状態によらない）" do
        expect(plan_for(with_resource(state), "admin_stop").settlement_state).to eq("pending")
        expect(plan_for(without_resource(state), "admin_stop").settlement_state).to eq("none")
      end
    end

    it "ストリームの識別子だけを持つ配信（配信の識別子が無い）は、資源を持たない（不要）。ストリームは再利用する資源で、清算の対象ではない" do
      broadcast = snapshot("awaiting_media", youtube_broadcast_id: nil, youtube_stream_id: "dummy-youtube-stream-1")

      expect(plan_for(broadcast, "start_timeout").settlement_state).to eq("none")
    end

    it "清算の成否に依存しない（計画は、清算の結果を引数に取らない）" do
      expect(TerminationPlanner.method(:plan).parameters).to eq([ [ :keyreq, :broadcast ], [ :keyreq, :reason ] ])
    end

    it "予約の残額を解放するのは、清算状態が終端のときだけ（SettlementRules.terminal? と一致する。8.4）" do
      [ :with_resource, :without_resource ].each do |build|
        plan = plan_for(public_send(build, "live"), "user_stop")

        expect(plan.release_reservation).to eq(SettlementRules.terminal?(plan.settlement_state))
      end
    end

    it "settle? は、清算の指示があるとき（YouTube 資源を持つとき）だけ真" do
      expect(plan_for(with_resource("live"), "user_stop").settle?).to be(true)
      expect(plan_for(without_resource("live"), "user_stop").settle?).to be(false)
    end

    it "最初の試行の清算は、終了・清算枠（#5 の QuotaPolicy の :settle）から支出する" do
      settle = plan_for(snapshot("live"), "user_stop").steps.last

      expect(settle.kind).to eq(:settle)
      expect(settle.args).to eq({ bucket: SettlementRules::BUCKET })
    end
  end

  describe ".plan: 検査" do
    it "終了済みの配信には計画しない（清算状態を、あとから上書きして戻さないため）。AlreadyEnded（ArgumentError）で、配信の識別子を載せる" do
      expect { plan_for(ended_snapshot, "user_stop") }
        .to raise_error(TerminationPlanner::AlreadyEnded, /broadcast is already ended \(broadcast_id=dummy-broadcast-1\)/)
      expect(TerminationPlanner::AlreadyEnded.ancestors).to include(ArgumentError)
    end

    it "契約に無い終了理由は ArgumentError" do
      expect { plan_for(snapshot("live"), "unknown") }.to raise_error(ArgumentError, /reason must be a Contract::EndReason value/)
      expect { plan_for(snapshot("live"), :user_stop) }.to raise_error(ArgumentError, /reason must be a Contract::EndReason value/)
      expect { plan_for(snapshot("live"), nil) }.to raise_error(ArgumentError, /reason must be a Contract::EndReason value/)
    end

    it "broadcast が BroadcastSnapshot でなければ ArgumentError" do
      expect { plan_for({ state: "live" }, "user_stop") }.to raise_error(ArgumentError, "broadcast must be a BroadcastSnapshot, got Hash")
    end
  end

  describe ".plan: 純粋性・不変" do
    it "同じ入力に、等しい出力を返す。計画は凍結された値" do
      broadcast = snapshot("live")
      first = plan_for(broadcast, "time_limit")

      expect(plan_for(broadcast, "time_limit")).to eq(first)
      expect(first).to be_frozen
      expect(first.steps).to be_frozen
    end

    it "入力の配信（スナップショット）を変えない" do
      broadcast = snapshot("live")

      expect { plan_for(broadcast, "time_limit") }.not_to(change { broadcast })
      expect(broadcast.state).to eq("live")
      expect(broadcast.settlement_state).to eq("none")
    end

    it "Plan は、終了理由・清算状態・手順・予約の解放の要否・タイトルの消去を持つ" do
      expect(TerminationPlanner::Plan.members).to eq(%i[end_reason settlement_state steps release_reservation clear_title])
    end

    it "インスタンスを作らない（状態を持たない）" do
      expect { TerminationPlanner.new }.to raise_error(NoMethodError)
    end
  end
end
