require "spec_helper"
require_relative "../support/domain_loader"
require_relative "support/lifecycle_helpers"

# 配信レコードのスナップショット（BroadcastSnapshot）。AR モデルを渡さず、必要な値だけを持つ不変の値オブジェクト。
# 期限の評価・終了処理・先行配信の清算確認が、評価の対象として受け取る。
# 状態ごとに必要な時刻・状態どうしの整合を、作成時に検査する（不整合は、黙って通さず ArgumentError）。
RSpec.describe "配信レコードのスナップショット（BroadcastSnapshot）" do
  include LifecycleSpecHelpers

  all_states = %w[reserved awaiting_media confirming live interrupted ended]

  describe "作成" do
    all_states.each do |state|
      it "#{state}: 整合した値で作成できる" do
        built = snapshot(state)

        expect(built.state).to eq(state)
        expect(built.id).to eq("dummy-broadcast-1")
        expect(built.user_id).to eq("dummy-user-1")
      end
    end

    it "省略した項目は、既定値になる（清算状態 none・回数 0・予告の送出済みの印 false・時刻と識別子は nil）" do
      built = BroadcastSnapshot.new(id: "dummy-broadcast-1", user_id: "dummy-user-1", state: "reserved", accepted_at: LifecycleSpecHelpers::T0)

      expect(built.settlement_state).to eq("none")
      expect(built.settlement_attempts).to eq(0)
      expect(built.resume_count).to eq(0)
      expect(built.time_limit_notice_sent).to be(false)
      expect(built.end_reason).to be_nil
      expect(built.youtube_broadcast_id).to be_nil
      expect(built.youtube_stream_id).to be_nil
      %i[provisioned_at publish_started_at live_at interrupted_at relay_notified_at last_heartbeat_at last_checked_at ended_at settlement_attempted_at].each do |field|
        expect(built.public_send(field)).to be_nil, "#{field} は既定で nil"
      end
    end

    it "不変（凍結される）。with で、検査つきの複製を作れる" do
      built = snapshot("live")

      expect(built).to be_frozen
      expect(built.with(resume_count: 3).resume_count).to eq(3)
      expect(built.resume_count).to eq(0)
      expect { built.with(state: "ended") }.to raise_error(ArgumentError, /ended_at is required in state ended/)
    end

    it "同じ値なら等しい（値として比べる）" do
      expect(snapshot("live")).to eq(snapshot("live"))
      expect(snapshot("live")).not_to eq(snapshot("live", resume_count: 1))
    end
  end

  describe "述語" do
    it "ended? は、終了だけが真" do
      expect(all_states.select { |state| snapshot(state).ended? }).to eq([ "ended" ])
    end

    it "youtube_resource? は、YouTube の配信の識別子があるときだけ真（ストリームの識別子だけでは、資源を持たない）" do
      expect(snapshot("live").youtube_resource?).to be(true)
      expect(snapshot("reserved").youtube_resource?).to be(false)
      expect(snapshot("reserved", youtube_stream_id: "dummy-youtube-stream-1").youtube_resource?).to be(false)
    end
  end

  describe "検査（不整合は ArgumentError。メッセージに配信の識別子を載せる）" do
    {
      "識別子が空" => [ [ "reserved", { id: "" } ], /id must be a non-empty String/ ],
      "アカウント識別子が nil" => [ [ "reserved", { user_id: nil } ], /user_id must be a non-empty String/ ],
      "状態が契約に無い値" => [ [ "reserved", { state: "unknown" } ], /state must be a Contract::BroadcastState value/ ],
      "状態がシンボル" => [ [ "reserved", { state: :reserved } ], /state must be a Contract::BroadcastState value/ ],
      "清算状態が契約に無い値" => [ [ "reserved", { settlement_state: "unknown" } ], /settlement_state must be a Contract::SettlementState value/ ],
      "終了理由が契約に無い値" => [ [ "ended", { end_reason: "unknown" } ], /end_reason must be a Contract::EndReason value/ ],
      "受理の時刻が文字列" => [ [ "reserved", { accepted_at: "2026-10-07T12:00:00Z" } ], /accepted_at must be a Time, got String/ ],
      "受理の時刻が nil" => [ [ "reserved", { accepted_at: nil } ], /accepted_at must be a Time, got NilClass/ ],
      "心拍の時刻が文字列" => [ [ "live", { last_heartbeat_at: "x" } ], /last_heartbeat_at must be a Time or nil, got String/ ],
      "清算の試行回数が負" => [ [ "ended", { settlement_attempts: -1 } ], /settlement_attempts must be >= 0, got -1/ ],
      "清算の試行回数が小数" => [ [ "ended", { settlement_attempts: 1.5 } ], /settlement_attempts must be an Integer, got Float/ ],
      "復帰の回数が負" => [ [ "live", { resume_count: -1 } ], /resume_count must be >= 0, got -1/ ],
      "予告の送出済みの印が真偽値でない" => [ [ "live", { time_limit_notice_sent: "yes" } ], /time_limit_notice_sent must be true or false, got String/ ],
      "配信の識別子が空文字列" => [ [ "live", { youtube_broadcast_id: "" } ], /youtube_broadcast_id must be a non-empty String or nil, got String/ ],
      "ストリームの識別子が数値" => [ [ "live", { youtube_stream_id: 1 } ], /youtube_stream_id must be a non-empty String or nil, got Integer/ ]
    }.each do |label, ((state, overrides), message)|
      it "#{label}: 拒否する" do
        expect { snapshot(state, **overrides) }.to raise_error(ArgumentError, message)
      end
    end

    {
      "送出待ちに、準備の完了の時刻が無い" => [ "awaiting_media", { provisioned_at: nil }, /provisioned_at is required in state awaiting_media/ ],
      "確定待ちに、送出開始の時刻が無い" => [ "confirming", { publish_started_at: nil }, /publish_started_at is required in state confirming/ ],
      "ライブに、ライブ確定の時刻が無い" => [ "live", { live_at: nil }, /live_at is required in state live/ ],
      "中断に、ライブ確定の時刻が無い" => [ "interrupted", { live_at: nil }, /live_at is required in state interrupted/ ],
      "中断に、中断の時刻が無い" => [ "interrupted", { interrupted_at: nil }, /interrupted_at is required in state interrupted/ ],
      "終了に、終了の時刻が無い" => [ "ended", { ended_at: nil }, /ended_at is required in state ended/ ],
      "終了に、終了理由が無い" => [ "ended", { end_reason: nil }, /end_reason is required in state ended/ ],
      "終了していないのに、終了理由がある" => [ "live", { end_reason: "user_stop" }, /end_reason must be nil unless the state is ended/ ],
      "終了していないのに、清算状態が none でない" => [ "live", { settlement_state: "pending" }, /settlement_state must be none unless the state is ended/ ],
      "中継の通知の時刻が、中断の時刻より前（前の中断の値が残っている）" => [
        "interrupted", { interrupted_at: LifecycleSpecHelpers::T0 + 100, relay_notified_at: LifecycleSpecHelpers::T0 + 99 },
        /relay_notified_at must not be earlier than interrupted_at/
      ]
    }.each do |label, (state, overrides, message)|
      it "#{label}: 拒否する" do
        expect { snapshot(state, **overrides) }.to raise_error(ArgumentError, message)
      end
    end

    it "メッセージに配信の識別子を載せる（どの配信で失敗したかをたどれる）" do
      expect { snapshot("live", live_at: nil) }.to raise_error(ArgumentError, /broadcast_id=dummy-broadcast-1/)
      expect { snapshot("live", resume_count: -1) }.to raise_error(ArgumentError, /broadcast_id=dummy-broadcast-1/)
    end

    it "中継の通知の時刻が、中断の時刻と同じ（通知による中断）なら通す" do
      built = snapshot("interrupted", relay_notified_at: LifecycleSpecHelpers::T0 + 100)

      expect(built.relay_notified_at).to eq(built.interrupted_at)
    end

    it "ライブへ復帰したあと、前の中断の時刻と通知の時刻が残っていても、整合していれば通す" do
      built = snapshot("live", interrupted_at: LifecycleSpecHelpers::T0 + 70, relay_notified_at: LifecycleSpecHelpers::T0 + 70, resume_count: 1)

      expect(built.state).to eq("live")
    end
  end

  describe "清算の試行回数と状態" do
    %w[none pending settled abandoned].each do |settlement_state|
      it "終了した配信は、清算状態 #{settlement_state} を持てる" do
        expect(ended_snapshot(settlement_state: settlement_state).settlement_state).to eq(settlement_state)
      end
    end
  end
end
