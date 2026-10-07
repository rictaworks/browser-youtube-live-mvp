require "spec_helper"
require "date"
require_relative "support/domain_loader"

# 割り当て台帳のシミュレーション（requirements.md 8.4 の単価表と回数の上限）。
# すべての配信が、準備・確認（321 / 枠 340）と、終了・清算（204 / 枠 210）の回数の上限まで支出しても、
# 枠を超えず、1 日の割り当て（10,000）を超えないこと。準備・確認の支出が、終了・清算の支出を不足させないこと。
#
# 呼び出しの単価は、契約（Contract::Limits::QUOTA の unit_costs）から取る。表の各行は、[ ラベル, 単価のキー（1 回の呼び出し）, 回数 ]。
RSpec.describe "割り当て台帳のシミュレーション（QuotaPolicy）" do
  # 8.4 の表「準備・確認」の各行。ライブ中の定期確認・復帰時の確認は、1 回で 2 ユニット（配信状態とストリームの健全性）
  let(:preparation_calls) do
    [
      [ "先行配信の状態確認（一覧取得）", %w[list], 1 ],
      [ "先行配信の清算（遷移または削除）", %w[transition], 1 ],
      [ "配信の作成", %w[insert], 1 ],
      [ "応答喪失時の未開始配信の一覧取得", %w[list], 1 ],
      [ "ストリームの確認（取り込み先・配信キーの取得を兼ねる）", %w[list], 1 ],
      [ "ストリームの作成（保存した識別子が無い・無効な場合のみ）", %w[insert], 1 ],
      [ "紐づけ", %w[bind], 1 ],
      [ "準備中の一時的な失敗の再試行", %w[insert], 1 ],
      [ "ライブ確定の確認（5 秒間隔・最長 120 秒）", %w[list], 24 ],
      [ "ライブ中の定期確認（配信状態とストリームの健全性。5 分間隔・最長 60 分）", %w[list list], 12 ],
      [ "復帰時の確認（配信状態と、必要な場合の配信キーの再取得）", %w[list list], 10 ]
    ]
  end

  # 8.4 の表「終了・清算」の各行。清算の再試行は、状態確認（一覧取得）と清算（遷移）の 1 組で 51 ユニット
  let(:settlement_calls) do
    [
      [ "終了時の状態確認", %w[list], 1 ],
      [ "完了への遷移、または未開始の削除", %w[transition], 1 ],
      [ "清算の再試行（状態確認と清算）", %w[list transition], 3 ]
    ]
  end

  let(:policy) { QuotaPolicy }
  let(:date) { Date.new(2026, 10, 6) }
  let(:daily_total) { Settings.defaults.daily_quota_units }

  # 表の行を、1 回ずつの呼び出しの単価の列にする（行の回数だけ並べる）
  def unit_calls(table)
    costs = Contract::Limits::QUOTA.fetch("unit_costs")
    table.flat_map { |_label, keys, count| Array.new(count) { keys.sum { |key| costs.fetch(key) } } }
  end

  def empty_day
    QuotaPolicy::Day.new(quota_date: date, used_units: 0, reserved_units: 0, common_used_units: 0)
  end

  # 台帳の不変条件: 使用済み + 予約中が配信に使える上限以下。予約中は、予約の残額の合計と一致する
  def check_invariants(current_day, reservations)
    usable = policy.usable_units(daily_total: daily_total)
    expect(current_day.used_units + current_day.reserved_units).to be <= usable
    expect(current_day.reserved_units).to eq(reservations.sum(&:remaining_units))
    expect(current_day.reserved_units).to be >= 0
  end

  describe "8.4 の単価表" do
    it "準備・確認の小計は 321（枠 340）、終了・清算の小計は 204（枠 210）。契約の単価から再計算して、表と一致する" do
      prep_total = unit_calls(preparation_calls).sum
      settle_total = unit_calls(settlement_calls).sum

      expect(prep_total).to eq(321)
      expect(settle_total).to eq(204)
      expect(prep_total).to be <= policy::PREP_UNITS
      expect(settle_total).to be <= policy::SETTLE_UNITS
      expect(prep_total + settle_total).to eq(525)
    end

    it "準備・確認の呼び出しの回数は 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 24 + 12 + 10 = 54 回、終了・清算は 1 + 1 + 3 = 5 回" do
      expect(unit_calls(preparation_calls).size).to eq(54)
      expect(unit_calls(settlement_calls).size).to eq(5)
    end
  end

  describe "1 本の配信" do
    it "すべての呼び出しが上限の回数まで、枠を超えず、すべて記帳できる。準備・確認に 19、終了・清算に 6 が残る" do
      booked = policy.reserve(empty_day, daily_total: daily_total)
      current_day = booked.day
      held = booked.reservation

      unit_calls(preparation_calls).each do |units|
        outcome = policy.spend(held, bucket: :prep, units: units, day: current_day)
        expect(outcome).to be_granted
        current_day = outcome.day
        held = outcome.reservation
      end
      unit_calls(settlement_calls).each do |units|
        outcome = policy.spend(held, bucket: :settle, units: units, day: current_day)
        expect(outcome).to be_granted
        current_day = outcome.day
        held = outcome.reservation
      end

      expect(held.prep_remaining_units).to eq(19)
      expect(held.settle_remaining_units).to eq(6)
      expect(current_day.used_units).to eq(525)
      expect(current_day.reserved_units).to eq(25)
      expect(policy.release(held, day: current_day).day).to eq(
        QuotaPolicy::Day.new(quota_date: date, used_units: 525, reserved_units: 0, common_used_units: 0)
      )
    end

    it "準備・確認の支出が、予約の枠（340）を超えようとしても、終了・清算枠は減らず、終了・清算の支出がすべて通る" do
      booked = policy.reserve(empty_day, daily_total: daily_total)
      current_day = booked.day
      held = booked.reservation

      # 50 ユニットの呼び出し（作成・紐づけなど）を、枠が尽きるまで続ける。7 回（350）は入らず、6 回（300）で 40 が残る
      refused = 0
      10.times do
        outcome = policy.spend(held, bucket: :prep, units: 50, day: current_day)
        if outcome.granted?
          current_day = outcome.day
          held = outcome.reservation
        else
          refused += 1
        end
      end
      expect(held.prep_remaining_units).to eq(40)
      expect(refused).to eq(4)
      expect(held.settle_remaining_units).to eq(210)

      unit_calls(settlement_calls).each do |units|
        outcome = policy.spend(held, bucket: :settle, units: units, day: current_day)
        expect(outcome).to be_granted
        current_day = outcome.day
        held = outcome.reservation
      end
      expect(held.settle_remaining_units).to eq(6)
    end
  end

  describe "16 本の配信（9,000 / 550 = 16 本）" do
    def reserve_all(count)
      current_day = empty_day
      reservations = []
      count.times do
        outcome = policy.reserve(current_day, daily_total: daily_total)
        break unless outcome.granted?

        current_day = outcome.day
        reservations << outcome.reservation
      end
      [ current_day, reservations ]
    end

    it "17 本目の予約は拒否される（予約中 8,800 + 550 = 9,350 > 9,000）" do
      current_day, reservations = reserve_all(17)

      expect(reservations.size).to eq(16)
      expect(current_day.reserved_units).to eq(8_800)
      expect(policy.reserve(current_day, daily_total: daily_total)).not_to be_granted
    end

    it "16 本すべてが、準備・確認と終了・清算の上限まで支出しても、配信に使える上限（9,000）を超えない。全支出が記帳できる" do
      current_day, reservations = reserve_all(16)
      calls = unit_calls(preparation_calls).map { |units| [ :prep, units ] } + unit_calls(settlement_calls).map { |units| [ :settle, units ] }

      # 配信ごとに 1 呼び出しずつ、交互に進める（全配信が同時に進行する最悪の並び）
      calls.each do |bucket, units|
        reservations = reservations.map do |held|
          outcome = policy.spend(held, bucket: bucket, units: units, day: current_day)
          expect(outcome).to be_granted
          current_day = outcome.day
          outcome.reservation
        end
        check_invariants(current_day, reservations)
      end

      expect(current_day.used_units).to eq(16 * 525)
      expect(current_day.used_units).to be <= policy.usable_units(daily_total: daily_total)
      expect(reservations.map(&:prep_remaining_units).uniq).to eq([ 19 ])
      expect(reservations.map(&:settle_remaining_units).uniq).to eq([ 6 ])

      # 清算が終端に達して、予約の残額を解放する
      reservations.each do |held|
        outcome = policy.release(held, day: current_day)
        current_day = outcome.day
      end
      expect(current_day.reserved_units).to eq(0)
      expect(current_day.used_units).to eq(8_400)
    end

    it "すべての配信が予約を使い切る最悪でも、配信 + 共通枠 + 安全余裕が、1 日の割り当て（10,000）を超えない" do
      worst = policy.usable_units(daily_total: daily_total) / policy::RESERVATION_UNITS * policy::RESERVATION_UNITS

      expect(worst).to eq(8_800)
      expect(worst + policy::COMMON_UNITS + policy::SAFETY_MARGIN_UNITS).to be <= daily_total
    end

    it "実費が予約より小さい（525 < 550）ので、16 本が終わって解放したあと、さらに 1 本（17 本目）が入る。その次は入らない" do
      current_day, reservations = reserve_all(16)
      reservations.each do |held|
        spent_prep = policy.spend(held, bucket: :prep, units: 321, day: current_day)
        spent_settle = policy.spend(spent_prep.reservation, bucket: :settle, units: 204, day: spent_prep.day)
        released = policy.release(spent_settle.reservation, day: spent_settle.day)
        current_day = released.day
      end
      expect(current_day.used_units).to eq(8_400)
      expect(current_day.reserved_units).to eq(0)

      seventeenth = policy.reserve(current_day, daily_total: daily_total)
      expect(seventeenth).to be_granted
      expect(policy.reserve(seventeenth.day, daily_total: daily_total)).not_to be_granted
    end

    it "ランダムな順序（固定の種）で、全配信の全呼び出しを混ぜても、すべて記帳でき、不変条件が保たれる" do
      current_day, reservations = reserve_all(16)
      operations = []
      reservations.each_index do |index|
        unit_calls(preparation_calls).each { |units| operations << [ index, :prep, units ] }
        unit_calls(settlement_calls).each { |units| operations << [ index, :settle, units ] }
      end
      shuffled = operations.shuffle(random: Random.new(20_261_007))

      shuffled.each do |index, bucket, units|
        outcome = policy.spend(reservations[index], bucket: bucket, units: units, day: current_day)
        expect(outcome).to be_granted, "配信 #{index} の #{bucket} #{units} ユニットが記帳できません"
        current_day = outcome.day
        reservations[index] = outcome.reservation
        check_invariants(current_day, reservations)
      end

      expect(current_day.used_units).to eq(16 * 525)
      expect(shuffled.size).to eq(16 * 59)
    end

    it "準備・確認の過剰な支出を混ぜても（どの配信も、枠を超える分は拒否される）、終了・清算の支出はすべて通る" do
      current_day, reservations = reserve_all(16)
      random = Random.new(7)

      # 準備・確認を、50 ユニットずつ、ランダムな配信に 200 回（1 本あたり平均 12.5 回 = 625 ユニット。枠 340 を超える配信が出る）
      200.times do
        index = random.rand(reservations.size)
        outcome = policy.spend(reservations[index], bucket: :prep, units: 50, day: current_day)
        next unless outcome.granted?

        current_day = outcome.day
        reservations[index] = outcome.reservation
      end
      expect(reservations.map(&:prep_remaining_units)).to all(be < 50)
      expect(reservations.map(&:settle_remaining_units).uniq).to eq([ 210 ])
      check_invariants(current_day, reservations)

      reservations.each_index do |index|
        unit_calls(settlement_calls).each do |units|
          outcome = policy.spend(reservations[index], bucket: :settle, units: units, day: current_day)
          expect(outcome).to be_granted
          current_day = outcome.day
          reservations[index] = outcome.reservation
        end
      end
      check_invariants(current_day, reservations)
    end
  end

  describe "共通枠（配信に属さない呼び出し。接続時の確認・再確認・チャンネル名の取得）" do
    it "500 ユニットまで支出でき、尽きたあとは、配信の予約があっても支出できない（割り当て日の終わりまで）" do
      current_day = empty_day
      list_cost = Contract::Limits::QUOTA.fetch("unit_costs").fetch("list")
      granted = 0
      600.times do
        outcome = policy.spend_common(current_day, units: list_cost)
        next unless outcome.granted?

        current_day = outcome.day
        granted += 1
      end

      expect(granted).to eq(500)
      expect(current_day.common_used_units).to eq(500)
      expect(policy.reserve(current_day, daily_total: daily_total)).to be_granted
      expect(policy.spend_common(current_day, units: list_cost)).not_to be_granted
    end
  end

  describe "割り当て日をまたぐ配信" do
    it "またいだ後の最初の支出で、残額を新しい割り当て日へ移す。使用済みは、支出した日に残る。最後に、新しい日で解放する" do
      next_date = Date.new(2026, 10, 7)
      day_one = policy.reserve(empty_day, daily_total: daily_total)
      day_two = QuotaPolicy::Day.new(quota_date: next_date, used_units: 100, reserved_units: 550, common_used_units: 0)

      # 1 日目: 準備・確認を 200 ユニット使う
      spent = policy.spend(day_one.reservation, bucket: :prep, units: 200, day: day_one.day)
      expect(spent.day).to eq(QuotaPolicy::Day.new(quota_date: date, used_units: 200, reserved_units: 350, common_used_units: 0))

      # 2 日目の最初の支出の前に、移し替える
      carried = policy.carry_over(spent.reservation, from: spent.day, to: day_two)
      expect(carried.from.reserved_units).to eq(0)
      expect(carried.from.used_units).to eq(200)
      expect(carried.to.reserved_units).to eq(900)

      # 2 日目: 準備・確認の残り 140 のうち 20、終了・清算を 204 使う
      after_prep = policy.spend(carried.reservation, bucket: :prep, units: 20, day: carried.to)
      after_settle = policy.spend(after_prep.reservation, bucket: :settle, units: 204, day: after_prep.day)
      released = policy.release(after_settle.reservation, day: after_settle.day)

      expect(released.day).to eq(QuotaPolicy::Day.new(quota_date: next_date, used_units: 324, reserved_units: 550, common_used_units: 0))
      expect(released.reservation.remaining_units).to eq(0)
    end
  end
end
