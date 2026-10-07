require "rails_helper"
require "support/model_support"
require "services/support/ledger_support"

# 日次の利用枠・開始試行の、同時の操作（requirements.md 14 章・27 章「整合性」「同時性」）。
# 複数の接続（スレッド）が、同時に同じ配信・同じ利用日の行へ挑む。二重に消費しない・二重に計上しない・上限を超えない・
# 付与が失われない、を、行ロックと、1 つの upsert 文で保証する。
#
# 別の接続からは、未コミットの行が見えない。このグループは、トランザクションで包まず、実際にコミットする。
# 例が作った行（アカウント。配信・利用実績は、連鎖で消える）は、各例の前後で、SQL で整理する。
RSpec.describe "日次の利用枠・開始試行の同時の操作" do
  include LedgerSupport

  self.use_transactional_tests = false

  let(:usage_date) { Date.new(2031, 4, 14) }
  let(:settings) { Settings.defaults }

  before { clean_committed_rows! }
  after { clean_committed_rows! }

  def fresh(broadcast)
    Broadcast.find(broadcast.id)
  end

  def outcomes(results)
    results.map { |status, value| status == :ok ? value : value.class }
  end

  # 同じアカウントの、同じ利用日の行と、その利用日に属する配信（終了していないもの 1 件と、終了したもの）
  def account_with_usage(consumed: 0, attempts: 0, extra: 0)
    user = create_tracked_user
    usage = create(:daily_usage, user: user, usage_date: usage_date, consumed_count: consumed, attempt_count: attempts, extra_grants: extra)
    [ user, usage ]
  end

  describe "ensure_for!（利用日の行の取得・作成）" do
    it "同じアカウント・利用日への、同時の最初の呼び出しが重なっても、行は 1 件で、全員が、同じ行を得る" do
      user = create_tracked_user

      results = run_threads(concurrent_width) { DailyAllowance.ensure_for!(user_id: user.id, usage_date: usage_date).id }

      expect(results.map(&:first)).to all(eq(:ok))
      expect(results.map(&:last).uniq.size).to eq(1)
      expect(DailyUsage.owned_by(user).where(usage_date: usage_date).count).to eq(1)
    end

    it "行ロックは、呼び出し側のトランザクションが終わるまで続く（同じ行への、もう 1 つの確保は、待たされる）" do
      user, = account_with_usage # 行は、先に作っておく（待たされるのは、行の作成の競合ではなく、FOR UPDATE のため）
      holder_ready = Queue.new
      release_holder = Queue.new
      order = Queue.new

      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            DailyAllowance.ensure_for!(user_id: user.id, usage_date: usage_date)
            holder_ready << true
            release_holder.pop
            order << :holder_done
          end
        end
      end
      holder_ready.pop

      waiter = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            DailyAllowance.ensure_for!(user_id: user.id, usage_date: usage_date)
            order << :waiter_got_lock
          end
        end
      end

      sleep 0.5 # 待たされている間に、先の確保の持ち主が、先に終わる（ロックが解けるまで、後の確保は進まない）
      release_holder << true
      [ holder, waiter ].each(&:join)

      expect([ order.pop, order.pop ]).to eq(%i[ holder_done waiter_got_lock ])
    end
  end

  describe "grant_extra!（追加の付与）" do
    it "同時の付与が、1 つも失われない（追加の数が、付与の回数と一致する）。行は 1 件。開始試行は 0" do
      user = create_tracked_user

      results = run_in_waves(8) { DailyAllowance.grant_extra!(user_id: user.id, usage_date: usage_date).id }

      expect(results.map(&:first)).to all(eq(:ok))
      expect(DailyUsage.owned_by(user).where(usage_date: usage_date).count).to eq(1)
      expect(DailyUsage.owned_by(user).find_by!(usage_date: usage_date)).to have_attributes(extra_grants: 8, attempt_count: 0, consumed_count: 0)
    end

    it "既存の行へ、同時に付与しても、消費数を変えず、追加が積み上がり、開始試行が 0 に戻る" do
      user, usage = account_with_usage(consumed: 1, attempts: 3)

      run_in_waves(4) { DailyAllowance.grant_extra!(user_id: user.id, usage_date: usage_date) }

      expect(usage.reload).to have_attributes(extra_grants: 4, attempt_count: 0, consumed_count: 1)
    end
  end

  describe "consume!（利用枠の消費）" do
    it "同じ配信への同時の消費は、1 回だけ（二重に消費しない）。ほかは false で、例外にならない" do
      user, usage = account_with_usage
      broadcast = create(:broadcast, user: user, daily_usage: usage)

      results = run_threads(concurrent_width) { DailyAllowance.consume!(fresh(broadcast), settings: settings) }

      expect(outcomes(results).count(true)).to eq(1)
      expect(outcomes(results).count(false)).to eq(concurrent_width - 1)
      expect(usage.reload.consumed_count).to eq(1)
      expect(fresh(broadcast).allowance_consumed).to be(true)
    end

    it "利用枠が 1 回のとき、同じ利用日の 2 つの配信の同時の消費は、片方だけが成功し、もう片方は AllowanceExhausted（上限を超えない）" do
      user, usage = account_with_usage
      first = create(:broadcast, :ended, user: user, daily_usage: usage)
      second = create(:broadcast, user: user, daily_usage: usage)

      results = run_threads(2) { |index| DailyAllowance.consume!(fresh(index.zero? ? first : second), settings: settings) }

      expect(outcomes(results)).to contain_exactly(true, DailyAllowance::AllowanceExhausted)
      expect(usage.reload.consumed_count).to eq(1)
      expect(Broadcast.where(id: [ first.id, second.id ], allowance_consumed: true).count).to eq(1)
    end

    it "追加の付与と、消費が同時に重なっても、数が合う（付与は、失われない）" do
      user, usage = account_with_usage(consumed: 1)
      broadcast = create(:broadcast, user: user, daily_usage: usage)

      results = run_threads(concurrent_width) do |index|
        index.zero? ? DailyAllowance.grant_extra!(user_id: user.id, usage_date: usage_date) : DailyAllowance.consume!(fresh(broadcast), settings: settings)
      end

      # 消費は、付与が先なら成功、後なら例外。どちらでも、付与は 1 回分が残り、消費は 1 回を超えない
      expect(results.map(&:first)).to include(:ok)
      expect(usage.reload.extra_grants).to eq(1)
      expect(usage.consumed_count).to be_between(1, 2)
      expect(fresh(broadcast).allowance_consumed).to eq(usage.consumed_count == 2)
    end
  end

  describe "count_attempt!（開始試行の計上）" do
    it "同じ配信への同時の計上は、1 回だけ（二重に計上しない）" do
      user, usage = account_with_usage
      broadcast = create(:broadcast, user: user, daily_usage: usage)

      results = run_threads(concurrent_width) { DailyAllowance.count_attempt!(fresh(broadcast), settings: settings) }

      expect(outcomes(results).count(true)).to eq(1)
      expect(outcomes(results).count(false)).to eq(concurrent_width - 1)
      expect(usage.reload.attempt_count).to eq(1)
      expect(fresh(broadcast).attempt_counted).to be(true)
    end

    it "上限の 1 回手前（計上 2・上限 3）で、2 つの配信の同時の計上は、片方だけが成功し、もう片方は AttemptLimitReached" do
      user, usage = account_with_usage(attempts: 2)
      first = create(:broadcast, :ended, user: user, daily_usage: usage)
      second = create(:broadcast, user: user, daily_usage: usage)

      results = run_threads(2) { |index| DailyAllowance.count_attempt!(fresh(index.zero? ? first : second), settings: settings) }

      expect(outcomes(results)).to contain_exactly(true, DailyAllowance::AttemptLimitReached)
      expect(usage.reload.attempt_count).to eq(3)
      expect(Broadcast.where(id: [ first.id, second.id ], attempt_counted: true).count).to eq(1)
    end

    it "計上と手動リセット（grant_extra!）が同時に重なっても、行は壊れない（計上は 1 回分が残るか、0 に戻る）" do
      user, usage = account_with_usage(attempts: 1)
      broadcast = create(:broadcast, user: user, daily_usage: usage)

      results = run_threads(2) do |index|
        index.zero? ? DailyAllowance.count_attempt!(fresh(broadcast), settings: settings) : DailyAllowance.grant_extra!(user_id: user.id, usage_date: usage_date)
      end

      expect(results.map(&:first)).to all(eq(:ok))
      expect(usage.reload.extra_grants).to eq(1)
      expect(usage.attempt_count).to be_between(0, 2)
    end
  end

  # 途中で失敗したら、すべて取り消される。最後の書き込み（配信の印）の失敗で、利用枠の行の更新も取り消されること
  describe "途中で失敗したときの取り消し" do
    it "consume!: 配信の印の更新が失敗したら、消費数も、元に戻る" do
      user, usage = account_with_usage
      broadcast = create(:broadcast, user: user, daily_usage: usage)
      allow_any_instance_of(Broadcast).to receive(:update_columns).and_raise(RuntimeError, "forced failure")

      expect { DailyAllowance.consume!(fresh(broadcast), settings: settings) }.to raise_error(RuntimeError, "forced failure")

      expect(usage.reload.consumed_count).to eq(0)
      expect(fresh(broadcast).allowance_consumed).to be(false)
    end

    it "count_attempt!: 配信の印の更新が失敗したら、計上数も、元に戻る" do
      user, usage = account_with_usage
      broadcast = create(:broadcast, user: user, daily_usage: usage)
      allow_any_instance_of(Broadcast).to receive(:update_columns).and_raise(RuntimeError, "forced failure")

      expect { DailyAllowance.count_attempt!(fresh(broadcast), settings: settings) }.to raise_error(RuntimeError, "forced failure")

      expect(usage.reload.attempt_count).to eq(0)
      expect(fresh(broadcast).attempt_counted).to be(false)
    end
  end
end
