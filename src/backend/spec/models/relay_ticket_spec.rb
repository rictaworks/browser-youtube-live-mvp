require "rails_helper"
require "support/model_support"

# 接続チケット（relay_tickets）のモデル。要約値のみを保存する（チケットそのものの列を持たない。11.9・14 章）。
# 使用済みの印（used_at）は、1 度だけ立てられる（20.2）。条件付き更新（used_at が NULL の行だけを更新する）で、原子的に確保する。
# 同時の呼び出しでの検査は、spec/models/schema/concurrency_spec.rb。
RSpec.describe RelayTicket do
  it "チケットそのものを保存する列を持たない（要約値の列 token_digest だけ）" do
    expect(described_class.column_names).to match_array(%w[ id user_id broadcast_id token_digest epoch expires_at used_at ])
  end

  describe "#mark_used（使用済みの印を、1 度だけ立てる）" do
    let(:ticket) { create(:relay_ticket) }
    let(:first_time) { Time.utc(2026, 10, 7, 4, 30, 0) }
    let(:second_time) { Time.utc(2026, 10, 7, 4, 31, 0) }

    it "最初の呼び出しは true を返し、used_at を立てる" do
      expect(ticket.mark_used(first_time)).to be(true)

      expect(described_class.find(ticket.id).used_at).to eq(first_time)
      expect(ticket.used_at).to eq(first_time)
    end

    it "2 回目の呼び出しは false を返し、used_at を変えない（二重の確保が失敗する）" do
      ticket.mark_used(first_time)

      expect(described_class.find(ticket.id).mark_used(second_time)).to be(false)

      expect(described_class.find(ticket.id).used_at).to eq(first_time)
    end

    it "同じインスタンスでの 2 回目も false（メモリ上の used_at ではなく、DB の行で判定する）" do
      stale = described_class.find(ticket.id)
      described_class.find(ticket.id).mark_used(first_time)

      expect(stale.used_at).to be_nil
      expect(stale.mark_used(second_time)).to be(false)
      expect(stale.used_at).to be_nil
    end

    it "使用済みで作成されたチケットは、確保できない" do
      used = create(:relay_ticket, :used)

      expect(used.mark_used(second_time)).to be(false)
    end

    it "used_at が NULL の行だけを更新する、条件付きの UPDATE 文 1 つで行う" do
      statements = capture_sql { ticket.mark_used(first_time) }
      updates = statements.grep(/\AUPDATE "relay_tickets"/)

      expect(updates.size).to eq(1)
      expect(updates.first).to include('"used_at" IS NULL')
    end

    it "時刻（nil）を省いた呼び出しは ArgumentError（実時計で補わない）" do
      expect { ticket.mark_used(nil) }.to raise_error(ArgumentError)
      expect(described_class.find(ticket.id).used_at).to be_nil
    end
  end

  describe ".unused" do
    it "使用済みの印が無いチケットだけを返す" do
      unused = create(:relay_ticket)
      create(:relay_ticket, :used)

      expect(described_class.unused).to eq([ unused ])
    end
  end

  describe "関連" do
    it "アカウントと配信に属する" do
      ticket = create(:relay_ticket)

      expect(ticket.user).to eq(ticket.broadcast.user)
      expect(ticket.broadcast.relay_tickets).to eq([ ticket ])
    end
  end
end
