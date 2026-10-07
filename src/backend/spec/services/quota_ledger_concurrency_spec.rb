require "rails_helper"
require "support/model_support"
require "services/support/ledger_support"

# 割り当て台帳の、同時の操作（requirements.md 14 章・27 章「整合性」「同時性」）。
# 複数の接続（スレッド）が、同時に同じ台帳・同じ配信へ挑む。上限を超えて予約しない・二重に計上しない・予約中が負にならない、を、
# アプリケーションの変数での判定ではなく、DB のロック（SELECT ... FOR UPDATE）と、行の確保の順序で保証する。
#
# 別の接続からは、未コミットの行が見えない。このグループは、トランザクションで包まず、実際にコミットする。
# 例が作った行（アカウント・配信・台帳・明細）は、各例の後で、SQL で整理する（共有のテスト用 DB に残さない）。
# 接続のプールの大きさ（既定 5）を超えるスレッドを、一度に立てると止まるため、同時の幅は、プールの大きさに合わせる
# （それを超える回数は、同時の波を重ねて行う。LedgerSupport#run_in_waves）。
RSpec.describe "割り当て台帳の同時の操作" do
  include LedgerSupport

  self.use_transactional_tests = false

  # 他の例と日付が重ならないよう、未来の日付を使う（共有の DB に、行が残っていても、影響しない）
  let(:day) { Date.new(2031, 3, 10) }
  let(:next_day) { day + 1 }

  before { clean_committed_rows!(quota_dates: committed_quota_dates) }
  after { clean_committed_rows!(quota_dates: committed_quota_dates) }

  def committed_quota_dates
    (0..4).map { |offset| day + offset }
  end

  # 例の中のスレッドが使う、DB から読み直した配信（スレッドごとに、別のインスタンス。AR のインスタンスは、スレッド間で共有しない）
  def fresh(broadcast)
    Broadcast.find(broadcast.id)
  end

  def successes(results)
    results.map(&:last).count(true)
  end

  def spend(broadcast, units:, at: noon_of(day), bucket: :prep, method: "liveBroadcasts.insert", result: "ok")
    QuotaLedger.spend!(fresh(broadcast), method: method, units: units, bucket: bucket, result: result, now: at)
  end

  describe "予約（reserve!）" do
    it "残りが 1 本分のとき、同時に reserve! を行うと、1 本だけ成功する（予約の判定と計上が、行ロックで直列になる）" do
      seed_day(day, used: 8_450) # 配信に使える上限 9,000 に対し、あと 1 本（550）だけ空いている
      broadcasts = Array.new(concurrent_width) { create_bare_broadcast(quota_date: day) }

      results = run_threads(broadcasts.size) do |index|
        QuotaLedger.reserve!(fresh(broadcasts[index]), quota_date: day, daily_total: 10_000)
      end

      expect(results.map(&:first)).to all(eq(:ok))
      expect(successes(results)).to eq(1)
      expect(QuotaDay.find(day)).to have_attributes(used_units: 8_450, reserved_units: 550)
      expect(Broadcast.where(id: broadcasts.map(&:id)).where("prep_reserved_units > 0").count).to eq(1)
      expect_ledger_consistent(day)
    end

    it "同時の要求が、どれだけ重なっても、成功は 16 本を超えない（9,000 ÷ 550）。予約中が、配信に使える上限を超えない" do
      broadcasts = Array.new(24) { create_bare_broadcast(quota_date: day) }

      results = run_in_waves(broadcasts.size) do |index|
        QuotaLedger.reserve!(fresh(broadcasts[index]), quota_date: day, daily_total: 10_000)
      end

      expect(results.map(&:first)).to all(eq(:ok))
      expect(successes(results)).to eq(16)
      expect(QuotaDay.find(day).reserved_units).to eq(16 * 550)
      expect(QuotaDay.find(day).reserved_units).to be <= 9_000
      expect(Broadcast.where(id: broadcasts.map(&:id)).where("prep_reserved_units > 0").count).to eq(16)
      expect_ledger_consistent(day)
    end

    it "別々の割り当て日への同時の予約は、互いに妨げない（日ごとに、上限まで）" do
      half = concurrent_width / 2 # 同時に立てるスレッドは、2 つの日の合計で、同時の幅に収める
      first_day = Array.new(half) { create_bare_broadcast(quota_date: day) }
      second_day = Array.new(half) { create_bare_broadcast(quota_date: next_day) }

      results = run_threads(first_day.size + second_day.size) do |index|
        target = index < first_day.size ? first_day[index] : second_day[index - first_day.size]
        QuotaLedger.reserve!(fresh(target), quota_date: target.quota_date, daily_total: 10_000)
      end

      expect(results.map(&:last)).to all(be(true))
      expect(QuotaDay.find(day).reserved_units).to eq(first_day.size * 550)
      expect(QuotaDay.find(next_day).reserved_units).to eq(second_day.size * 550)
      expect_ledger_consistent(day, next_day)
    end

    it "割り当て超過の印の付与と、予約が同時に行われても、行は壊れない（印のあとの予約は、断られる）" do
      broadcasts = Array.new(concurrent_width) { create_bare_broadcast(quota_date: day) }

      results = run_threads(broadcasts.size) do |index|
        if index.zero?
          QuotaLedger.mark_exhausted!(quota_date: day)
        else
          QuotaLedger.reserve!(fresh(broadcasts[index]), quota_date: day, daily_total: 10_000)
        end
      end

      expect(results.map(&:first)).to all(eq(:ok))
      expect(QuotaDay.find(day).exhausted).to be(true)
      late = create_bare_broadcast(quota_date: day)
      expect(QuotaLedger.reserve!(fresh(late), quota_date: day, daily_total: 10_000)).to be(false) # 印のあとの予約は、断られる
      expect_ledger_consistent(day)
    end
  end

  describe "記帳（spend!・spend_common!）" do
    it "同じ配信への同時の支出で、枠の残額を超えて支出しない（準備・確認枠 340 に、50 を 10 回: 成功は 6 回）" do
      broadcast = create_reserved_broadcast(quota_date: day)

      results = run_in_waves(10) { spend(broadcast, units: 50) }

      expect(results.map(&:first)).to all(eq(:ok))
      expect(successes(results)).to eq(6)
      expect(QuotaDay.find(day)).to have_attributes(used_units: 300, reserved_units: 250)
      expect(fresh(broadcast)).to have_attributes(prep_reserved_units: 40, settle_reserved_units: 210)
      expect(QuotaEntry.where(broadcast_id: broadcast.id).count).to eq(6)
      expect_ledger_consistent(day)
    end

    it "準備・確認枠の支出が重なっても、終了・清算枠を取り崩さない（準備・確認枠を使い切った後も、終了・清算枠は 210 のまま）" do
      broadcast = create_reserved_broadcast(quota_date: day)

      results = run_in_waves(12) { spend(broadcast, units: 100) }

      expect(successes(results)).to eq(3)
      expect(fresh(broadcast)).to have_attributes(prep_reserved_units: 40, settle_reserved_units: 210)
      expect(QuotaDay.find(day)).to have_attributes(used_units: 300, reserved_units: 250)
    end

    it "別々の配信への同時の支出が重なっても、台帳の合計が、明細と配信の残額と一致する" do
      broadcasts = Array.new(6) { create_reserved_broadcast(quota_date: day) }

      results = run_in_waves(36) do |index|
        spend(broadcasts[index % broadcasts.size], units: 1 + ((index % 7) * 10), bucket: index.even? ? :prep : :settle)
      end

      expect(results.map(&:first)).to all(eq(:ok))
      expect(QuotaEntry.where(quota_date: day).count).to eq(successes(results))
      expect_ledger_consistent(day)
    end

    it "共通枠の支出が重なっても、500 を超えない（50 を 12 回: 成功は 10 回）" do
      results = run_in_waves(12) do
        QuotaLedger.spend_common!(method: "channels.list", units: 50, quota_date: day, now: noon_of(day))
      end

      expect(results.map(&:first)).to all(eq(:ok))
      expect(successes(results)).to eq(10)
      expect(QuotaDay.find(day).common_used_units).to eq(500)
      expect(QuotaEntry.where(quota_date: day, bucket: "common").count).to eq(10)
      expect_ledger_consistent(day)
    end

    it "行の無い割り当て日への、同時の最初の記帳が重なっても、行は 1 件で、合計が合う（INSERT ... ON CONFLICT DO NOTHING）" do
      results = run_threads(concurrent_width) do
        QuotaLedger.spend_common!(method: "channels.list", units: 1, quota_date: next_day, now: noon_of(next_day))
      end

      expect(results.map(&:last)).to all(be(true))
      expect(QuotaDay.where(quota_date: next_day).count).to eq(1)
      expect(QuotaDay.find(next_day).common_used_units).to eq(concurrent_width)
      expect_ledger_consistent(next_day)
    end
  end

  describe "解放（release!）と移し替え（carry_over!）" do
    it "同じ配信の解放が、同時に重なっても、1 回だけ解放する（二重に解放しない。予約中が負にならない）" do
      broadcast = create_reserved_broadcast(quota_date: day)
      other = create_reserved_broadcast(quota_date: day)

      results = run_threads(concurrent_width) { QuotaLedger.release!(fresh(broadcast)) }

      expect(results.map(&:first)).to all(eq(:ok))
      expect(successes(results)).to eq(1)
      expect(QuotaDay.find(day).reserved_units).to eq(550) # 別の配信の予約だけが残る
      expect(fresh(other)).to have_attributes(prep_reserved_units: 340, settle_reserved_units: 210)
      expect_ledger_consistent(day)
    end

    it "同じ配信の移し替えが、同時に重なっても、1 回だけ移す（二重に移さない）" do
      broadcast = create_reserved_broadcast(quota_date: day)

      results = run_threads(concurrent_width) { QuotaLedger.carry_over!(fresh(broadcast), quota_date: next_day) }

      expect(results.map(&:first)).to all(eq(:ok))
      expect(successes(results)).to eq(1)
      expect(QuotaDay.find(day).reserved_units).to eq(0)
      expect(QuotaDay.find(next_day).reserved_units).to eq(550)
      expect_ledger_consistent(day, next_day)
    end

    it "支出と解放が、同じ配信に同時に重なっても、台帳が整合する（支出した分は、解放しない。解放した後の支出は、断られる）" do
      4.times do
        broadcast = create_reserved_broadcast(quota_date: day)

        results = run_threads(concurrent_width) do |index|
          index.odd? ? QuotaLedger.release!(fresh(broadcast)) : spend(broadcast, units: 50)
        end

        expect(results.map(&:first)).to all(eq(:ok))
        expect(fresh(broadcast)).to have_attributes(prep_reserved_units: 0, settle_reserved_units: 0)
      end
      expect_ledger_consistent(day)
    end

    it "割り当て日をまたぐ支出が、同時に重なっても、予約の残額を、1 回だけ、新しい日へ移す" do
      broadcast = create_reserved_broadcast(quota_date: day)

      results = run_threads(concurrent_width) { spend(broadcast, units: 10, at: noon_of(next_day)) }

      expect(results.map(&:first)).to all(eq(:ok))
      expect(successes(results)).to eq(concurrent_width)
      expect(QuotaDay.find(day)).to have_attributes(reserved_units: 0, used_units: 0)
      expect(QuotaDay.find(next_day)).to have_attributes(reserved_units: 550 - (10 * concurrent_width), used_units: 10 * concurrent_width)
      expect(fresh(broadcast).quota_date).to eq(next_day)
      expect_ledger_consistent(day, next_day)
    end
  end

  # 行ロックの順序（配信の行 → 台帳の行・割り当て日の昇順）が、すべての操作で同じなら、デッドロックしない。
  # 順序が食い違うと、PostgreSQL がデッドロックを検出して、片方を ActiveRecord::Deadlocked で中止させる。
  describe "入り混じった同時の操作（デッドロックしない）" do
    it "予約・支出（割り当て日をまたぐものを含む）・移し替え・解放・共通枠が、入り混じって重なっても、例外が起きず、台帳が整合する" do
      holders = Array.new(6) { create_reserved_broadcast(quota_date: day) } + Array.new(4) { create_reserved_broadcast(quota_date: next_day) }
      newcomers = Array.new(12) { create_bare_broadcast(quota_date: next_day) }
      rng = Random.new(20_261_007)
      kinds = %i[ spend_today spend_tomorrow carry release common reserve ]
      plan = Array.new(120) { kinds.sample(random: rng) }
      # 予約は、配信ごとに 1 回だけ（二重の予約は、呼び出し側の誤りで、NotReservable になる）。余りは、共通枠の操作に替える
      reserve_slots = plan.each_index.select { |index| plan.fetch(index) == :reserve }
      reserve_slots.drop(newcomers.size).each { |index| plan[index] = :common }
      newcomer_of = reserve_slots.first(newcomers.size).each_with_index.to_h { |plan_index, newcomer_index| [ plan_index, newcomers.fetch(newcomer_index) ] }

      results = run_in_waves(plan.size) do |index|
        case plan.fetch(index)
        when :spend_today then spend(holders.sample(random: Random.new(index)), units: 1 + (index % 5), at: noon_of(day))
        when :spend_tomorrow then spend(holders.sample(random: Random.new(index)), units: 1 + (index % 5), at: noon_of(next_day), bucket: :settle)
        when :carry then QuotaLedger.carry_over!(fresh(holders.sample(random: Random.new(index))), quota_date: next_day)
        when :release then QuotaLedger.release!(fresh(holders.sample(random: Random.new(index))))
        when :common then QuotaLedger.spend_common!(method: "channels.list", units: 1 + (index % 3), quota_date: [ day, next_day ][index % 2], now: noon_of(day))
        when :reserve then QuotaLedger.reserve!(fresh(newcomer_of.fetch(index)), quota_date: next_day, daily_total: 10_000)
        end
      end

      errors = results.select { |status, _| status == :error }.map { |_, error| "#{error.class}: #{error.message[0, 120]}" }
      expect(errors).to be_empty
      expect_ledger_consistent(day, next_day)
    end
  end

  # 途中で失敗したら、すべて取り消される。サービスが開いたトランザクションが、最後の書き込みの失敗で、台帳・配信・明細を、
  # すべて巻き戻すこと（スペックの外側のトランザクションは無い。巻き戻りが、実際にコミットされた状態で確かめられる）
  describe "途中で失敗したときの取り消し" do
    it "spend!: 明細の記帳が失敗したら、台帳の使用済み・予約中も、配信の枠も、元に戻る" do
      broadcast = create_reserved_broadcast(quota_date: day)
      allow(QuotaEntry).to receive(:create!).and_raise(RuntimeError, "forced failure")

      expect { spend(broadcast, units: 50) }.to raise_error(RuntimeError, "forced failure")

      expect(QuotaDay.find(day)).to have_attributes(used_units: 0, reserved_units: 550)
      expect(fresh(broadcast)).to have_attributes(prep_reserved_units: 340, settle_reserved_units: 210)
      expect(QuotaEntry.count).to eq(0)
    end

    it "spend!（割り当て日をまたぐ）: 記帳が失敗したら、移し替えも、取り消される" do
      broadcast = create_reserved_broadcast(quota_date: day)
      allow(QuotaEntry).to receive(:create!).and_raise(RuntimeError, "forced failure")

      expect { spend(broadcast, units: 50, at: noon_of(next_day)) }.to raise_error(RuntimeError, "forced failure")

      expect(QuotaDay.find(day)).to have_attributes(used_units: 0, reserved_units: 550)
      expect(QuotaDay.find_by(quota_date: next_day)).to be_nil
      expect(fresh(broadcast).quota_date).to eq(day)
    end

    it "spend_common!: 明細の記帳が失敗したら、共通枠の使用済みも、元に戻る" do
      seed_day(day)
      allow(QuotaEntry).to receive(:create!).and_raise(RuntimeError, "forced failure")

      expect { QuotaLedger.spend_common!(method: "channels.list", units: 5, quota_date: day, now: noon_of(day)) }.to raise_error(RuntimeError, "forced failure")

      expect(QuotaDay.find(day).common_used_units).to eq(0)
    end

    it "reserve!: 配信の更新が失敗したら、台帳の予約中も、台帳の行の作成も、元に戻る（予約が残らない）" do
      broadcast = create_bare_broadcast(quota_date: day)
      allow_any_instance_of(Broadcast).to receive(:update_columns).and_raise(RuntimeError, "forced failure")

      expect { QuotaLedger.reserve!(fresh(broadcast), quota_date: day, daily_total: 10_000) }.to raise_error(RuntimeError, "forced failure")

      expect(QuotaDay.find_by(quota_date: day)).to be_nil
      expect(fresh(broadcast)).to have_attributes(prep_reserved_units: 0, settle_reserved_units: 0)
    end

    it "release!: 配信の更新が失敗したら、台帳の予約中も、元に戻る（解放が、半分だけ反映されない）" do
      broadcast = create_reserved_broadcast(quota_date: day)
      allow_any_instance_of(Broadcast).to receive(:update_columns).and_raise(RuntimeError, "forced failure")

      expect { QuotaLedger.release!(fresh(broadcast)) }.to raise_error(RuntimeError, "forced failure")

      expect(QuotaDay.find(day).reserved_units).to eq(550)
      expect(fresh(broadcast)).to have_attributes(prep_reserved_units: 340, settle_reserved_units: 210)
    end

    it "carry_over!: 配信の更新が失敗したら、両方の日の台帳が、元に戻る" do
      broadcast = create_reserved_broadcast(quota_date: day)
      allow_any_instance_of(Broadcast).to receive(:update_columns).and_raise(RuntimeError, "forced failure")

      expect { QuotaLedger.carry_over!(fresh(broadcast), quota_date: next_day) }.to raise_error(RuntimeError, "forced failure")

      expect(QuotaDay.find(day).reserved_units).to eq(550)
      expect(QuotaDay.find_by(quota_date: next_day)).to be_nil
      expect(fresh(broadcast).quota_date).to eq(day)
    end
  end
end
