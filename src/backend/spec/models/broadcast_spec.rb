require "rails_helper"
require "support/model_support"

# 配信レコード（broadcasts）のモデル。モデルは、業務の判定を持たない（判定は Domain Core・サービス）。
# ここで検査するのは、タイトルの寿命の不変条件（10.1・20.3・28.2）と、既定値・関連。
#   タイトル（pending_title）は、YouTube の配信識別子を保存した時点、または配信レコードを終了した時点の、早い方で消去する。
RSpec.describe Broadcast do
  describe "既定値（受理直後の姿）" do
    subject(:broadcast) { described_class.new }

    it "状態は reserved、清算状態は none、件数・量は 0、印は false" do
      expect(broadcast).to have_attributes(
        state: "reserved", settlement_state: "none", settlement_attempts: 0, prep_reserved_units: 0, settle_reserved_units: 0,
        resume_count: 0, sent_bytes: 0, publisher_epoch: 0, attempt_counted: false, bound: false, allowance_consumed: false
      )
    end

    it "終了理由・プロファイル・タイトル・YouTube の識別子・各時刻は、空" do
      expect(broadcast).to have_attributes(
        end_reason: nil, profile: nil, pending_title: nil, youtube_broadcast_id: nil, youtube_stream_id: nil, scheduled_start_at: nil,
        provisioned_at: nil, publish_started_at: nil, live_at: nil, interrupted_at: nil, last_heartbeat_at: nil, last_checked_at: nil, ended_at: nil
      )
    end
  end

  describe "#record_youtube_broadcast!（YouTube の配信識別子を保存する）" do
    let(:broadcast) { create(:broadcast, pending_title: "dummy-title") }

    it "識別子を保存し、同じ更新（1 つの UPDATE 文）でタイトルを消去する" do
      statements = capture_sql { broadcast.record_youtube_broadcast!("dummy-youtube-broadcast-1") }
      updates = statements.grep(/\AUPDATE "broadcasts"/)

      expect(updates.size).to eq(1)
      expect(updates.first).to include('"youtube_broadcast_id"', '"pending_title"')
      reloaded = described_class.find(broadcast.id)
      expect(reloaded.youtube_broadcast_id).to eq("dummy-youtube-broadcast-1")
      expect(reloaded.pending_title).to be_nil
    end

    it "メモリ上のレコードでも、タイトルが消えている" do
      broadcast.record_youtube_broadcast!("dummy-youtube-broadcast-1")

      expect(broadcast.pending_title).to be_nil
      expect(broadcast.youtube_broadcast_id).to eq("dummy-youtube-broadcast-1")
    end

    it "識別子が空（nil・空文字・空白）なら、ArgumentError。何も変えない（タイトルも残る）" do
      [ nil, "", "  " ].each do |blank|
        expect { broadcast.record_youtube_broadcast!(blank) }.to raise_error(ArgumentError)
      end
      expect(described_class.find(broadcast.id)).to have_attributes(youtube_broadcast_id: nil, pending_title: "dummy-title")
    end

    it "DB の CHECK 制約があるため、識別子だけを保存してタイトルを残す更新は、起こらない（update_columns で迂回しても拒否される）" do
      expect_db_violation(ActiveRecord::CheckViolation) { broadcast.update_columns(youtube_broadcast_id: "dummy-youtube-broadcast-1") }
    end
  end

  describe "#clear_pending_title!" do
    it "タイトルを消去する" do
      broadcast = create(:broadcast, pending_title: "dummy-title")

      broadcast.clear_pending_title!

      expect(broadcast.pending_title).to be_nil
      expect(described_class.find(broadcast.id).pending_title).to be_nil
    end

    it "すでに空でも失敗せず、何も更新しない（冪等）" do
      broadcast = create(:broadcast, pending_title: nil)

      statements = capture_sql { broadcast.clear_pending_title! }

      expect(statements.grep(/\AUPDATE/)).to be_empty
    end
  end

  describe "終了したときのタイトルの消去（保存のたびに、不変条件を保つ）" do
    it "状態を ended へ更新すると、同じ更新（1 つの UPDATE 文）でタイトルが消える" do
      broadcast = create(:broadcast, pending_title: "dummy-title")

      statements = capture_sql { broadcast.update!(state: "ended", end_reason: "user_stop", ended_at: Time.current) }

      expect(statements.grep(/\AUPDATE "broadcasts"/).size).to eq(1)
      expect(described_class.find(broadcast.id).pending_title).to be_nil
    end

    it "終了した状態で作成しても、タイトルは保存されない" do
      broadcast = create(:broadcast, state: "ended", end_reason: "user_cancel", ended_at: Time.current, pending_title: "dummy-title")

      expect(described_class.find(broadcast.id).pending_title).to be_nil
    end

    it "YouTube の識別子を持つ状態で作成しても、タイトルは保存されない" do
      broadcast = create(:broadcast, youtube_broadcast_id: "dummy-youtube-broadcast-2", pending_title: "dummy-title")

      expect(described_class.find(broadcast.id).pending_title).to be_nil
    end

    it "識別子を保存した後・終了した後に、タイトルを書き込んでも、保存されない" do
      ended = create(:broadcast, :ended)
      saved = create(:broadcast, :provisioned)

      ended.update!(pending_title: "dummy-title")
      saved.update!(pending_title: "dummy-title")

      expect(described_class.find(ended.id).pending_title).to be_nil
      expect(described_class.find(saved.id).pending_title).to be_nil
    end

    it "識別子の保存前の、終了していない配信は、ほかの更新があってもタイトルを保つ" do
      broadcast = create(:broadcast, pending_title: "dummy-title")

      broadcast.update!(settlement_attempts: 0, last_heartbeat_at: Time.current)

      expect(described_class.find(broadcast.id).pending_title).to eq("dummy-title")
    end

    it "識別子を消去（保持期間の適用）しても、終了した配信にタイトルは戻らない" do
      ended = create(:broadcast, :ended_unsettled)

      ended.update!(youtube_broadcast_id: nil)

      expect(described_class.find(ended.id).pending_title).to be_nil
    end
  end

  describe "関連" do
    it "アカウント・利用日の利用実績に属し、接続チケット・健全性の標本・出来事・台帳の明細を持つ" do
      user = create(:user)
      records = create_account_records(user)
      broadcast = records.fetch(:broadcast)

      expect(broadcast.user).to eq(user)
      expect(broadcast.daily_usage).to eq(records.fetch(:daily_usage))
      expect(broadcast.relay_tickets).to eq([ records.fetch(:relay_ticket) ])
      expect(broadcast.health_samples).to eq([ records.fetch(:health_sample) ])
      expect(broadcast.broadcast_events).to eq([ records.fetch(:broadcast_event) ])
      expect(broadcast.quota_entries).to eq([ records.fetch(:quota_entry) ])
    end
  end
end
