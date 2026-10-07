require "rails_helper"
require "support/model_support"
require "services/support/ledger_support"

# 送信転送量（requirements.md 8.3・27 章「整合性」）と設定値の、同時の操作と、途中で失敗したときの取り消し。
# 中継の送出量の報告は、2 秒ごとに、複数の配信から同時に届く。加算が失われない（積算が、報告の合計と一致する）ことを、
# 1 つの upsert 文（月次）と、配信の行の FOR UPDATE（配信の sent_bytes）で保証する。
#
# 別の接続からは、未コミットの行が見えない。このグループは、トランザクションで包まず、実際にコミットする。
# 例が作った行は、各例の前後で、SQL で整理する。
RSpec.describe "送信転送量・設定値の同時の操作" do
  include LedgerSupport

  self.use_transactional_tests = false

  # 他の例と重ならない暦月（未来の月）
  let(:month) { "2031-05" }
  let(:time_in_month) { Time.utc(2031, 5, 15, 3, 0, 0) }
  let(:setting_keys) { %w[ daily_allowance attempt_limit concurrent_limit ] }

  before { clean_committed_rows!(months: [ month ], setting_keys: setting_keys) }
  after { clean_committed_rows!(months: [ month ], setting_keys: setting_keys) }

  def committed_broadcast(**attributes)
    user = create_tracked_user
    usage = create(:daily_usage, user: user)
    create(:broadcast, user: user, daily_usage: usage, **attributes)
  end

  describe "TransferBudget.add!（月次の積算）" do
    it "行の無い月への、同時の最初の加算が重なっても、行は 1 件で、積算が、加算の合計と一致する" do
      results = run_threads(concurrent_width) { |index| TransferBudget.add!(month_key: month, bytes: 1_000 * (index + 1)) }

      expect(results.map(&:first)).to all(eq(:ok))
      expect(TransferMonth.where(month: month).count).to eq(1)
      expect(TransferMonth.find(month).sent_bytes).to eq(1_000 * (1..concurrent_width).sum)
    end

    it "同時の加算が、1 つも失われない（積算が、報告の合計と一致する。読んでから書く 2 段なら、失われる）" do
      results = run_in_waves(40) { |index| TransferBudget.add!(month_key: month, bytes: index + 1) }

      expect(results.map(&:first)).to all(eq(:ok))
      expect(TransferMonth.find(month).sent_bytes).to eq((1..40).sum)
      # 戻り値（加算後の積算）は、すべて異なり、最後のものが合計に一致する（各加算が、直列に反映された）
      returned = results.map(&:last)
      expect(returned.uniq.size).to eq(40)
      expect(returned.max).to eq((1..40).sum)
    end

    it "加算と判定（exceeded?）が同時に重なっても、判定は、積算の途中の値を、一貫して読む（例外にならない）" do
      settings = Settings.defaults.with(monthly_transfer_budget_gb: 1)

      results = run_in_waves(24) do |index|
        index.even? ? TransferBudget.add!(month_key: month, bytes: 100_000_000) : TransferBudget.exceeded?(month_key: month, settings: settings)
      end

      expect(results.map(&:first)).to all(eq(:ok))
      expect(TransferMonth.find(month).sent_bytes).to eq(12 * 100_000_000)
      expect(TransferBudget.exceeded?(month_key: month, settings: settings)).to be(true)
    end
  end

  describe "TransferBudget.add_for_broadcast!（配信の sent_bytes と月次の積算）" do
    it "同じ配信への同時の報告が、1 つも失われない（配信の sent_bytes も、月次の積算も、報告の合計と一致する）" do
      broadcast = committed_broadcast(sent_bytes: 500)

      results = run_in_waves(20) do |index|
        TransferBudget.add_for_broadcast!(Broadcast.find(broadcast.id), delta_bytes: 100 + index, now: time_in_month)
      end

      expect(results.map(&:first)).to all(eq(:ok))
      total = (0...20).sum { |index| 100 + index }
      expect(Broadcast.find(broadcast.id).sent_bytes).to eq(500 + total)
      expect(TransferMonth.find(month).sent_bytes).to eq(total)
    end

    it "別々の配信の同時の報告も、月次の積算は、全配信の合計と一致する。配信ごとの値は、混ざらない" do
      broadcasts = Array.new(concurrent_width) { committed_broadcast }

      results = run_in_waves(concurrent_width * 5) do |index|
        TransferBudget.add_for_broadcast!(Broadcast.find(broadcasts[index % broadcasts.size].id), delta_bytes: 10 * (index % broadcasts.size + 1), now: time_in_month)
      end

      expect(results.map(&:first)).to all(eq(:ok))
      broadcasts.each_with_index do |broadcast, position|
        expect(Broadcast.find(broadcast.id).sent_bytes).to eq(5 * 10 * (position + 1))
      end
      expect(TransferMonth.find(month).sent_bytes).to eq(Broadcast.where(id: broadcasts.map(&:id)).sum(:sent_bytes))
    end

    # 途中で失敗したら、すべて取り消される。サービスが開いたトランザクションが、月次の積算の失敗で、配信の加算も巻き戻すこと
    it "月次の積算の加算が失敗したら、配信の sent_bytes の加算も、取り消される（同一のトランザクション）" do
      broadcast = committed_broadcast(sent_bytes: 500)
      allow(TransferBudget).to receive(:add!).and_raise(RuntimeError, "forced failure")

      expect do
        TransferBudget.add_for_broadcast!(Broadcast.find(broadcast.id), delta_bytes: 100, now: time_in_month)
      end.to raise_error(RuntimeError, "forced failure")

      expect(Broadcast.find(broadcast.id).sent_bytes).to eq(500)
      expect(TransferMonth.where(month: month).count).to eq(0)
    end
  end

  describe "SettingsStore.update!（設定値の upsert）" do
    it "同じキーへの同時の更新が重なっても、行は 1 件（一意制約と競合しない）で、いずれかの値になる" do
      results = run_threads(concurrent_width) { |index| SettingsStore.update!(key: "daily_allowance", value: index + 1) }

      expect(results.map(&:first)).to all(eq(:ok))
      expect(SystemSetting.where(key: "daily_allowance").count).to eq(1)
      expect((1..concurrent_width).map(&:to_s)).to include(SystemSetting.find("daily_allowance").value)
      expect(SettingsStore.current.daily_allowance).to be_between(1, concurrent_width)
    end

    it "別々のキーへの同時の更新は、すべて反映される" do
      updates = { "daily_allowance" => 7, "attempt_limit" => 8, "concurrent_limit" => 9 }

      results = run_threads(updates.size) { |index| SettingsStore.update!(key: updates.keys.fetch(index), value: updates.values.fetch(index)) }

      expect(results.map(&:first)).to all(eq(:ok))
      expect(SettingsStore.current).to have_attributes(daily_allowance: 7, attempt_limit: 8, concurrent_limit: 9)
    end

    it "更新は、次の current に、すぐ反映される（別の接続から読んでも。キャッシュしない）" do
      SettingsStore.update!(key: "daily_allowance", value: 4)

      results = run_threads(2) { SettingsStore.current.daily_allowance }

      expect(results.map(&:last)).to all(eq(4))
    end
  end
end
