require "spec_helper"
require "date"
require_relative "../support/domain_loader"
require_relative "support/lifecycle_helpers"

# 保持期間（requirements.md 20.3）。RetentionPolicy。いつ消去・削除・失効させるかを、時刻から算出する純粋な関数。
#   YouTube の配信識別子  配信の終了から 30 日
#   健全性の標本・配信の出来事  30 日
#   接続チケット          失効から 1 日
#   セッション            最終利用から 30 日
#   ストリーム識別子      最後の確認から 30 日
#   再登録の保留          削除時点の利用日の終わりまで（利用日は、引数で受け取る。#5 の UsageCalendar を参照しない）
RSpec.describe "保持期間（RetentionPolicy）" do
  include LifecycleSpecHelpers

  t0 = LifecycleSpecHelpers::T0
  day = 86_400

  # 対象 => [保持の日数, 起点の呼び名]（20.3 の表）
  periods = {
    youtube_broadcast_id: [ 30, "配信の終了" ],
    health_samples: [ 30, "標本の時刻" ],
    broadcast_events: [ 30, "出来事の時刻" ],
    relay_tickets: [ 1, "接続チケットの失効" ],
    sessions: [ 30, "セッションの最終利用" ],
    stream_id: [ 30, "ストリームの最後の確認" ]
  }

  describe "対象と期間（20.3 の表）" do
    it "対象は 6 つ" do
      expect(RetentionPolicy::SUBJECTS).to eq(periods.keys)
      expect(RetentionPolicy::SUBJECTS).to be_frozen
    end

    periods.each do |subject, (days, origin)|
      it "#{subject}: #{origin}から #{days} 日（#{days * day} 秒）" do
        expect(RetentionPolicy.period_seconds(subject)).to eq(days * day)
      end
    end

    it "期間は、契約（limits.json の retention）の日数から取る" do
      retention = Contract::Limits::RETENTION

      expect(RetentionPolicy.period_seconds(:youtube_broadcast_id)).to eq(retention.fetch("youtube_broadcast_id_days_after_end") * day)
      expect(RetentionPolicy.period_seconds(:health_samples)).to eq(retention.fetch("health_samples_days") * day)
      expect(RetentionPolicy.period_seconds(:broadcast_events)).to eq(retention.fetch("broadcast_events_days") * day)
      expect(RetentionPolicy.period_seconds(:relay_tickets)).to eq(retention.fetch("relay_ticket_days_after_expiry") * day)
      expect(RetentionPolicy.period_seconds(:sessions)).to eq(retention.fetch("session_days_after_last_use") * day)
      expect(RetentionPolicy.period_seconds(:stream_id)).to eq(retention.fetch("stream_id_days_after_last_verified") * day)
    end
  end

  describe ".expires_at / .expired?（起点の時刻から算出する）" do
    periods.each do |subject, (days, origin)|
      describe "#{subject}（#{origin}から #{days} 日）" do
        it "期限は、起点の #{days} 日後" do
          expect(RetentionPolicy.expires_at(subject: subject, reference_at: t0)).to eq(t0 + days * day)
        end

        it "1 秒前: 失効していない" do
          expect(RetentionPolicy.expired?(subject: subject, reference_at: t0, now: t0 + days * day - 1)).to be(false)
        end

        it "ちょうど: 失効する（期限に達した）" do
          expect(RetentionPolicy.expired?(subject: subject, reference_at: t0, now: t0 + days * day)).to be(true)
        end

        it "1 秒後: 失効している" do
          expect(RetentionPolicy.expired?(subject: subject, reference_at: t0, now: t0 + days * day + 1)).to be(true)
        end
      end
    end

    it "30 日は、暦の月ではなく、30 × 24 時間（2026-10-07 12:00 UTC の 30 日後は、2026-11-06 12:00 UTC）" do
      expect(RetentionPolicy.expires_at(subject: :sessions, reference_at: Time.utc(2026, 10, 7, 12, 0, 0))).to eq(Time.utc(2026, 11, 6, 12, 0, 0))
    end

    it "接続チケットは、失効から 1 日（24 時間）で削除する" do
      expect(RetentionPolicy.expires_at(subject: :relay_tickets, reference_at: t0)).to eq(t0 + day)
    end
  end

  describe ".cutoff / .cutoffs（now から、削除の基準の時刻を算出する）" do
    periods.each do |subject, (days, _origin)|
      it "#{subject}: now の #{days} 日前（起点がこの時刻以前のものが、失効している）" do
        now = t0 + 100 * day

        expect(RetentionPolicy.cutoff(subject: subject, now: now)).to eq(now - days * day)
      end

      it "#{subject}: 基準の時刻ちょうどの起点は失効しており、1 秒後の起点は失効していない（expired? と一致）" do
        now = t0 + 100 * day
        cutoff = RetentionPolicy.cutoff(subject: subject, now: now)

        expect(RetentionPolicy.expired?(subject: subject, reference_at: cutoff, now: now)).to be(true)
        expect(RetentionPolicy.expired?(subject: subject, reference_at: cutoff + 1, now: now)).to be(false)
      end
    end

    it "cutoffs は、全対象の基準の時刻を、一度に返す" do
      now = t0 + 100 * day
      cutoffs = RetentionPolicy.cutoffs(now: now)

      expect(cutoffs.keys).to eq(periods.keys)
      expect(cutoffs).to eq(periods.to_h { |subject, (days, _)| [ subject, now - days * day ] })
      expect(cutoffs).to be_frozen
    end
  end

  describe ".registration_hold_expired?（再登録の保留。削除時点の利用日の終わりまで）" do
    # 利用日は、引数で受け取る（#5 の UsageCalendar を参照しない。呼び出し側が、時刻から算出して渡す）
    {
      "同じ利用日（まだ、その利用日の終わりまで）" => [ Date.new(2026, 10, 7), Date.new(2026, 10, 7), false ],
      "次の利用日（利用日の終わりを過ぎた）" => [ Date.new(2026, 10, 7), Date.new(2026, 10, 8), true ],
      "数日後" => [ Date.new(2026, 10, 7), Date.new(2026, 10, 20), true ],
      "削除時点より前の利用日（あり得ない。保留は続く）" => [ Date.new(2026, 10, 7), Date.new(2026, 10, 6), false ],
      "月をまたぐ（10 月 31 日の保留は、11 月 1 日に失効）" => [ Date.new(2026, 10, 31), Date.new(2026, 11, 1), true ],
      "年をまたぐ" => [ Date.new(2026, 12, 31), Date.new(2027, 1, 1), true ]
    }.each do |label, (hold, current, expected)|
      it "#{label}: #{expected ? "失効" : "保留中"}" do
        expect(RetentionPolicy.registration_hold_expired?(hold_usage_date: hold, usage_date: current)).to eq(expected)
      end
    end

    [ "2026-10-07", Time.utc(2026, 10, 7), nil ].each do |value|
      it "利用日が Date でなければ（#{value.class}）ArgumentError" do
        expect { RetentionPolicy.registration_hold_expired?(hold_usage_date: value, usage_date: Date.new(2026, 10, 7)) }
          .to raise_error(ArgumentError, "hold_usage_date must be a Date, got #{value.class}")
        expect { RetentionPolicy.registration_hold_expired?(hold_usage_date: Date.new(2026, 10, 7), usage_date: value) }
          .to raise_error(ArgumentError, "usage_date must be a Date, got #{value.class}")
      end
    end

    it "時刻を持つ DateTime は拒否する（利用日は、時刻を持たない日付）" do
      expect { RetentionPolicy.registration_hold_expired?(hold_usage_date: DateTime.new(2026, 10, 7), usage_date: Date.new(2026, 10, 8)) }
        .to raise_error(ArgumentError, "hold_usage_date must be a Date, got DateTime")
    end
  end

  describe ".broadcast_id_erasure（YouTube の配信識別子の消去。20.3・10.5）" do
    # 終了は T0+200
    ended_at = t0 + 200
    due = ended_at + 30 * day

    def erase(broadcast, at:)
      RetentionPolicy.broadcast_id_erasure(broadcast: broadcast, now: at)
    end

    it "終了から 30 日の前: 消去しない" do
      expect(erase(ended_snapshot(settlement_state: "settled"), at: due - 1)).to eq([])
    end

    {
      "settled" => "清算済み: 識別子だけを消去する（ストリームは取り替えない）",
      "none" => "不要: 識別子だけを消去する"
    }.each do |settlement_state, label|
      it "終了から 30 日（ちょうど）・#{settlement_state}（#{label}）" do
        expect(erase(ended_snapshot(settlement_state: settlement_state), at: due)).to eq([ Directive.of(:erase_youtube_broadcast_id) ])
      end
    end

    {
      "pending" => "未清算のまま消去する",
      "abandoned" => "清算不能のまま消去する"
    }.each do |settlement_state, label|
      it "終了から 30 日（ちょうど）・#{settlement_state}（#{label}）: 配信用ストリームの識別子も破棄する（10.5）" do
        expect(erase(ended_snapshot(settlement_state: settlement_state), at: due)).to eq(
          [ Directive.of(:erase_youtube_broadcast_id), Directive.of(:discard_stream_id) ]
        )
      end
    end

    it "未清算・清算不能のまま消去するときの、ストリームの破棄は、取り替えの規則（StreamReplacementPolicy）に従う" do
      allow(StreamReplacementPolicy).to receive(:discard?).and_return(false)

      expect(erase(ended_snapshot(settlement_state: "pending"), at: due)).to eq([ Directive.of(:erase_youtube_broadcast_id) ])
      expect(StreamReplacementPolicy).to have_received(:discard?).with(trigger: StreamReplacementPolicy::UNSETTLED_IDENTIFIER_ERASED)
    end

    it "清算済みの消去は、取り替えのトリガーにしない（StreamReplacementPolicy を呼ばない）" do
      allow(StreamReplacementPolicy).to receive(:discard?).and_call_original

      erase(ended_snapshot(settlement_state: "settled"), at: due)

      expect(StreamReplacementPolicy).not_to have_received(:discard?)
    end

    it "識別子を消去済みなら、何もしない" do
      expect(erase(ended_snapshot(settlement_state: "pending", youtube_broadcast_id: nil), at: due + 1000)).to eq([])
    end

    it "終了していない配信は、対象外（起点の終了の時刻が無い）" do
      expect(erase(snapshot("live"), at: due + 1000)).to eq([])
    end

    it "ストリーム識別子の期限（最後の確認から 30 日）を過ぎたら、破棄のトリガーになる（20.3）" do
      verified_at = t0

      expect(RetentionPolicy.expired?(subject: :stream_id, reference_at: verified_at, now: verified_at + 30 * day)).to be(true)
      expect(StreamReplacementPolicy.discard?(trigger: StreamReplacementPolicy::STREAM_ID_EXPIRED)).to be(true)
    end
  end

  describe "検査" do
    it "対象が表に無ければ ArgumentError（黙って期間を与えない）" do
      expect { RetentionPolicy.period_seconds(:unknown) }.to raise_error(ArgumentError, /subject must be one of/)
      expect { RetentionPolicy.expires_at(subject: "sessions", reference_at: t0) }.to raise_error(ArgumentError, /subject must be one of/)
      expect { RetentionPolicy.cutoff(subject: nil, now: t0) }.to raise_error(ArgumentError, /subject must be one of/)
    end

    it "起点・now が Time でなければ ArgumentError" do
      expect { RetentionPolicy.expires_at(subject: :sessions, reference_at: "2026-10-07") }.to raise_error(ArgumentError, "reference_at must be a Time, got String")
      expect { RetentionPolicy.expired?(subject: :sessions, reference_at: t0, now: nil) }.to raise_error(ArgumentError, "now must be a Time, got NilClass")
      expect { RetentionPolicy.cutoff(subject: :sessions, now: 1) }.to raise_error(ArgumentError, "now must be a Time, got Integer")
      expect { RetentionPolicy.cutoffs(now: "x") }.to raise_error(ArgumentError, "now must be a Time, got String")
    end

    it "broadcast_id_erasure の broadcast・now の型を検査する" do
      expect { RetentionPolicy.broadcast_id_erasure(broadcast: {}, now: t0) }.to raise_error(ArgumentError, "broadcast must be a BroadcastSnapshot, got Hash")
      expect { RetentionPolicy.broadcast_id_erasure(broadcast: ended_snapshot, now: "x") }.to raise_error(ArgumentError, "now must be a Time, got String")
    end
  end

  describe "純粋性・不変" do
    it "同じ入力に、同じ出力を返す。インスタンスを作らない" do
      expect(RetentionPolicy.expires_at(subject: :sessions, reference_at: t0)).to eq(RetentionPolicy.expires_at(subject: :sessions, reference_at: t0))
      expect { RetentionPolicy.new }.to raise_error(NoMethodError)
    end

    it "消去の指示は、凍結された配列" do
      expect(RetentionPolicy.broadcast_id_erasure(broadcast: ended_snapshot(settlement_state: "pending"), now: t0 + 200 + 30 * day)).to be_frozen
    end
  end
end
