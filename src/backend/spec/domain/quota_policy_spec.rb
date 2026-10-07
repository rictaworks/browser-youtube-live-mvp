require "spec_helper"
require "date"
require_relative "support/domain_loader"

# 割り当て台帳の規則（requirements.md 8.4・15 章「割り当ての予約」「割り当ての記帳」）。純粋な値の変換で、不変の値を返す。
#
#   台帳の 1 日（Day）   割り当て日・配信の使用済み・予約中・共通枠の使用済み・割り当て超過の印（exhausted）
#   予約（Reservation）  配信 1 本の予約。割り当て日と、準備・確認枠・終了・清算枠の残額（550 = 340 + 210）
#
# 配信に使える上限 = 1 日の割り当て - 共通枠 500 - 安全余裕 500（既定の 10,000 で 9,000）。
# 呼び出しの結果は、記帳できたとき Booked（更新後の台帳と予約）、できないとき Refused（理由。台帳・予約は変えない）。
RSpec.describe "割り当て台帳の規則（QuotaPolicy）" do
  let(:policy) { QuotaPolicy }
  let(:date) { Date.new(2026, 10, 6) }
  let(:next_date) { Date.new(2026, 10, 7) }

  def day(date: Date.new(2026, 10, 6), used: 0, reserved: 0, common: 0, exhausted: false)
    QuotaPolicy::Day.new(quota_date: date, used_units: used, reserved_units: reserved, common_used_units: common, exhausted: exhausted)
  end

  def reservation(date: Date.new(2026, 10, 6), prep: 340, settle: 210)
    QuotaPolicy::Reservation.new(quota_date: date, prep_remaining_units: prep, settle_remaining_units: settle)
  end

  describe "固定値（契約の limits.json の quota）" do
    it "共通枠 500・安全余裕 500・配信 1 本の予約 550（準備・確認 340 + 終了・清算 210）。契約の値と同じ" do
      quota = Contract::Limits::QUOTA

      expect(policy::COMMON_UNITS).to eq(quota.fetch("common_units"))
      expect(policy::SAFETY_MARGIN_UNITS).to eq(quota.fetch("safety_margin_units"))
      expect(policy::RESERVATION_UNITS).to eq(quota.fetch("broadcast_reservation_units"))
      expect(policy::PREP_UNITS).to eq(quota.fetch("prep_reservation_units"))
      expect(policy::SETTLE_UNITS).to eq(quota.fetch("settle_reservation_units"))
      expect([ policy::COMMON_UNITS, policy::SAFETY_MARGIN_UNITS, policy::RESERVATION_UNITS, policy::PREP_UNITS, policy::SETTLE_UNITS ])
        .to eq([ 500, 500, 550, 340, 210 ])
      expect(policy::PREP_UNITS + policy::SETTLE_UNITS).to eq(policy::RESERVATION_UNITS)
    end

    it "枠の種類は、準備・確認（:prep）と終了・清算（:settle）の 2 つ" do
      expect(policy::BUCKETS).to eq(%i[prep settle])
      expect(policy::BUCKETS).to be_frozen
    end
  end

  describe ".usable_units（配信に使える上限 = 1 日の割り当て - 共通枠 - 安全余裕）" do
    {
      "既定の 10,000 は 9,000（契約の broadcast_usable_units_at_default）" => [ 10_000, 9_000 ],
      "20,000 は 19,000" => [ 20_000, 19_000 ],
      "1,000（共通枠 + 安全余裕だけ）は 0" => [ 1_000, 0 ],
      "1,550 は 550" => [ 1_550, 550 ]
    }.each do |label, (daily_total, expected)|
      it label do
        expect(policy.usable_units(daily_total: daily_total)).to eq(expected)
      end
    end

    it "既定の設定（Settings.defaults.daily_quota_units）から、契約の 9,000 になる" do
      expect(policy.usable_units(daily_total: Settings.defaults.daily_quota_units))
        .to eq(Contract::Limits::QUOTA.fetch("broadcast_usable_units_at_default"))
    end
  end

  describe ".can_reserve?（使用済み + 予約中 + 新規の予約 <= 配信に使える上限）" do
    # [ 使用済み, 予約中, 新規の予約, 1 日の割り当て, 期待 ]
    {
      "台帳が空: 550 は予約できる" => [ 0, 0, 550, 10_000, true ],
      "ちょうど 9,000（予約中 8,450 + 550）は可（境界）" => [ 0, 8_450, 550, 10_000, true ],
      "9,001（予約中 8,451 + 550）は不可（境界の 1 つ外）" => [ 0, 8_451, 550, 10_000, false ],
      "16 本目（予約中 8,250 + 550 = 8,800）は可" => [ 0, 8_250, 550, 10_000, true ],
      "17 本目（予約中 8,800 + 550 = 9,350）は不可" => [ 0, 8_800, 550, 10_000, false ],
      "使用済みと予約中の合計で判定する: 4,000 + 4,450 + 550 = 9,000 は可" => [ 4_000, 4_450, 550, 10_000, true ],
      "使用済みと予約中の合計で判定する: 4,001 + 4,450 + 550 = 9,001 は不可" => [ 4_001, 4_450, 550, 10_000, false ],
      "使用済みだけで 8,450（予約中なし）+ 550 = 9,000 は可" => [ 8_450, 0, 550, 10_000, true ],
      "使用済みだけで 8,451 + 550 = 9,001 は不可" => [ 8_451, 0, 550, 10_000, false ],
      "1 ユニットの予約: 8,999 + 1 = 9,000 は可" => [ 8_999, 0, 1, 10_000, true ],
      "1 ユニットの予約: 9,000 + 1 = 9,001 は不可" => [ 9_000, 0, 1, 10_000, false ],
      "1 日の割り当て 20,000（上限 19,000）: 18,450 + 550 = 19,000 は可" => [ 0, 18_450, 550, 20_000, true ],
      "1 日の割り当て 20,000（上限 19,000）: 18,451 + 550 は不可" => [ 0, 18_451, 550, 20_000, false ],
      "1 日の割り当て 9,999（上限 8,999）: 8,449 + 550 = 8,999 は可" => [ 0, 8_449, 550, 9_999, true ],
      "1 日の割り当て 9,999（上限 8,999）: 8,450 + 550 = 9,000 は不可" => [ 0, 8_450, 550, 9_999, false ],
      "1 日の割り当て 1,000（配信に使える上限が 0）: 1 ユニットも不可" => [ 0, 0, 1, 1_000, false ],
      "1 日の割り当て 1,550（上限 550）: 550 は可" => [ 0, 0, 550, 1_550, true ],
      "1 日の割り当て 1,549（上限 549）: 550 は不可" => [ 0, 0, 550, 1_549, false ]
    }.each do |label, (used, reserved, units, daily_total, expected)|
      it label do
        result = policy.can_reserve?(day(used: used, reserved: reserved), units: units, daily_total: daily_total)

        expect(result).to be(expected)
      end
    end

    it "共通枠の使用済み（配信に属さない呼び出し）は、判定に含めない（共通枠 500 は別に確保されている）" do
      expect(policy.can_reserve?(day(common: 500), units: 550, daily_total: 10_000)).to be(true)
      expect(policy.can_reserve?(day(reserved: 8_450, common: 500), units: 550, daily_total: 10_000)).to be(true)
      expect(policy.can_reserve?(day(reserved: 8_451, common: 0), units: 550, daily_total: 10_000)).to be(false)
    end

    it "割り当て超過が返った日（exhausted）は、空きがあっても予約できない（8.4: 当該割り当て日の終わりまで新規受付を停止する）" do
      expect(policy.can_reserve?(day(exhausted: true), units: 550, daily_total: 10_000)).to be(false)
      expect(policy.can_reserve?(day(exhausted: true), units: 1, daily_total: 20_000)).to be(false)
      expect(policy.can_reserve?(day(exhausted: false), units: 550, daily_total: 10_000)).to be(true)
    end

    it "判定は、割り当て日の日付に依らない" do
      expect(policy.can_reserve?(day(date: Date.new(2026, 3, 8), reserved: 8_450), units: 550, daily_total: 10_000)).to be(true)
      expect(policy.can_reserve?(day(date: Date.new(2026, 11, 1), reserved: 8_451), units: 550, daily_total: 10_000)).to be(false)
    end

    {
      "新規の予約が 0" => [ 0, 10_000 ],
      "新規の予約が負" => [ -1, 10_000 ],
      "新規の予約が Float" => [ 550.0, 10_000 ],
      "新規の予約が文字列" => [ "550", 10_000 ],
      "新規の予約が nil" => [ nil, 10_000 ],
      "1 日の割り当てが負" => [ 550, -1 ],
      "1 日の割り当てが Float" => [ 550, 10_000.0 ],
      "1 日の割り当てが文字列" => [ 550, "10000" ],
      "1 日の割り当てが nil" => [ 550, nil ]
    }.each do |label, (units, daily_total)|
      it "引数の検査: #{label}は ArgumentError" do
        expect { policy.can_reserve?(day, units: units, daily_total: daily_total) }.to raise_error(ArgumentError)
      end
    end

    it "引数の検査: 台帳が Day でないものは ArgumentError" do
      [ nil, {}, { used_units: 0 }, "day", 1 ].each do |invalid|
        expect { policy.can_reserve?(invalid, units: 550, daily_total: 10_000) }.to raise_error(ArgumentError, /day/)
      end
    end
  end

  describe ".reserve（受理時の予約の計上。予約中に 550 を足す）" do
    it "予約できるとき、予約中が 550 増えた台帳と、新しい予約（準備・確認 340・終了・清算 210）を返す" do
      before = day(used: 100, reserved: 550, common: 20)
      result = policy.reserve(before, daily_total: 10_000)

      expect(result).to be_a(QuotaPolicy::Booked)
      expect(result).to be_granted
      expect(result.day).to eq(day(used: 100, reserved: 1_100, common: 20))
      expect(result.reservation).to eq(reservation(date: date, prep: 340, settle: 210))
      expect(result.reservation.remaining_units).to eq(550)
    end

    it "元の台帳を変更しない（不変）" do
      before = day(reserved: 550)
      policy.reserve(before, daily_total: 10_000)

      expect(before).to eq(day(reserved: 550))
      expect(before).to be_frozen
    end

    it "ちょうど上限（予約中 8,450 + 550 = 9,000）に収まるときは、予約できる" do
      result = policy.reserve(day(reserved: 8_450), daily_total: 10_000)

      expect(result).to be_granted
      expect(result.day.reserved_units).to eq(9_000)
    end

    it "上限を超えるとき（8,451 + 550 = 9,001）は Refused（:ledger_full）。台帳は変わらない" do
      result = policy.reserve(day(reserved: 8_451), daily_total: 10_000)

      expect(result).to be_a(QuotaPolicy::Refused)
      expect(result).not_to be_granted
      expect(result.reason).to eq(:ledger_full)
    end

    it "割り当て超過が返った日（exhausted）は Refused（:day_exhausted）。台帳の空きによる拒否（:ledger_full）とは区別する" do
      result = policy.reserve(day(exhausted: true), daily_total: 10_000)

      expect(result).to be_a(QuotaPolicy::Refused)
      expect(result.reason).to eq(:day_exhausted)
      expect(policy.reserve(day(exhausted: true, reserved: 8_451), daily_total: 10_000).reason).to eq(:day_exhausted)
      expect(policy.reserve(day(reserved: 8_451), daily_total: 10_000).reason).to eq(:ledger_full)
    end

    it "予約した台帳は、割り当て超過の印を引き継ぐ（印のない日は、印のないまま）" do
      expect(policy.reserve(day, daily_total: 10_000).day.exhausted).to be(false)
    end

    it "17 本目の予約は拒否される（550 × 16 = 8,800。17 本目は 9,350 で不可）" do
      current = day
      results = Array.new(17) do
        outcome = policy.reserve(current, daily_total: 10_000)
        current = outcome.day if outcome.granted?
        outcome
      end

      expect(results.first(16)).to all(be_granted)
      expect(results.last).not_to be_granted
      expect(results.last.reason).to eq(:ledger_full)
      expect(current.reserved_units).to eq(8_800)
    end

    it "予約した割り当て日は、台帳の割り当て日" do
      result = policy.reserve(day(date: Date.new(2026, 3, 8)), daily_total: 10_000)

      expect(result.reservation.quota_date).to eq(Date.new(2026, 3, 8))
      expect(result.day.quota_date).to eq(Date.new(2026, 3, 8))
    end

    it "1 日の割り当てが大きいと、より多く予約できる（20,000 で 34 本。19,000 / 550 = 34.5）" do
      current = day
      count = 0
      loop do
        outcome = policy.reserve(current, daily_total: 20_000)
        break unless outcome.granted?

        current = outcome.day
        count += 1
      end

      expect(count).to eq(34)
    end

    it "引数の検査: 台帳が Day でない・1 日の割り当てが整数でない、は ArgumentError" do
      expect { policy.reserve(nil, daily_total: 10_000) }.to raise_error(ArgumentError)
      expect { policy.reserve(day, daily_total: nil) }.to raise_error(ArgumentError)
      expect { policy.reserve(day, daily_total: "10000") }.to raise_error(ArgumentError)
    end
  end

  describe ".spend（配信の予約の、該当する枠から支出する。実費を使用済みへ、同額を枠の予約から取り崩す）" do
    let(:booked) { policy.reserve(day, daily_total: 10_000) }
    let(:ledger) { booked.day }
    let(:held) { booked.reservation }

    it "準備・確認枠: 使用済みが増え、予約中と準備・確認枠の残額が同額減る。終了・清算枠は変わらない" do
      result = policy.spend(held, bucket: :prep, units: 50, day: ledger)

      expect(result).to be_a(QuotaPolicy::Booked)
      expect(result).to be_granted
      expect(result.day).to eq(day(used: 50, reserved: 500))
      expect(result.reservation).to eq(reservation(prep: 290, settle: 210))
    end

    it "終了・清算枠: 使用済みが増え、予約中と終了・清算枠の残額が同額減る。準備・確認枠は変わらない" do
      result = policy.spend(held, bucket: :settle, units: 51, day: ledger)

      expect(result).to be_granted
      expect(result.day).to eq(day(used: 51, reserved: 499))
      expect(result.reservation).to eq(reservation(prep: 340, settle: 159))
    end

    it "使用済み + 予約中は、支出の前後で変わらない（予約から使用済みへ移るだけ）" do
      result = policy.spend(held, bucket: :prep, units: 321, day: ledger)

      expect(result.day.used_units + result.day.reserved_units).to eq(ledger.used_units + ledger.reserved_units)
    end

    it "共通枠の使用済みは、配信の支出で変わらない" do
      with_common = ledger.with(common_used_units: 123)
      result = policy.spend(held, bucket: :prep, units: 1, day: with_common)

      expect(result.day.common_used_units).to eq(123)
    end

    it "準備・確認枠の残額ちょうど（340）まで支出できる。残額 0 になる" do
      result = policy.spend(held, bucket: :prep, units: 340, day: ledger)

      expect(result).to be_granted
      expect(result.reservation.prep_remaining_units).to eq(0)
      expect(result.reservation.settle_remaining_units).to eq(210)
      expect(result.day).to eq(day(used: 340, reserved: 210))
    end

    it "準備・確認枠の残額を 1 超える（341）支出は Refused（:bucket_insufficient）。終了・清算枠から取り崩さない" do
      result = policy.spend(held, bucket: :prep, units: 341, day: ledger)

      expect(result).to be_a(QuotaPolicy::Refused)
      expect(result.reason).to eq(:bucket_insufficient)
    end

    it "終了・清算枠の残額ちょうど（210）まで支出できる" do
      result = policy.spend(held, bucket: :settle, units: 210, day: ledger)

      expect(result).to be_granted
      expect(result.reservation.settle_remaining_units).to eq(0)
      expect(result.reservation.prep_remaining_units).to eq(340)
    end

    it "終了・清算枠の残額を 1 超える（211）支出は Refused。準備・確認枠から取り崩さない" do
      result = policy.spend(held, bucket: :settle, units: 211, day: ledger)

      expect(result).not_to be_granted
      expect(result.reason).to eq(:bucket_insufficient)
    end

    it "準備・確認の支出が 340 を超えても、終了・清算枠の残額は減らない（不足なら不可）" do
      current_day = ledger
      current = held
      # 準備・確認枠を、100 ずつ 3 回（300）使う
      3.times do
        outcome = policy.spend(current, bucket: :prep, units: 100, day: current_day)
        expect(outcome).to be_granted
        current_day = outcome.day
        current = outcome.reservation
      end
      expect(current.prep_remaining_units).to eq(40)

      over = policy.spend(current, bucket: :prep, units: 41, day: current_day)
      expect(over).not_to be_granted

      rest = policy.spend(current, bucket: :prep, units: 40, day: current_day)
      expect(rest).to be_granted
      current_day = rest.day
      current = rest.reservation

      again = policy.spend(current, bucket: :prep, units: 1, day: current_day)
      expect(again).not_to be_granted
      expect(again.reason).to eq(:bucket_insufficient)
      # 終了・清算枠は、まるごと残っていて、終了・清算の用途（:settle）で使える
      expect(current.settle_remaining_units).to eq(210)
      expect(current_day.reserved_units).to eq(210)
      expect(policy.spend(current, bucket: :settle, units: 210, day: current_day)).to be_granted
    end

    it "支出できなかったとき、台帳も予約も変わらない（Refused は理由だけを持つ）" do
      result = policy.spend(held, bucket: :prep, units: 341, day: ledger)

      expect(result.to_h).to eq(reason: :bucket_insufficient)
      expect(ledger).to eq(day(reserved: 550))
      expect(held).to eq(reservation)
    end

    it "元の台帳・予約を変更しない（不変）" do
      policy.spend(held, bucket: :prep, units: 10, day: ledger)

      expect(ledger).to eq(day(reserved: 550))
      expect(held).to eq(reservation)
      expect([ ledger, held ]).to all(be_frozen)
    end

    it "ほかの配信の予約中を含む台帳でも、自分の予約の分だけを動かす" do
      crowded = day(used: 1_000, reserved: 2_200)
      mine = reservation(prep: 300, settle: 210)
      result = policy.spend(mine, bucket: :prep, units: 50, day: crowded)

      expect(result.day).to eq(day(used: 1_050, reserved: 2_150))
      expect(result.reservation).to eq(reservation(prep: 250, settle: 210))
    end

    it "割り当て超過が返った日（exhausted）でも、進行中の配信の支出は記帳できる（印は変わらない）" do
      exhausted = day(reserved: 550, exhausted: true)
      result = policy.spend(held, bucket: :settle, units: 51, day: exhausted)

      expect(result).to be_granted
      expect(result.day).to eq(day(used: 51, reserved: 499, exhausted: true))
    end

    it "割り当て日が、予約と台帳で違うときは、DayMismatch（先に carry_over で移し替える）" do
      expect { policy.spend(held, bucket: :prep, units: 1, day: day(date: next_date, reserved: 550)) }
        .to raise_error(QuotaPolicy::DayMismatch) { |error|
          expect(error).to be_a(ArgumentError)
          expect(error.message).to include("carry_over")
        }
    end

    it "台帳の予約中が、この予約の残額より少ないときは、InconsistentLedger（支出が可否にかかわらず、台帳の不整合を報告する）" do
      broken = day(reserved: 549)

      expect { policy.spend(held, bucket: :prep, units: 1, day: broken) }.to raise_error(QuotaPolicy::InconsistentLedger)
      expect { policy.spend(held, bucket: :prep, units: 9_999, day: broken) }.to raise_error(QuotaPolicy::InconsistentLedger)
    end

    {
      "枠が未知のシンボル" => [ :other, 1 ],
      "枠が文字列" => [ "prep", 1 ],
      "枠が nil" => [ nil, 1 ],
      "支出が 0" => [ :prep, 0 ],
      "支出が負" => [ :prep, -1 ],
      "支出が Float" => [ :prep, 1.0 ],
      "支出が文字列" => [ :prep, "1" ],
      "支出が nil" => [ :prep, nil ]
    }.each do |label, (bucket, units)|
      it "引数の検査: #{label}は ArgumentError" do
        expect { policy.spend(held, bucket: bucket, units: units, day: ledger) }.to raise_error(ArgumentError)
      end
    end

    it "引数の検査: 予約が Reservation でない・台帳が Day でないものは ArgumentError" do
      expect { policy.spend(nil, bucket: :prep, units: 1, day: ledger) }.to raise_error(ArgumentError, /reservation/)
      expect { policy.spend(held, bucket: :prep, units: 1, day: nil) }.to raise_error(ArgumentError, /day/)
      expect { policy.spend({}, bucket: :prep, units: 1, day: ledger) }.to raise_error(ArgumentError, /reservation/)
    end
  end

  describe ".spend_common（配信に属さない呼び出し。共通枠 500 から支出する）" do
    it "共通枠の使用済みが増える。配信の使用済み・予約中は変わらない。予約は持たない（nil）" do
      result = policy.spend_common(day(used: 100, reserved: 550, common: 20), units: 1)

      expect(result).to be_a(QuotaPolicy::Booked)
      expect(result).to be_granted
      expect(result.day).to eq(day(used: 100, reserved: 550, common: 21))
      expect(result.reservation).to be_nil
    end

    it "共通枠の残額ちょうど（500）まで支出できる" do
      result = policy.spend_common(day, units: 500)

      expect(result).to be_granted
      expect(result.day.common_used_units).to eq(500)
    end

    it "共通枠の残額を 1 超える（501）支出は Refused（:common_exhausted）" do
      result = policy.spend_common(day, units: 501)

      expect(result).to be_a(QuotaPolicy::Refused)
      expect(result.reason).to eq(:common_exhausted)
    end

    it "499 使用済みのとき、1 は可、2 は不可（一部だけの支出はしない）" do
      expect(policy.spend_common(day(common: 499), units: 1)).to be_granted
      expect(policy.spend_common(day(common: 499), units: 2)).not_to be_granted
    end

    it "共通枠が尽きた（500）あとは、1 ユニットも支出できない（割り当て日の終わりまで）" do
      exhausted = day(common: 500)

      expect(policy.spend_common(exhausted, units: 1).reason).to eq(:common_exhausted)
      expect(policy.spend_common(exhausted, units: 500).reason).to eq(:common_exhausted)
    end

    it "1 ユニットずつ 500 回の支出で尽き、501 回目が拒否される" do
      current = day
      granted = 0
      501.times do
        outcome = policy.spend_common(current, units: 1)
        next unless outcome.granted?

        current = outcome.day
        granted += 1
      end

      expect(granted).to eq(500)
      expect(current.common_used_units).to eq(500)
    end

    it "共通枠は、配信の予約・使用済みと独立している（共通枠が尽きても、配信の予約はできる）" do
      exhausted = policy.spend_common(day, units: 500).day

      expect(policy.reserve(exhausted, daily_total: 10_000)).to be_granted
    end

    it "元の台帳を変更しない（不変）" do
      before = day(common: 10)
      policy.spend_common(before, units: 5)

      expect(before).to eq(day(common: 10))
    end

    it "割り当て超過の印は、共通枠の支出で変わらない" do
      expect(policy.spend_common(day(exhausted: true), units: 1).day.exhausted).to be(true)
    end

    it "引数の検査: 支出が整数でない・0 以下、台帳が Day でないものは ArgumentError" do
      [ 0, -1, 1.5, "1", nil ].each do |units|
        expect { policy.spend_common(day, units: units) }.to raise_error(ArgumentError)
      end
      expect { policy.spend_common(nil, units: 1) }.to raise_error(ArgumentError)
    end
  end

  describe ".carry_over（割り当て日をまたいだ配信の予約の残額を、新しい割り当て日へ移す）" do
    let(:held) { reservation(prep: 100, settle: 210) }
    let(:from_day) { day(used: 240, reserved: 860, common: 5) }
    let(:to_day) { day(date: Date.new(2026, 10, 7), used: 50, reserved: 1_000, common: 7) }

    it "元の割り当て日の予約中から残額を引き、新しい割り当て日の予約中へ足し、予約の割り当て日を更新する" do
      result = policy.carry_over(held, from: from_day, to: to_day)

      expect(result).to be_a(QuotaPolicy::Carried)
      expect(result.from).to eq(day(used: 240, reserved: 550, common: 5))
      expect(result.to).to eq(day(date: Date.new(2026, 10, 7), used: 50, reserved: 1_310, common: 7))
      expect(result.reservation).to eq(reservation(date: Date.new(2026, 10, 7), prep: 100, settle: 210))
    end

    it "使用済みと共通枠は、移さない（支出した日のまま）" do
      result = policy.carry_over(held, from: from_day, to: to_day)

      expect(result.from.used_units).to eq(from_day.used_units)
      expect(result.from.common_used_units).to eq(from_day.common_used_units)
      expect(result.to.used_units).to eq(to_day.used_units)
      expect(result.to.common_used_units).to eq(to_day.common_used_units)
    end

    it "予約中の合計（2 日分）は、移し替えの前後で変わらない" do
      result = policy.carry_over(held, from: from_day, to: to_day)

      expect(result.from.reserved_units + result.to.reserved_units).to eq(from_day.reserved_units + to_day.reserved_units)
    end

    it "移し替えの後、新しい割り当て日の台帳で支出できる。元の割り当て日の台帳では DayMismatch" do
      result = policy.carry_over(held, from: from_day, to: to_day)

      expect(policy.spend(result.reservation, bucket: :prep, units: 50, day: result.to)).to be_granted
      expect { policy.spend(result.reservation, bucket: :prep, units: 50, day: result.from) }.to raise_error(QuotaPolicy::DayMismatch)
    end

    it "移し替えは、新しい割り当て日の空きを検査しない（進行中の配信の清算に必要な額を取り上げない）。新規の予約は、そのあと拒否される" do
      full = day(date: Date.new(2026, 10, 7), reserved: 9_000)
      result = policy.carry_over(held, from: from_day, to: full)

      expect(result.to.reserved_units).to eq(9_310)
      expect(policy.can_reserve?(result.to, units: 550, daily_total: 10_000)).to be(false)
    end

    it "残額が 0 の予約（解放済み）も移し替えられる（予約中は変わらず、割り当て日だけが更新される）" do
      empty = reservation(prep: 0, settle: 0)
      result = policy.carry_over(empty, from: day(reserved: 500), to: to_day)

      expect(result.from.reserved_units).to eq(500)
      expect(result.to.reserved_units).to eq(1_000)
      expect(result.reservation.quota_date).to eq(Date.new(2026, 10, 7))
    end

    it "2 日以上あとの割り当て日へも移せる" do
      result = policy.carry_over(held, from: from_day, to: day(date: Date.new(2026, 10, 9)))

      expect(result.reservation.quota_date).to eq(Date.new(2026, 10, 9))
    end

    it "元の台帳・予約を変更しない（不変）" do
      policy.carry_over(held, from: from_day, to: to_day)

      expect(from_day).to eq(day(used: 240, reserved: 860, common: 5))
      expect(held).to eq(reservation(prep: 100, settle: 210))
    end

    it "割り当て超過の印は、それぞれの割り当て日の台帳のまま（移し替えで、日をまたいで引き継がない）" do
      result = policy.carry_over(held, from: day(reserved: 860, exhausted: true), to: to_day)

      expect(result.from.exhausted).to be(true)
      expect(result.to.exhausted).to be(false)
    end

    it "予約の割り当て日が、元の台帳と違うときは DayMismatch" do
      expect { policy.carry_over(reservation(date: next_date), from: from_day, to: to_day) }.to raise_error(QuotaPolicy::DayMismatch)
    end

    it "新しい割り当て日が、元の割り当て日より後でないとき（同じ日・前の日）は ArgumentError（逆戻りしない）" do
      expect { policy.carry_over(held, from: from_day, to: day(date: date, reserved: 100)) }.to raise_error(ArgumentError, /later/)
      expect { policy.carry_over(held, from: from_day, to: day(date: Date.new(2026, 10, 5))) }.to raise_error(ArgumentError, /later/)
    end

    it "元の台帳の予約中が、予約の残額より少ないときは InconsistentLedger" do
      expect { policy.carry_over(held, from: day(reserved: 309), to: to_day) }.to raise_error(QuotaPolicy::InconsistentLedger)
    end

    it "引数の検査: 型が違うものは ArgumentError" do
      expect { policy.carry_over(nil, from: from_day, to: to_day) }.to raise_error(ArgumentError, /reservation/)
      expect { policy.carry_over(held, from: nil, to: to_day) }.to raise_error(ArgumentError, /from/)
      expect { policy.carry_over(held, from: from_day, to: nil) }.to raise_error(ArgumentError, /to/)
    end
  end

  describe ".release（清算が終端に達した時点で、予約の残額を解放する）" do
    it "台帳の予約中から、予約の残額を引く。予約は空（0・0）になる。使用済みは変わらない" do
      held = reservation(prep: 19, settle: 6)
      result = policy.release(held, day: day(used: 8_400, reserved: 1_125))

      expect(result).to be_a(QuotaPolicy::Booked)
      expect(result).to be_granted
      expect(result.day).to eq(day(used: 8_400, reserved: 1_100))
      expect(result.reservation).to eq(reservation(prep: 0, settle: 0))
    end

    it "冪等: 解放済みの予約をもう一度解放しても、台帳は変わらない" do
      first = policy.release(reservation(prep: 19, settle: 6), day: day(reserved: 25))
      second = policy.release(first.reservation, day: first.day)

      expect(first.day.reserved_units).to eq(0)
      expect(second.day).to eq(first.day)
      expect(second.reservation).to eq(first.reservation)
    end

    it "解放すると、新しい予約の余地が戻る（16 本で満杯 → 1 本解放 → 17 本目が入る）" do
      current = day
      reservations = Array.new(16) do
        outcome = policy.reserve(current, daily_total: 10_000)
        current = outcome.day
        outcome.reservation
      end
      expect(policy.reserve(current, daily_total: 10_000)).not_to be_granted

      released = policy.release(reservations.first, day: current)

      expect(policy.reserve(released.day, daily_total: 10_000)).to be_granted
    end

    it "使った分は、解放しても戻らない（使用済みに残る）" do
      booked = policy.reserve(day, daily_total: 10_000)
      spent = policy.spend(booked.reservation, bucket: :prep, units: 321, day: booked.day)
      released = policy.release(spent.reservation, day: spent.day)

      expect(released.day).to eq(day(used: 321, reserved: 0))
    end

    it "元の台帳・予約を変更しない（不変）" do
      held = reservation(prep: 19, settle: 6)
      ledger = day(reserved: 25)
      policy.release(held, day: ledger)

      expect(held).to eq(reservation(prep: 19, settle: 6))
      expect(ledger).to eq(day(reserved: 25))
    end

    it "割り当て超過の日の解放も、予約中から引く（印は変わらない）" do
      result = policy.release(reservation(prep: 19, settle: 6), day: day(reserved: 25, exhausted: true))

      expect(result.day).to eq(day(reserved: 0, exhausted: true))
    end

    it "予約の割り当て日が、台帳と違うときは DayMismatch" do
      expect { policy.release(reservation(date: next_date), day: day(reserved: 550)) }.to raise_error(QuotaPolicy::DayMismatch)
    end

    it "台帳の予約中が、予約の残額より少ないときは InconsistentLedger（予約中を負にしない）" do
      expect { policy.release(reservation, day: day(reserved: 549)) }.to raise_error(QuotaPolicy::InconsistentLedger)
    end

    it "引数の検査: 型が違うものは ArgumentError" do
      expect { policy.release(nil, day: day) }.to raise_error(ArgumentError, /reservation/)
      expect { policy.release(reservation, day: nil) }.to raise_error(ArgumentError, /day/)
    end
  end

  describe "値オブジェクト（Day・Reservation・結果）" do
    it "Day・Reservation・Booked・Refused・Carried は凍結されている" do
      booked = policy.reserve(day, daily_total: 10_000)
      refused = policy.reserve(day(reserved: 9_000), daily_total: 10_000)
      carried = policy.carry_over(reservation, from: day(reserved: 550), to: day(date: next_date))

      expect([ day, reservation, booked, refused, carried ]).to all(be_frozen)
    end

    it "Day: 割り当て日は Date、ほかは 0 以上の整数。違反は ArgumentError" do
      expect { day.with(quota_date: "2026-10-06") }.to raise_error(ArgumentError, /quota_date/)
      expect { day.with(quota_date: Time.utc(2026, 10, 6)) }.to raise_error(ArgumentError, /quota_date/)
      expect { day.with(quota_date: DateTime.new(2026, 10, 6)) }.to raise_error(ArgumentError, /quota_date/)
      expect { day.with(used_units: -1) }.to raise_error(ArgumentError, /used_units/)
      expect { day.with(reserved_units: -1) }.to raise_error(ArgumentError, /reserved_units/)
      expect { day.with(common_used_units: -1) }.to raise_error(ArgumentError, /common_used_units/)
      expect { day.with(used_units: 1.5) }.to raise_error(ArgumentError, /used_units/)
      expect { day.with(reserved_units: nil) }.to raise_error(ArgumentError, /reserved_units/)
      expect { day.with(common_used_units: "0") }.to raise_error(ArgumentError, /common_used_units/)
    end

    it "Day: 割り当て超過の印（exhausted）は、既定が false で、true・false だけ。それ以外は ArgumentError" do
      expect(QuotaPolicy::Day.new(quota_date: date, used_units: 0, reserved_units: 0, common_used_units: 0).exhausted).to be(false)
      expect(QuotaPolicy::Day.new(date, 1, 2, 3).exhausted).to be(false)
      expect(day(exhausted: true).exhausted).to be(true)
      [ nil, "true", 1, 0, :true ].each do |invalid|
        expect { day.with(exhausted: invalid) }.to raise_error(ArgumentError, /exhausted/)
      end
    end

    it "Reservation: 割り当て日は Date、残額は 0 以上の整数。違反は ArgumentError" do
      expect { reservation.with(quota_date: nil) }.to raise_error(ArgumentError, /quota_date/)
      expect { reservation.with(prep_remaining_units: -1) }.to raise_error(ArgumentError, /prep_remaining_units/)
      expect { reservation.with(settle_remaining_units: -1) }.to raise_error(ArgumentError, /settle_remaining_units/)
      expect { reservation.with(prep_remaining_units: 1.0) }.to raise_error(ArgumentError, /prep_remaining_units/)
      expect { reservation.with(settle_remaining_units: "210") }.to raise_error(ArgumentError, /settle_remaining_units/)
    end

    it "Reservation: 残額の合計と、枠ごとの残額" do
      held = reservation(prep: 100, settle: 7)

      expect(held.remaining_units).to eq(107)
      expect(held.remaining(:prep)).to eq(100)
      expect(held.remaining(:settle)).to eq(7)
      expect { held.remaining(:other) }.to raise_error(ArgumentError, /bucket/)
    end

    it "Booked は granted? が true、Refused は false。Refused の理由は 4 種類だけ" do
      expect(QuotaPolicy::Booked.new(day: day, reservation: nil)).to be_granted
      expect(QuotaPolicy::Refused.new(reason: :ledger_full)).not_to be_granted
      %i[ledger_full day_exhausted bucket_insufficient common_exhausted].each do |reason|
        expect(QuotaPolicy::Refused.new(reason: reason).reason).to eq(reason)
      end
      expect { QuotaPolicy::Refused.new(reason: :unknown) }.to raise_error(ArgumentError, /reason/)
      expect { QuotaPolicy::Refused.new(reason: "ledger_full") }.to raise_error(ArgumentError, /reason/)
    end

    it "エラーの種類: DayMismatch は ArgumentError、InconsistentLedger は StandardError（呼び出し側の誤りか、台帳の破損か）" do
      expect(QuotaPolicy::DayMismatch.ancestors).to include(ArgumentError)
      expect(QuotaPolicy::InconsistentLedger.ancestors).to include(StandardError)
      expect(QuotaPolicy::InconsistentLedger.ancestors).not_to include(ArgumentError)
    end
  end

  describe "実時計・環境に依存しない（同じ入力に同じ出力）" do
    it "Time.now・Date.today が失敗する状態でも動き、何度呼んでも同じ結果" do
      allow(Time).to receive(:now).and_raise("Time.now must not be called")
      allow(Date).to receive(:today).and_raise("Date.today must not be called")
      ledger = day(used: 10, reserved: 550)

      first = policy.reserve(ledger, daily_total: 10_000)
      second = policy.reserve(ledger, daily_total: 10_000)

      expect(second).to eq(first)
    end
  end
end
