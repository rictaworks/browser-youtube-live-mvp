require "rails_helper"
require "support/model_support"
require "services/support/ledger_support"

# 割り当て台帳（requirements.md 8.4・14 章・15 章「割り当ての予約」・20.1 の quota_days）: 読み取り・予約・超過の印。
# 規則（配信に使える上限 = 1 日の割り当て - 共通枠 - 安全余裕。予約 550 = 準備・確認枠 340 + 終了・清算枠 210。
# 超過の日は予約しない）は、#5 の QuotaPolicy。このサービスは、台帳の行を FOR UPDATE で確保して、規則を適用し、永続化する。
# 例のグループに :ledger を付けたものは、各例の終わりに、台帳の不変条件（明細と配信の残額からの再計算）を、全体で検査する。
#   記帳（spend!・spend_common!）: quota_ledger_spend_spec.rb
#   移し替え・解放: quota_ledger_carry_release_spec.rb
#   同時の呼び出しと、途中で失敗したときの取り消し: quota_ledger_concurrency_spec.rb
RSpec.describe QuotaLedger do
  include LedgerSupport

  let(:day) { quota_day(0) }
  let(:default_total) { Settings.defaults.daily_quota_units }
  let(:reservation_units) { QuotaPolicy::RESERVATION_UNITS }

  def reserve(broadcast, quota_date: day, daily_total: default_total, units: reservation_units)
    described_class.reserve!(broadcast, quota_date: quota_date, units: units, daily_total: daily_total)
  end

  describe ".day（台帳の 1 日の読み取り）", :ledger do
    it "行が無い割り当て日は、すべて 0・超過の印なし。読み取りは、行を作らない" do
      value = described_class.day(day)

      expect(value).to be_a(QuotaPolicy::Day)
      expect(value).to have_attributes(quota_date: day, used_units: 0, reserved_units: 0, common_used_units: 0, exhausted: false)
      expect(QuotaDay.count).to eq(0)
    end

    it "保存された行の値を、QuotaPolicy::Day（不変の値）として返す" do
      seed_day(day, used: 120, reserved: 550, common: 30, exhausted: true)

      value = described_class.day(day)

      expect(value).to eq(QuotaPolicy::Day.new(quota_date: day, used_units: 120, reserved_units: 550, common_used_units: 30, exhausted: true))
      expect(value).to be_frozen
    end

    it "別の割り当て日の値を、返さない" do
      seed_day(day + 1, used: 500)

      expect(described_class.day(day).used_units).to eq(0)
    end

    # 受理（#12）は、台帳の 1 日を読み、開始受付判定（順 13: API 割り当て不足）で空きを見たあと、同じトランザクションで予約する。
    # 判定の入力（このメソッドの値）と、予約の成否が、食い違わないこと
    it "受付判定の入力として使える: QuotaPolicy.can_reserve? の答えと、reserve! の成否が、一致する" do
      [ [ 0, 0, true ], [ 8_450, 0, true ], [ 8_451, 0, false ], [ 0, 8_450, true ], [ 0, 8_451, false ], [ 4_000, 4_451, false ] ].each_with_index do |(used, reserved, expected), index|
        date = day + index
        seed_day(date, used: used, reserved: reserved)

        decision = QuotaPolicy.can_reserve?(described_class.day(date), units: QuotaPolicy::RESERVATION_UNITS, daily_total: default_total)
        reserved_now = reserve(create_bare_broadcast(quota_date: date), quota_date: date)

        expect([ decision, reserved_now ]).to eq([ expected, expected ])
      end
    end

    it "割り当て日が Date でなければ ArgumentError" do
      [ nil, "2026-10-07", Time.utc(2026, 10, 7), DateTime.new(2026, 10, 7) ].each do |bad|
        expect { described_class.day(bad) }.to raise_error(ArgumentError)
      end
    end
  end

  describe ".reserve!（受理時の予約）", :ledger do
    let(:broadcast) { create_bare_broadcast(quota_date: day) }

    it "予約できる: true。台帳の予約中が 550 になり、配信の枠は準備・確認枠 340・終了・清算枠 210、割り当て日が設定される" do
      expect(reserve(broadcast)).to be(true)

      expect(QuotaDay.find(day)).to have_attributes(reserved_units: 550, used_units: 0, common_used_units: 0, exhausted: false)
      expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 340, settle_reserved_units: 210, quota_date: day)
    end

    it "予約額と枠の内訳は、固定値（QuotaPolicy の定数。設定値ではない）" do
      reserve(broadcast)

      expect(Broadcast.find(broadcast.id).prep_reserved_units).to eq(QuotaPolicy::PREP_UNITS)
      expect(Broadcast.find(broadcast.id).settle_reserved_units).to eq(QuotaPolicy::SETTLE_UNITS)
      expect(QuotaPolicy::PREP_UNITS + QuotaPolicy::SETTLE_UNITS).to eq(QuotaPolicy::RESERVATION_UNITS)
    end

    it "メモリ上の配信にも反映される（変更済みの印は付かない）" do
      reserve(broadcast)

      expect(broadcast).to have_attributes(prep_reserved_units: 340, settle_reserved_units: 210, quota_date: day)
      expect(broadcast).not_to be_changed
    end

    it "units を省くと、固定の予約額（550）で予約する" do
      expect(described_class.reserve!(broadcast, quota_date: day, daily_total: default_total)).to be(true)

      expect(QuotaDay.find(day).reserved_units).to eq(550)
    end

    it "配信の割り当て日を、引数の割り当て日にする（作成時と違っていても）" do
      other = create_bare_broadcast(quota_date: day - 1)

      reserve(other, quota_date: day)

      expect(Broadcast.find(other.id).quota_date).to eq(day)
      expect(QuotaDay.find(day).reserved_units).to eq(550)
      expect(QuotaDay.find_by(quota_date: day - 1)).to be_nil
    end

    it "使用済み・共通枠には触れない（予約中だけが増える）" do
      seed_day(day, used: 100, common: 40)

      reserve(broadcast)

      expect(QuotaDay.find(day)).to have_attributes(used_units: 100, common_used_units: 40, reserved_units: 550)
    end

    it "別のアカウントの配信も、同じ割り当て日の台帳へ積み上がる" do
      reserve(broadcast)
      reserve(create_bare_broadcast(quota_date: day))
      reserve(create_bare_broadcast(quota_date: day))

      expect(QuotaDay.find(day).reserved_units).to eq(1_650)
    end

    it "別の割り当て日は、別の台帳（互いに影響しない）" do
      reserve(broadcast, quota_date: day)
      reserve(create_bare_broadcast(quota_date: day + 1), quota_date: day + 1)

      expect(QuotaDay.find(day).reserved_units).to eq(550)
      expect(QuotaDay.find(day + 1).reserved_units).to eq(550)
    end

    describe "配信に使える上限（使用済み + 予約中 + 新規の予約 <= 1 日の割り当て - 共通枠 500 - 安全余裕 500）" do
      {
        "空の台帳（既定 10,000 → 上限 9,000）" => [ 0, 0, 10_000, true ],
        "使用済み 8,450（+550 = 9,000 ちょうど）" => [ 8_450, 0, 10_000, true ],
        "使用済み 8,451（+550 = 9,001）" => [ 8_451, 0, 10_000, false ],
        "予約中 8,450（+550 = 9,000 ちょうど）" => [ 0, 8_450, 10_000, true ],
        "予約中 8,451（+550 = 9,001）" => [ 0, 8_451, 10_000, false ],
        "使用済み 4,000 + 予約中 4,450（合計 9,000）" => [ 4_000, 4_450, 10_000, true ],
        "使用済み 4,000 + 予約中 4,451（合計 9,001）" => [ 4_000, 4_451, 10_000, false ],
        "1 日の割り当て 1,549（上限 549）" => [ 0, 0, 1_549, false ],
        "1 日の割り当て 1,550（上限 550 ちょうど）" => [ 0, 0, 1_550, true ],
        "1 日の割り当て 1,000（上限 0）" => [ 0, 0, 1_000, false ],
        "1 日の割り当て 20,000（上限 19,000）で、使用済み 18,450" => [ 18_450, 0, 20_000, true ],
        "1 日の割り当て 20,000 で、使用済み 18,451" => [ 18_451, 0, 20_000, false ]
      }.each do |label, (used, reserved, total, expected)|
        it "#{label}: #{expected ? '予約できる' : '予約しない（false）'}" do
          seed_day(day, used: used, reserved: reserved)

          expect(reserve(broadcast, daily_total: total)).to be(expected)

          expected_reserved = expected ? reserved + 550 : reserved
          expect(QuotaDay.find(day).reserved_units).to eq(expected_reserved)
        end
      end

      it "既定では、16 本まで予約できて、17 本目は予約しない（9,000 ÷ 550）" do
        accepted = Array.new(17) { reserve(create_bare_broadcast(quota_date: day)) }

        expect(accepted).to eq([ true ] * 16 + [ false ])
        expect(QuotaDay.find(day).reserved_units).to eq(16 * 550)
      end

      it "1 日の割り当てが 8,000（上限 7,000）なら、12 本まで（12 × 550 = 6,600。13 本目は 7,150 で超える）" do
        accepted = Array.new(13) { reserve(create_bare_broadcast(quota_date: day), daily_total: 8_000) }

        expect(accepted).to eq([ true ] * 12 + [ false ])
      end

      it "1 日の割り当ては、呼び出しのたびに引数で与える（次の受付から、変えた値が適用される）" do
        12.times { reserve(create_bare_broadcast(quota_date: day), daily_total: 8_000) }
        refused = create_bare_broadcast(quota_date: day)

        expect(reserve(refused, daily_total: 8_000)).to be(false)
        expect(reserve(refused, daily_total: 10_000)).to be(true)
      end

      it "予約を解放すると（release!）、空きが戻り、また予約できる" do
        reserved = Array.new(16) { create_reserved_broadcast(quota_date: day) }
        refused = create_bare_broadcast(quota_date: day)
        expect(reserve(refused)).to be(false)

        described_class.release!(reserved.first)

        expect(reserve(refused)).to be(true)
        expect(QuotaDay.find(day).reserved_units).to eq(16 * 550)
      end
    end

    describe "予約しない（false）とき" do
      before { seed_day(day, used: 8_451) }

      it "台帳も配信も変えない。明細も作らない" do
        before_day = QuotaDay.find(day).attributes
        entries_before = QuotaEntry.count

        expect(reserve(broadcast)).to be(false)

        expect(QuotaDay.find(day).attributes).to eq(before_day)
        expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 0, settle_reserved_units: 0, quota_date: day)
        expect(broadcast).to have_attributes(prep_reserved_units: 0, settle_reserved_units: 0)
        expect(QuotaEntry.count).to eq(entries_before)
      end

      it "割り当て日の違う配信は、割り当て日も変えない" do
        other = create_bare_broadcast(quota_date: day - 3)

        expect(reserve(other, quota_date: day)).to be(false)

        expect(Broadcast.find(other.id).quota_date).to eq(day - 3)
      end

      it "拒否の理由（ledger_full）と、配信の識別子を、警告のログへ出す。タイトルは出さない" do
        broadcast.update_columns(pending_title: "dummy-secret-title")
        logged = []
        allow(Rails.logger).to receive(:warn) { |message| logged << message.to_s }

        reserve(broadcast)

        expect(logged.size).to eq(1)
        expect(logged.first).to include("reason=ledger_full", "broadcast_id=#{broadcast.id}", "quota_date=#{day}")
        expect(logged.first).not_to include("dummy-secret-title")
      end
    end

    describe "割り当て超過の印がある日（mark_exhausted!）" do
      it "空きがあっても予約しない（false）。台帳も配信も変えない" do
        seed_day(day, exhausted: true)

        expect(reserve(broadcast)).to be(false)

        expect(QuotaDay.find(day)).to have_attributes(reserved_units: 0, exhausted: true)
        expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 0, settle_reserved_units: 0)
      end

      it "理由 day_exhausted を、警告のログへ出す" do
        seed_day(day, exhausted: true)
        logged = []
        allow(Rails.logger).to receive(:warn) { |message| logged << message.to_s }

        reserve(broadcast)

        expect(logged.first).to include("reason=day_exhausted")
      end

      it "別の割り当て日には、影響しない" do
        seed_day(day, exhausted: true)
        tomorrow = create_bare_broadcast(quota_date: day + 1)

        expect(reserve(tomorrow, quota_date: day + 1)).to be(true)
      end
    end

    describe "配信が予約の前提を満たさないとき（呼び出し側の誤りは、例外にする。台帳を変えない）" do
      it "状態が reserved でない配信: QuotaLedger::NotReservable" do
        (Contract::BroadcastState::ALL - [ Contract::BroadcastState::RESERVED ]).each do |state|
          traits = state == Contract::BroadcastState::ENDED ? [ :ended ] : []
          other = create_bare_broadcast(quota_date: day, traits: traits, state: state)

          expect { reserve(other) }.to raise_error(QuotaLedger::NotReservable, /state=#{state}/)
        end
        expect(QuotaDay.count).to eq(0)
      end

      it "すでに予約を持つ配信（二重の予約）: QuotaLedger::NotReservable。台帳は 550 のまま" do
        reserved = create_reserved_broadcast(quota_date: day)

        expect { reserve(reserved) }.to raise_error(QuotaLedger::NotReservable, /already_holds/)

        expect(QuotaDay.find(day).reserved_units).to eq(550)
        expect(Broadcast.find(reserved.id)).to have_attributes(prep_reserved_units: 340, settle_reserved_units: 210)
      end

      # 台帳に載っていない予約の枠を持つ配信を、わざと作る（台帳の不変条件の検査の対象外にする）
      it "準備・確認枠・終了・清算枠のどちらかでも残っていれば、予約を持つ配信として拒否する", ledger: false do
        [ { prep_reserved_units: 1 }, { settle_reserved_units: 1 } ].each do |held|
          other = create_bare_broadcast(quota_date: day, **held)

          expect { reserve(other) }.to raise_error(QuotaLedger::NotReservable)
        end
      end

      it "例外のメッセージは、識別子と符号だけ（タイトルを含まない）" do
        other = create_bare_broadcast(quota_date: day, state: "awaiting_media", pending_title: "dummy-secret-title")

        expect { reserve(other) }.to raise_error(QuotaLedger::NotReservable) { |error|
          expect(error.message).to include(other.id)
          expect(error.message).not_to include("dummy-secret-title")
        }
      end
    end

    describe "不正な引数は、ArgumentError。何も変えない" do
      it "配信が、保存されていない・Broadcast でない" do
        expect { reserve(build(:broadcast)) }.to raise_error(ArgumentError)
        expect { reserve(nil) }.to raise_error(ArgumentError)
        expect { reserve(broadcast.id) }.to raise_error(ArgumentError)
        expect(QuotaDay.count).to eq(0)
      end

      it "予約額が、固定の予約額（550）でない（内訳は固定値。別の額で予約しない）" do
        [ 0, 1, 340, 549, 551, 1_100, "550", nil, 550.0 ].each do |bad|
          expect { reserve(broadcast, units: bad) }.to raise_error(ArgumentError)
        end
        expect(QuotaDay.count).to eq(0)
      end

      it "割り当て日が Date でない" do
        [ nil, "2026-10-07", Time.utc(2026, 10, 7), DateTime.new(2026, 10, 7) ].each do |bad|
          expect { reserve(broadcast, quota_date: bad) }.to raise_error(ArgumentError)
        end
        expect(QuotaDay.count).to eq(0)
      end

      it "1 日の割り当てが、0 以上の整数でない" do
        [ nil, -1, "10000", 10_000.0, true ].each do |bad|
          expect { reserve(broadcast, daily_total: bad) }.to raise_error(ArgumentError)
        end
        expect(QuotaDay.count).to eq(0)
      end
    end

    describe "原子性" do
      it "配信の行を、台帳の行より先に、FOR UPDATE で確保する（記帳・移し替え・解放と同じ順序）" do
        broadcast # 記録の前に作る
        statements = capture_sql { reserve(broadcast) }
        locks = statements.grep(/ FOR UPDATE/).map { |sql| sql[/FROM "(\w+)"/, 1] }

        expect(locks).to eq(%w[ broadcasts quota_days ])
      end

      it "台帳の行が無ければ、INSERT ... ON CONFLICT DO NOTHING で作る（同時の作成と競合しない）" do
        broadcast
        statements = capture_sql { reserve(broadcast) }
        inserts = statements.grep(/\AINSERT INTO "quota_days"/)

        expect(inserts.size).to eq(1)
        expect(inserts.first).to include("ON CONFLICT").and include("DO NOTHING")
      end

      it "外側のトランザクションに参加する（SAVEPOINT を作らない）" do
        broadcast
        statements = nil
        ActiveRecord::Base.transaction do
          User.exists?(broadcast.user_id) # トランザクションは、最初の SQL で実体になる（遅延）。記録の前に、外側を実体にしておく
          statements = capture_every_sql { reserve(broadcast) }
        end

        expect(statements.grep(/SAVEPOINT/)).to be_empty
      end

      it "外側のトランザクション（受理）を巻き戻すと、予約も取り消される（予約が残らない）" do
        broadcast
        ActiveRecord::Base.transaction(requires_new: true) do
          reserve(broadcast)
          raise ActiveRecord::Rollback
        end

        expect(QuotaDay.find_by(quota_date: day)).to be_nil
        expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 0, settle_reserved_units: 0)
      end
    end
  end

  describe ".mark_exhausted!（割り当て超過の印）", :ledger do
    it "行が無い日は、行を作って、印を付ける（ほかの値は 0）。true を返す" do
      expect(described_class.mark_exhausted!(quota_date: day)).to be(true)

      expect(QuotaDay.find(day)).to have_attributes(exhausted: true, used_units: 0, reserved_units: 0, common_used_units: 0)
    end

    it "行がある日は、印だけを付ける（使用済み・予約中・共通枠を変えない）" do
      seed_day(day, used: 100, reserved: 550, common: 30)

      described_class.mark_exhausted!(quota_date: day)

      expect(QuotaDay.find(day)).to have_attributes(exhausted: true, used_units: 100, reserved_units: 550, common_used_units: 30)
    end

    it "冪等: 何度呼んでも、同じ（行は 1 件）" do
      3.times { described_class.mark_exhausted!(quota_date: day) }

      expect(QuotaDay.where(quota_date: day).count).to eq(1)
      expect(QuotaDay.find(day).exhausted).to be(true)
    end

    it "指定した割り当て日だけに付く（別の日に影響しない）" do
      seed_day(day + 1)

      described_class.mark_exhausted!(quota_date: day)

      expect(QuotaDay.find(day + 1).exhausted).to be(false)
      expect(described_class.day(day + 1).exhausted).to be(false)
      expect(described_class.day(day).exhausted).to be(true)
    end

    it "印のある日は、新規の予約を受け付けない。日が変われば、また受け付ける" do
      described_class.mark_exhausted!(quota_date: day)

      expect(reserve(create_bare_broadcast(quota_date: day))).to be(false)
      expect(reserve(create_bare_broadcast(quota_date: day + 1), quota_date: day + 1)).to be(true)
    end

    it "1 つの upsert 文で行う（読んでから書く 2 段にしない）" do
      statements = capture_sql { described_class.mark_exhausted!(quota_date: day) }
      writes = statements.grep(/\A(INSERT|UPDATE) /)

      expect(writes.size).to eq(1)
      expect(writes.first).to match(/\AINSERT INTO "quota_days".*ON CONFLICT \("quota_date"\) DO UPDATE/m)
    end

    it "割り当て日が Date でなければ ArgumentError（行を作らない）" do
      [ nil, "2026-10-07", Time.utc(2026, 10, 7) ].each do |bad|
        expect { described_class.mark_exhausted!(quota_date: bad) }.to raise_error(ArgumentError)
      end
      expect(QuotaDay.count).to eq(0)
    end
  end
end
