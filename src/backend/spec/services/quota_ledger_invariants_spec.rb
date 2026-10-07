require "rails_helper"
require "support/model_support"
require "services/support/ledger_support"

# 割り当て台帳の不変条件（requirements.md 8.4・20.2）を、ランダムな操作列で検査する（固定のシード。同じシードは、同じ操作列）。
# 操作: 受理（予約）・支出（準備・確認枠／終了・清算枠。成功・失敗の結果）・共通枠の支出・割り当て日の移し替え・解放・超過の印・日付の進行。
# 規則（QuotaPolicy）と同じ式で期待値を作らない。DB の明細と配信の残額から、独立に再計算した値と、保存された値を比べる。
#
#   1. 台帳の 1 日（used_units・reserved_units・common_used_units）が、明細と配信の残額から再計算した値と一致する
#   2. 配信ごとの保存則: 解放していない配信は、枠の残額 = 固定の枠 - その配信の明細の合計（準備・確認枠と終了・清算枠が別々）。
#      解放した配信は、残額 0。どの配信も、明細の合計が、固定の枠を超えない（終了・清算枠を、準備・確認の用途で取り崩さない）
#   3. 予約中・使用済み・共通枠の使用済みは、負にならない（DB の CHECK 制約に頼る前に、ロジックで保証する。違反は、操作が例外になる）
#   4. 共通枠の使用済みは、共通枠（500）を超えない
module LedgerInvariantParameters
  # 固定のシード。値に意味は無い（再現のための固定）
  SEEDS = [ 20_261_007, 7, 123_456 ].freeze
  STEPS = 160
  # 操作と重み
  WEIGHTS = { accept: 24, spend: 40, spend_common: 8, release: 8, carry: 6, exhaust: 1, advance: 4 }.freeze
  UNITS = [ 1, 1, 2, 50, 51, 100, 211, 340 ].freeze
  KINDS = %w[ liveBroadcasts.list liveBroadcasts.insert liveBroadcasts.bind liveBroadcasts.transition liveStreams.list ].freeze
  TOTALS = [ 10_000, 10_000, 10_000, 8_000, 3_000 ].freeze
end

RSpec.describe "割り当て台帳の不変条件（ランダムな操作列）" do
  include LedgerSupport

  def pick(rng, weights)
    point = rng.rand(weights.values.sum)
    weights.each do |name, weight|
      return name if point < weight

      point -= weight
    end
  end

  # 台帳の 1 日の保存された値が、負でない・共通枠を超えない
  def expect_day_bounds(dates)
    QuotaDay.where(quota_date: dates).each do |row|
      expect([ row.used_units, row.reserved_units, row.common_used_units ]).to all(be >= 0)
      expect(row.common_used_units).to be <= QuotaPolicy::COMMON_UNITS
    end
  end

  # 配信ごとの保存則（2）
  def expect_conservation(holders)
    holders.each do |holder|
      broadcast = Broadcast.find(holder.fetch(:id))
      spent = QuotaEntry.where(broadcast_id: broadcast.id).group(:bucket).sum(:units)
      spent_prep = spent.fetch("prep", 0)
      spent_settle = spent.fetch("settle", 0)

      expect(spent_prep).to be <= QuotaPolicy::PREP_UNITS, "broadcast #{broadcast.id} spent more than the prep bucket"
      expect(spent_settle).to be <= QuotaPolicy::SETTLE_UNITS, "broadcast #{broadcast.id} spent more than the settle bucket"
      if holder.fetch(:released)
        expect([ broadcast.prep_reserved_units, broadcast.settle_reserved_units ]).to eq([ 0, 0 ])
      else
        expect(broadcast.prep_reserved_units).to eq(QuotaPolicy::PREP_UNITS - spent_prep)
        expect(broadcast.settle_reserved_units).to eq(QuotaPolicy::SETTLE_UNITS - spent_settle)
      end
    end
  end

  # 受理: 配信を作って、予約する。予約できた配信を、保持の一覧へ入れる（断られた配信は、予約を持たない）
  def op_accept(rng, today, holders)
    date = quota_day(today)
    broadcast = create_bare_broadcast(quota_date: date)
    reserved = QuotaLedger.reserve!(broadcast, quota_date: date, daily_total: LedgerInvariantParameters::TOTALS.sample(random: rng))
    holders << { id: broadcast.id, released: false, origin: date } if reserved
    reserved
  end

  # 支出: 古いメモリ上の配信（DB から読み直さない）と、読み直した配信を、半々で使う
  def op_spend(rng, today, holders)
    return if holders.empty?

    holder = holders.sample(random: rng)
    broadcast = rng.rand < 0.5 ? Broadcast.find(holder.fetch(:id)) : holder.fetch(:memory) { Broadcast.find(holder.fetch(:id)) }
    holder[:memory] = broadcast
    at = noon_of(quota_day(today)) + rng.rand(-36_000..36_000)
    QuotaLedger.spend!(
      broadcast,
      method: LedgerInvariantParameters::KINDS.sample(random: rng), units: LedgerInvariantParameters::UNITS.sample(random: rng), bucket: %i[ prep prep settle ].sample(random: rng),
      result: %w[ ok ok error ].sample(random: rng), now: at
    )
  end

  def op_spend_common(rng, today, _holders)
    QuotaLedger.spend_common!(
      method: LedgerInvariantParameters::KINDS.sample(random: rng), units: [ 1, 1, 50, 100, 250 ].sample(random: rng),
      quota_date: quota_day(today), result: %w[ ok error ].sample(random: rng), now: noon_of(quota_day(today))
    )
  end

  def op_release(rng, _today, holders)
    return if holders.empty?

    holder = holders.sample(random: rng)
    released = QuotaLedger.release!(Broadcast.find(holder.fetch(:id)))
    holder[:released] = true if released
    released
  end

  def op_carry(rng, today, holders)
    return if holders.empty?

    QuotaLedger.carry_over!(Broadcast.find(holders.sample(random: rng).fetch(:id)), quota_date: quota_day(today))
  end

  def op_exhaust(_rng, today, _holders)
    QuotaLedger.mark_exhausted!(quota_date: quota_day(today))
  end

  def run_sequence(seed)
    rng = Random.new(seed)
    today = 0
    holders = []
    stats = Hash.new(0) # [操作, 結果（true・false・nil。何もしなかった）] => 回数

    LedgerInvariantParameters::STEPS.times do |step|
      operation = pick(rng, LedgerInvariantParameters::WEIGHTS)
      if operation == :advance
        today += 1 if today < 3
      else
        stats[[ operation, send(:"op_#{operation}", rng, today, holders) ]] += 1
      end

      dates = (0..today).map { |offset| quota_day(offset) } # 操作が触れ得る日は、今日まで（先の日には、何も無い）
      expect_ledger_consistent(*dates)
      expect_day_bounds(dates)
      expect_conservation(holders) if (step % 11).zero?
    end
    expect_conservation(holders)
    [ holders, stats ]
  end

  # 全体の合計（日ごとの値の足し上げが、明細・配信の合計と一致する）
  def expect_grand_totals
    expect(QuotaDay.sum(:used_units)).to eq(QuotaEntry.where(bucket: %w[ prep settle ]).sum(:units))
    expect(QuotaDay.sum(:common_used_units)).to eq(QuotaEntry.where(bucket: "common").sum(:units))
    expect(QuotaDay.sum(:reserved_units)).to eq(Broadcast.sum(:prep_reserved_units) + Broadcast.sum(:settle_reserved_units))
  end

  LedgerInvariantParameters::SEEDS.each do |seed|
    it "シード #{seed}: #{LedgerInvariantParameters::STEPS} 回の操作のたびに、台帳の 1 日が、明細と配信の残額から再計算した値と一致し、保存則が成り立つ" do
      holders, stats = run_sequence(seed)
      expect_grand_totals

      # 操作列が、成功も、断られる場合も、移し替えも含み、台帳が動いていること（空の操作列を、成功と見なさない）
      expect(holders.size).to be >= 8
      expect(QuotaEntry.where(bucket: %w[ prep settle ]).count).to be >= 20
      expect(QuotaEntry.where(bucket: "common").count).to be >= 3
      expect(QuotaDay.count).to be >= 2
      expect(holders.count { |holder| holder.fetch(:released) }).to be >= 1
      expect(stats[[ :spend, true ]]).to be >= 20
      expect(stats[[ :spend, false ]]).to be >= 1 # 枠の不足・予約の無い配信
      # 割り当て日をまたいで、予約が移った配信がある（明示の移し替えか、またいだ後の最初の支出で）
      moved = holders.count { |holder| Broadcast.find(holder.fetch(:id)).quota_date != holder.fetch(:origin) }
      expect(moved).to be >= 1
    end
  end

  it "同じシードは、同じ操作列（再現できる）" do
    rng_a = Random.new(LedgerInvariantParameters::SEEDS.first)
    rng_b = Random.new(LedgerInvariantParameters::SEEDS.first)
    sequence = ->(rng) { Array.new(60) { [ pick(rng, LedgerInvariantParameters::WEIGHTS), LedgerInvariantParameters::UNITS.sample(random: rng) ] } }

    expect(sequence.call(rng_a)).to eq(sequence.call(rng_b))
    expect(sequence.call(Random.new(LedgerInvariantParameters::SEEDS.first))).not_to eq(sequence.call(Random.new(LedgerInvariantParameters::SEEDS.last)))
  end
end
