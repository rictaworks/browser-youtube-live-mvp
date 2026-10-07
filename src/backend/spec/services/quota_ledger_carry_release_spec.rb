require "rails_helper"
require "support/model_support"
require "services/support/ledger_support"

# 割り当て台帳の移し替えと解放（requirements.md 8.4）。
#   carry_over!   割り当て日をまたいだ配信の予約の残額を、またいだ後の最初の支出の時点で、新しい割り当て日へ移す。
#                 旧い日の予約中から差し引き、新しい日へ加算する（予約中が負にならない）。spend! が、必要なときに内部で行う
#   release!      予約の残額は、清算状態が終端（不要・清算済み・清算不能）に達した時点で解放する。配信レコードの終了時点では解放しない
#                 （呼び出し側の責務）。冪等。二重に解放しない
# 割り当て日は、太平洋時間のタイムゾーン定義による日付（固定の時差で計算しない。夏時間をまたぐ）。
RSpec.describe QuotaLedger do
  include LedgerSupport

  let(:day) { quota_day(0) }
  let(:next_day) { day + 1 }
  let(:now) { noon_of(day) }

  def spend(broadcast, units:, at:, bucket: :prep, result: "ok", method: "liveBroadcasts.insert")
    described_class.spend!(broadcast, method: method, units: units, bucket: bucket, result: result, now: at)
  end

  describe ".carry_over!（割り当て日をまたいだ予約の移し替え）", :ledger do
    let!(:broadcast) { create_reserved_broadcast(quota_date: day) }

    it "予約の残額（550）を、旧い日の予約中から引き、新しい日の予約中へ足す。配信の割り当て日が、新しい日になる。true を返す" do
      expect(described_class.carry_over!(broadcast, quota_date: next_day)).to be(true)

      expect(QuotaDay.find(day)).to have_attributes(reserved_units: 0, used_units: 0)
      expect(QuotaDay.find(next_day)).to have_attributes(reserved_units: 550, used_units: 0, common_used_units: 0)
      expect(Broadcast.find(broadcast.id)).to have_attributes(quota_date: next_day, prep_reserved_units: 340, settle_reserved_units: 210)
    end

    it "メモリ上の配信にも、新しい割り当て日が反映される（変更済みの印は付かない）" do
      described_class.carry_over!(broadcast, quota_date: next_day)

      expect(broadcast.quota_date).to eq(next_day)
      expect(broadcast).not_to be_changed
    end

    it "一部を支出したあとは、残額（500）だけを移す。使用済みは、元の日に残る（移さない）" do
      spend(broadcast, units: 50, at: now)

      described_class.carry_over!(broadcast, quota_date: next_day)

      expect(QuotaDay.find(day)).to have_attributes(used_units: 50, reserved_units: 0)
      expect(QuotaDay.find(next_day)).to have_attributes(used_units: 0, reserved_units: 500)
      expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 290, settle_reserved_units: 210)
    end

    it "共通枠の使用済みは、移さない" do
      described_class.spend_common!(method: "channels.list", units: 30, quota_date: day, now: now)

      described_class.carry_over!(broadcast, quota_date: next_day)

      expect(QuotaDay.find(day).common_used_units).to eq(30)
      expect(QuotaDay.find(next_day).common_used_units).to eq(0)
    end

    it "2 日以上またいでも、新しい日へ直接移す（間の日は、行を作らない）" do
      described_class.carry_over!(broadcast, quota_date: day + 3)

      expect(QuotaDay.find(day + 3).reserved_units).to eq(550)
      expect(QuotaDay.find(day).reserved_units).to eq(0)
      expect(QuotaDay.where(quota_date: [ day + 1, day + 2 ]).count).to eq(0)
    end

    it "新しい日の行が既にあれば、その値に加える（使用済み・共通枠・超過の印を変えない）" do
      seed_day(next_day, used: 700, reserved: 100, common: 40, exhausted: true)

      described_class.carry_over!(broadcast, quota_date: next_day)

      expect(QuotaDay.find(next_day)).to have_attributes(used_units: 700, reserved_units: 650, common_used_units: 40, exhausted: true)
    end

    it "新しい日の空きは、検査しない（進行中の配信の終了・清算に必要な額を、取り上げない）。配信に使える上限を超えても移す" do
      seed_day(next_day, used: 8_900)

      expect(described_class.carry_over!(broadcast, quota_date: next_day)).to be(true)

      expect(QuotaDay.find(next_day)).to have_attributes(used_units: 8_900, reserved_units: 550)
    end

    it "新しい日が、割り当て超過の印のある日でも、移す（進行中の配信の予約は、取り上げない）" do
      seed_day(next_day, exhausted: true)

      expect(described_class.carry_over!(broadcast, quota_date: next_day)).to be(true)
      expect(QuotaDay.find(next_day)).to have_attributes(reserved_units: 550, exhausted: true)
    end

    it "別の配信の予約に、触れない" do
      other = create_reserved_broadcast(quota_date: day)

      described_class.carry_over!(broadcast, quota_date: next_day)

      expect(Broadcast.find(other.id)).to have_attributes(quota_date: day, prep_reserved_units: 340, settle_reserved_units: 210)
      expect(QuotaDay.find(day).reserved_units).to eq(550)
    end

    describe "何もしない（false。冪等）" do
      it "すでに、その割り当て日の予約（二重の移し替え）" do
        described_class.carry_over!(broadcast, quota_date: next_day)

        expect(described_class.carry_over!(broadcast, quota_date: next_day)).to be(false)
        expect(described_class.carry_over!(Broadcast.find(broadcast.id), quota_date: next_day)).to be(false)

        expect(QuotaDay.find(next_day).reserved_units).to eq(550)
        expect(QuotaDay.find(day).reserved_units).to eq(0)
      end

      it "予約の割り当て日と同じ日" do
        expect(described_class.carry_over!(broadcast, quota_date: day)).to be(false)

        expect(QuotaDay.find(day).reserved_units).to eq(550)
        expect(QuotaDay.find_by(quota_date: next_day)).to be_nil
      end

      it "残額が無い予約（解放済み）: 移すものが無い。割り当て日も変えず、新しい日の行も作らない" do
        described_class.release!(broadcast)

        expect(described_class.carry_over!(broadcast, quota_date: next_day)).to be(false)

        expect(Broadcast.find(broadcast.id).quota_date).to eq(day)
        expect(QuotaDay.find_by(quota_date: next_day)).to be_nil
      end

      it "予約していない配信" do
        bare = create_bare_broadcast(quota_date: day)

        expect(described_class.carry_over!(bare, quota_date: next_day)).to be(false)

        expect(Broadcast.find(bare.id).quota_date).to eq(day)
      end
    end

    describe "不正な引数は、ArgumentError。何も変えない" do
      it "予約の割り当て日より前の日（後戻りさせない）" do
        expect { described_class.carry_over!(broadcast, quota_date: day - 1) }.to raise_error(ArgumentError, /earlier/)

        expect(QuotaDay.find(day).reserved_units).to eq(550)
        expect(Broadcast.find(broadcast.id).quota_date).to eq(day)
      end

      it "割り当て日が Date でない・配信が、保存されていない・Broadcast でない" do
        [ nil, "2026-10-08", Time.utc(2026, 10, 8) ].each do |bad|
          expect { described_class.carry_over!(broadcast, quota_date: bad) }.to raise_error(ArgumentError)
        end
        expect { described_class.carry_over!(build(:broadcast), quota_date: next_day) }.to raise_error(ArgumentError)
        expect { described_class.carry_over!(nil, quota_date: next_day) }.to raise_error(ArgumentError)
        expect(QuotaDay.find_by(quota_date: next_day)).to be_nil
      end
    end

    it "移し替えを、情報のログへ出す（配信の識別子・旧い日・新しい日・額）。タイトルは出さない" do
      Broadcast.find(broadcast.id).update_columns(pending_title: "dummy-secret-title")
      logged = []
      allow(Rails.logger).to receive(:info) { |message| logged << message.to_s }

      described_class.carry_over!(broadcast, quota_date: next_day)

      expect(logged.size).to eq(1)
      expect(logged.first).to include("broadcast_id=#{broadcast.id}", "from=#{day}", "to=#{next_day}", "units=550")
      expect(logged.first).not_to include("dummy-secret-title")
    end

    describe "原子性" do
      it "外側のトランザクションに参加する（SAVEPOINT を作らない）" do
        statements = nil
        ActiveRecord::Base.transaction do
          User.exists?(broadcast.user_id) # トランザクションは、最初の SQL で実体になる（遅延）。記録の前に、外側を実体にしておく
          statements = capture_every_sql { described_class.carry_over!(broadcast, quota_date: next_day) }
        end

        expect(statements.grep(/SAVEPOINT/)).to be_empty
      end

      it "外側のトランザクションを巻き戻すと、両方の日の台帳も、配信の割り当て日も、取り消される" do
        ActiveRecord::Base.transaction(requires_new: true) do
          described_class.carry_over!(broadcast, quota_date: next_day)
          raise ActiveRecord::Rollback
        end

        expect(QuotaDay.find(day).reserved_units).to eq(550)
        expect(QuotaDay.find_by(quota_date: next_day)).to be_nil
        expect(Broadcast.find(broadcast.id).quota_date).to eq(day)
      end

      it "配信の行 → 旧い日 → 新しい日の順に、FOR UPDATE で確保する（昇順。デッドロックを避ける）" do
        statements = capture_sql { described_class.carry_over!(broadcast, quota_date: next_day) }
        locks = statements.grep(/ FOR UPDATE/).map { |sql| sql[/FROM "(\w+)"/, 1] }

        expect(locks).to eq(%w[ broadcasts quota_days quota_days ])
      end
    end
  end

  describe ".spend!（割り当て日をまたいだ配信の記帳）", :ledger do
    let!(:broadcast) { create_reserved_broadcast(quota_date: day) }

    it "予約の割り当て日の中なら、移し替えない" do
      spend(broadcast, units: 50, at: now)

      expect(QuotaDay.find(day)).to have_attributes(used_units: 50, reserved_units: 500)
      expect(QuotaDay.find_by(quota_date: next_day)).to be_nil
    end

    it "割り当て日をまたいだ後の最初の支出で、予約の残額を、新しい日へ移してから、新しい日へ記帳する" do
      expect(spend(broadcast, units: 50, at: noon_of(next_day))).to be(true)

      expect(QuotaDay.find(day)).to have_attributes(used_units: 0, reserved_units: 0)
      expect(QuotaDay.find(next_day)).to have_attributes(used_units: 50, reserved_units: 500)
      expect(Broadcast.find(broadcast.id)).to have_attributes(quota_date: next_day, prep_reserved_units: 290, settle_reserved_units: 210)
      expect(QuotaEntry.find_by!(broadcast_id: broadcast.id)).to have_attributes(quota_date: next_day, units: 50)
    end

    it "移し替えのあとの支出は、再び移さない（新しい日に、とどまる）" do
      spend(broadcast, units: 50, at: noon_of(next_day))
      spend(broadcast, units: 51, at: noon_of(next_day) + 3600, bucket: :settle)

      expect(QuotaDay.find(next_day)).to have_attributes(used_units: 101, reserved_units: 449)
      expect(QuotaDay.find(day).reserved_units).to eq(0)
    end

    it "移し替える前の支出の記帳は、元の日に残る（使用済みを移さない）" do
      spend(broadcast, units: 50, at: now)

      spend(broadcast, units: 51, at: noon_of(next_day))

      expect(QuotaDay.find(day)).to have_attributes(used_units: 50, reserved_units: 0)
      expect(QuotaDay.find(next_day)).to have_attributes(used_units: 51, reserved_units: 449)
      expect(QuotaEntry.where(broadcast_id: broadcast.id).order(:units).pluck(:units, :quota_date)).to eq([ [ 50, day ], [ 51, next_day ] ])
    end

    it "2 日以上またいでも、最初の支出で、新しい日へ移す" do
      spend(broadcast, units: 50, at: noon_of(day + 2))

      expect(QuotaDay.find(day + 2)).to have_attributes(used_units: 50, reserved_units: 500)
      expect(QuotaDay.find(day).reserved_units).to eq(0)
    end

    it "新しい日の空きが無くても（上限を超えていても）、進行中の配信の支出は、記帳される" do
      seed_day(next_day, used: 9_000)

      expect(spend(broadcast, units: 50, at: noon_of(next_day))).to be(true)

      expect(QuotaDay.find(next_day)).to have_attributes(used_units: 9_050, reserved_units: 500)
    end

    it "終了・清算枠の支出も、またいだ後の最初の支出なら、移してから記帳する" do
      expect(spend(broadcast, units: 1, at: noon_of(next_day), bucket: :settle, method: "liveBroadcasts.list")).to be(true)

      expect(QuotaDay.find(next_day)).to have_attributes(used_units: 1, reserved_units: 549)
      expect(QuotaDay.find(day).reserved_units).to eq(0)
    end

    it "支出が断られても（枠の不足）、またいだ後の予約の残額は、新しい日へ移る（予約は、新しい日のものになる）" do
      spend(broadcast, units: 340, at: now)

      expect(spend(broadcast, units: 1, at: noon_of(next_day))).to be(false)

      expect(QuotaDay.find(day)).to have_attributes(used_units: 340, reserved_units: 0)
      expect(QuotaDay.find(next_day)).to have_attributes(used_units: 0, reserved_units: 210)
      expect(Broadcast.find(broadcast.id).quota_date).to eq(next_day)
      expect(QuotaEntry.where(broadcast_id: broadcast.id).count).to eq(1)
    end

    it "予約が空（解放済み）の配信の支出は、断られ、新しい日の行も作らない" do
      described_class.release!(broadcast)

      expect(spend(broadcast, units: 1, at: noon_of(next_day))).to be(false)

      expect(QuotaDay.find_by(quota_date: next_day)).to be_nil
      expect(Broadcast.find(broadcast.id).quota_date).to eq(day)
    end

    describe "割り当て日の境目（太平洋時間のタイムゾーン定義。UTC 0 時でも、固定の時差でもない）" do
      {
        "太平洋時間 10 月 7 日 23:59:59（UTC 10 月 8 日 06:59:59）: まだ 10 月 7 日" => [ Time.utc(2026, 10, 8, 6, 59, 59), false ],
        "UTC の 10 月 8 日 0 時（太平洋時間では 10 月 7 日の夕方）: まだ 10 月 7 日" => [ Time.utc(2026, 10, 8, 0, 0, 0), false ],
        "太平洋時間 10 月 8 日 00:00:00（UTC 10 月 8 日 07:00:00）: 10 月 8 日" => [ Time.utc(2026, 10, 8, 7, 0, 0), true ],
        "太平洋時間 10 月 8 日 00:00:01" => [ Time.utc(2026, 10, 8, 7, 0, 1), true ]
      }.each do |label, (time, crossed)|
        it "夏時間: #{label} → #{crossed ? '移し替える' : '移し替えない'}" do
          expect(spend(broadcast, units: 1, at: time)).to be(true)

          expect(Broadcast.find(broadcast.id).quota_date).to eq(crossed ? next_day : day)
        end
      end

      # 夏時間が終わる日（2026-11-01 02:00。太平洋夏時間 → 太平洋標準時）。標準時の間は、UTC-8
      {
        "標準時: 太平洋時間 11 月 1 日 23:30（UTC 11 月 2 日 07:30。UTC-7 の固定なら 11 月 2 日 00:30 になってしまう）: まだ 11 月 1 日" =>
          [ Time.utc(2026, 11, 2, 7, 30, 0), false ],
        "標準時: 太平洋時間 11 月 2 日 00:00（UTC 11 月 2 日 08:00）: 11 月 2 日" => [ Time.utc(2026, 11, 2, 8, 0, 0), true ]
      }.each do |label, (time, crossed)|
        it "夏時間の終了の日: #{label} → #{crossed ? '移し替える' : '移し替えない'}" do
          fall_day = Date.new(2026, 11, 1)
          reserved = create_reserved_broadcast(quota_date: fall_day)

          expect(spend(reserved, units: 1, at: time)).to be(true)

          expect(Broadcast.find(reserved.id).quota_date).to eq(crossed ? fall_day + 1 : fall_day)
        end
      end
    end

    describe "時計のずれ（now が、予約の割り当て日より前）" do
      it "後戻りさせず、予約の割り当て日に記帳する（移し替えない）" do
        moved = create_reserved_broadcast(quota_date: next_day)

        expect(spend(moved, units: 50, at: now)).to be(true)

        expect(QuotaDay.find(next_day)).to have_attributes(used_units: 50, reserved_units: 500)
        expect(Broadcast.find(moved.id).quota_date).to eq(next_day)
        expect(QuotaEntry.find_by!(broadcast_id: moved.id).quota_date).to eq(next_day)
      end
    end

    it "移し替えと記帳は、同じトランザクションで行う（巻き戻すと、移し替えも、記帳も、取り消される）" do
      ActiveRecord::Base.transaction(requires_new: true) do
        spend(broadcast, units: 50, at: noon_of(next_day))
        raise ActiveRecord::Rollback
      end

      expect(QuotaDay.find(day)).to have_attributes(used_units: 0, reserved_units: 550)
      expect(QuotaDay.find_by(quota_date: next_day)).to be_nil
      expect(Broadcast.find(broadcast.id).quota_date).to eq(day)
      expect(QuotaEntry.where(broadcast_id: broadcast.id).count).to eq(0)
    end
  end

  describe ".release!（予約の残額の解放）", :ledger do
    let!(:broadcast) { create_reserved_broadcast(quota_date: day) }

    it "予約の残額（550）を、台帳の予約中から引き、配信の枠を 0・0 にする。true を返す" do
      expect(described_class.release!(broadcast)).to be(true)

      expect(QuotaDay.find(day)).to have_attributes(reserved_units: 0, used_units: 0)
      expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 0, settle_reserved_units: 0)
    end

    it "メモリ上の配信にも、枠が 0・0 であることが反映される（変更済みの印は付かない）" do
      described_class.release!(broadcast)

      expect(broadcast).to have_attributes(prep_reserved_units: 0, settle_reserved_units: 0)
      expect(broadcast).not_to be_changed
    end

    it "一部を支出したあとは、残額だけを引く。使用済みは、変えない（解放しても、実費は返らない）" do
      spend(broadcast, units: 50, at: now)
      spend(broadcast, units: 51, at: now, bucket: :settle)

      described_class.release!(broadcast)

      expect(QuotaDay.find(day)).to have_attributes(used_units: 101, reserved_units: 0)
      expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 0, settle_reserved_units: 0)
    end

    it "冪等: 2 回目は false（二重に解放しない。予約中が負にならない）" do
      expect(described_class.release!(broadcast)).to be(true)
      expect(described_class.release!(broadcast)).to be(false)
      expect(described_class.release!(Broadcast.find(broadcast.id))).to be(false)

      expect(QuotaDay.find(day).reserved_units).to eq(0)
    end

    it "古いメモリ上の配信（枠が残っている）でも、DB の行で判定し、二重に解放しない" do
      stale = Broadcast.find(broadcast.id)
      described_class.release!(broadcast)

      expect(stale.prep_reserved_units).to eq(340)
      expect(described_class.release!(stale)).to be(false)
      expect(stale).to have_attributes(prep_reserved_units: 0, settle_reserved_units: 0)
      expect(QuotaDay.find(day).reserved_units).to eq(0)
    end

    it "予約していない配信は false（何も変えない）" do
      bare = create_bare_broadcast(quota_date: day)

      expect(described_class.release!(bare)).to be(false)
      expect(QuotaDay.find(day).reserved_units).to eq(550)
    end

    it "全部を使い切った配信（残額 0）は false" do
      spend(broadcast, units: 340, at: now)
      spend(broadcast, units: 210, at: now, bucket: :settle)

      expect(described_class.release!(broadcast)).to be(false)
      expect(QuotaDay.find(day)).to have_attributes(used_units: 550, reserved_units: 0)
    end

    it "割り当て日をまたいだ配信は、現在の（移した後の）割り当て日の予約中から引く" do
      spend(broadcast, units: 50, at: noon_of(next_day))

      described_class.release!(broadcast)

      expect(QuotaDay.find(next_day)).to have_attributes(used_units: 50, reserved_units: 0)
      expect(QuotaDay.find(day).reserved_units).to eq(0)
    end

    it "別の配信の予約に、触れない" do
      other = create_reserved_broadcast(quota_date: day)

      described_class.release!(broadcast)

      expect(Broadcast.find(other.id)).to have_attributes(prep_reserved_units: 340, settle_reserved_units: 210)
      expect(QuotaDay.find(day).reserved_units).to eq(550)
    end

    it "割り当て超過の印がある日にも、解放できる（進行中の配信の解放は、続けられる）" do
      described_class.mark_exhausted!(quota_date: day)

      expect(described_class.release!(broadcast)).to be(true)
      expect(QuotaDay.find(day)).to have_attributes(reserved_units: 0, exhausted: true)
    end

    it "解放のあとの支出は、断られる（予約が空）" do
      described_class.release!(broadcast)

      expect(spend(broadcast, units: 1, at: now)).to be(false)
    end

    it "配信の状態・清算状態を検査しない（呼ぶ時点は、呼び出し側の責務: 清算状態が終端に達したとき）" do
      ended_time = Time.utc(2026, 10, 7, 20, 0, 0)
      [ { settlement_state: "pending" }, { settlement_state: "settled" }, { settlement_state: "none" } ].each do |settlement|
        ended = create_reserved_broadcast(quota_date: day)
        Broadcast.where(id: ended.id).update_all(
          { state: "ended", end_reason: "user_stop", ended_at: ended_time, pending_title: nil }.merge(settlement)
        )

        expect(described_class.release!(Broadcast.find(ended.id))).to be(true)
      end
    end

    describe "不正な引数は ArgumentError" do
      it "配信が、保存されていない・Broadcast でない" do
        expect { described_class.release!(build(:broadcast)) }.to raise_error(ArgumentError)
        expect { described_class.release!(nil) }.to raise_error(ArgumentError)
        expect { described_class.release!(broadcast.id) }.to raise_error(ArgumentError)
        expect(QuotaDay.find(day).reserved_units).to eq(550)
      end
    end

    describe "原子性" do
      it "配信の行 → 台帳の行の順に、FOR UPDATE で確保する" do
        statements = capture_sql { described_class.release!(broadcast) }
        locks = statements.grep(/ FOR UPDATE/).map { |sql| sql[/FROM "(\w+)"/, 1] }

        expect(locks).to eq(%w[ broadcasts quota_days ])
      end

      it "外側のトランザクションに参加する（SAVEPOINT を作らない）" do
        statements = nil
        ActiveRecord::Base.transaction do
          User.exists?(broadcast.user_id) # トランザクションは、最初の SQL で実体になる（遅延）。記録の前に、外側を実体にしておく
          statements = capture_every_sql { described_class.release!(broadcast) }
        end

        expect(statements.grep(/SAVEPOINT/)).to be_empty
      end

      it "外側のトランザクションを巻き戻すと、解放も取り消される" do
        ActiveRecord::Base.transaction(requires_new: true) do
          described_class.release!(broadcast)
          raise ActiveRecord::Rollback
        end

        expect(QuotaDay.find(day).reserved_units).to eq(550)
        expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 340, settle_reserved_units: 210)
      end
    end
  end
end
