require "spec_helper"
require "date"
require_relative "support/domain_loader"

# アカウントの現況（AccountSnapshot）。開始受付判定（StartAdmission）が参照する、必要な値だけを持つ不変の値。
# AR モデルを渡さない（Domain Core は、永続化の型を参照しない）。ユーザーの識別情報・タイトルを持たない。
#
# 利用枠・開始試行は、利用日（usage_date）の値。転送量は、暦月（month_key）の値。台帳（quota_day）は、割り当て日の値。
# 現況が、判定の時刻の利用日・暦月・割り当て日のものであるかは、StartAdmission が検査する（古い現況で判定しない）。
RSpec.describe "アカウントの現況（AccountSnapshot）" do
  def attributes(**overrides)
    {
      usage_date: Date.new(2026, 10, 7),
      month_key: "2026-10",
      broadcast_in_progress: false,
      connection_state: "connected",
      consumed_count: 0,
      extra_grants: 0,
      attempt_count: 0,
      concurrent_count: 0,
      transfer_sent_bytes: 0,
      quota_day: QuotaPolicy::Day.new(quota_date: Date.new(2026, 10, 6), used_units: 0, reserved_units: 0, common_used_units: 0)
    }.merge(overrides)
  end

  let(:snapshot_class) { AccountSnapshot }

  it "10 項目の、凍結された値オブジェクト。ユーザーの識別情報・タイトルを持たない" do
    snapshot = snapshot_class.new(**attributes)

    expect(snapshot_class.members).to eq(
      %i[usage_date month_key broadcast_in_progress connection_state consumed_count extra_grants attempt_count
         concurrent_count transfer_sent_bytes quota_day]
    )
    expect(snapshot).to be_frozen
    expect(snapshot_class.members.map(&:to_s)).not_to include("title", "user_id", "account_id", "google_sub", "email", "name")
  end

  it "同じ値の現況は等しい" do
    expect(snapshot_class.new(**attributes)).to eq(snapshot_class.new(**attributes))
    expect(snapshot_class.new(**attributes)).not_to eq(snapshot_class.new(**attributes(consumed_count: 1)))
  end

  describe "利用日・暦月" do
    it "usage_date は、時刻を持たない Date（Date 以外・DateTime・Time・文字列・nil は ArgumentError）" do
      [ nil, "2026-10-07", Time.utc(2026, 10, 7), DateTime.new(2026, 10, 7), 20_261_007 ].each do |invalid|
        expect { snapshot_class.new(**attributes(usage_date: invalid)) }.to raise_error(ArgumentError, /usage_date/)
      end
    end

    it "month_key は、YYYY-MM の形（月は 01〜12）の文字列" do
      [ "2026-01", "2026-10", "2026-12", "1999-09", "2100-02" ].each do |valid|
        expect(snapshot_class.new(**attributes(month_key: valid)).month_key).to eq(valid)
      end
    end

    it "month_key の不正な形は ArgumentError（月が範囲外・桁が違う・前後の空白・改行・型違い）" do
      [ "2026-00", "2026-13", "2026-1", "26-10", "2026-010", "2026/10", "2026-10 ", " 2026-10", "2026-10\n", "", "abc", :"2026-10", 202_610, nil ].each do |invalid|
        expect { snapshot_class.new(**attributes(month_key: invalid)) }.to raise_error(ArgumentError, /month_key/)
      end
    end
  end

  describe "配信・YouTube の接続" do
    it "broadcast_in_progress は、true・false だけ" do
      [ true, false ].each { |valid| expect(snapshot_class.new(**attributes(broadcast_in_progress: valid)).broadcast_in_progress).to be(valid) }
      [ nil, "true", "false", 1, 0, :true, [] ].each do |invalid|
        expect { snapshot_class.new(**attributes(broadcast_in_progress: invalid)) }.to raise_error(ArgumentError, /broadcast_in_progress/)
      end
    end

    it "connection_state は、契約の youtube_connection_state の符号（文字列）だけ" do
      Contract::YoutubeConnectionState::ALL.each do |valid|
        expect(snapshot_class.new(**attributes(connection_state: valid)).connection_state).to eq(valid)
      end
      [ nil, :connected, "Connected", "connected ", "unknown", "", "not-connected", 1 ].each do |invalid|
        expect { snapshot_class.new(**attributes(connection_state: invalid)) }.to raise_error(ArgumentError, /connection_state/)
      end
    end
  end

  describe "数量（0 以上の整数）" do
    %i[consumed_count extra_grants attempt_count concurrent_count transfer_sent_bytes].each do |field|
      it "#{field}: 0 と大きな整数は有効。負・Float・文字列・nil・真偽値は ArgumentError" do
        [ 0, 1, 10**12 ].each { |valid| expect(snapshot_class.new(**attributes(field => valid)).public_send(field)).to eq(valid) }
        [ -1, 1.5, 1.0, "1", nil, true, [] ].each do |invalid|
          expect { snapshot_class.new(**attributes(field => invalid)) }.to raise_error(ArgumentError, /#{field}/)
        end
      end
    end
  end

  describe "台帳（quota_day）" do
    it "QuotaPolicy::Day だけ（Hash・nil・Day に似たものは ArgumentError）" do
      [ nil, {}, { used_units: 0 }, "day", 1 ].each do |invalid|
        expect { snapshot_class.new(**attributes(quota_day: invalid)) }.to raise_error(ArgumentError, /quota_day/)
      end
    end
  end

  describe "with（検証を通る）" do
    it "変更した値も検証する。元の値は変わらない" do
      snapshot = snapshot_class.new(**attributes)

      expect(snapshot.with(consumed_count: 1).consumed_count).to eq(1)
      expect(snapshot.consumed_count).to eq(0)
      expect { snapshot.with(consumed_count: -1) }.to raise_error(ArgumentError, /consumed_count/)
      expect { snapshot.with(connection_state: "bogus") }.to raise_error(ArgumentError, /connection_state/)
    end

    it "すべてを指定しない new は失敗する（既定値で補わない）" do
      expect { snapshot_class.new(usage_date: Date.new(2026, 10, 7)) }.to raise_error(ArgumentError)
    end
  end
end
