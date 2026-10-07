require "spec_helper"
require_relative "support/domain_loader"

# 転送量の判定（requirements.md 8.3・15 章「転送量の判定」）。
# 入力は、当月の送出量の積算（バイト）と、予算（GB）。積算が予算に達した月は、新規の受付を受理しない。
#
# 1 GB = 1,000,000,000 バイト（10 の 9 乗。十進の GB）として扱う。requirements.md は、GB の定義を置いていないため、
# この解釈を置く（2 進の GiB = 1,073,741,824 バイトとすると、同じ「10 GB」でも、約 0.74 GB 多く送れてしまい、
# 無料枠の予算（29.2）を守る側ではなくなる。十進は、先に受付を止める安全側の解釈）。
RSpec.describe "転送量の判定（TransferBudgetPolicy）" do
  let(:policy) { TransferBudgetPolicy }

  it "1 GB は 1,000,000,000 バイト（十進）" do
    expect(policy::BYTES_PER_GB).to eq(1_000_000_000)
  end

  describe ".exceeded?（積算が予算に達した月は不可。達した = 以上）" do
    {
      "積算 0・予算 10 GB は、まだ" => [ 0, 10, false ],
      "予算の 1 バイト手前（9,999,999,999 バイト）は、まだ" => [ 9_999_999_999, 10, false ],
      "予算にちょうど達した（10,000,000,000 バイト）は、不可（達した月は不可）" => [ 10_000_000_000, 10, true ],
      "予算を 1 バイト超えた（10,000,000,001 バイト）は、不可" => [ 10_000_000_001, 10, true ],
      "予算を大きく超えた（10 倍）は、不可" => [ 100_000_000_000, 10, true ],
      "1 GB の予算の 1 バイト手前（999,999,999 バイト）は、まだ" => [ 999_999_999, 1, false ],
      "1 GB の予算にちょうど達した（1,000,000,000 バイト）は、不可" => [ 1_000_000_000, 1, true ],
      "2 進の 1 GiB（1,073,741,824 バイト）は、1 GB の予算を超えている" => [ 1_073_741_824, 1, true ],
      "予算 0 GB は、積算 0 でも不可（達している）" => [ 0, 0, true ],
      "予算 0 GB・積算 1 バイトは、不可" => [ 1, 0, true ],
      "巨大な積算（Integer の上限を超える値）も、桁あふれせず判定できる" => [ 10**30, 10, true ],
      "巨大な予算でも、積算 0 はまだ" => [ 0, 2_147_483_647, false ],
      "巨大な予算の 1 バイト手前は、まだ" => [ (2_147_483_647 * 1_000_000_000) - 1, 2_147_483_647, false ],
      "巨大な予算にちょうど達した" => [ 2_147_483_647 * 1_000_000_000, 2_147_483_647, true ]
    }.each do |label, (sent_bytes, budget_gb, expected)|
      it label do
        expect(policy.exceeded?(sent_bytes: sent_bytes, budget_gb: budget_gb)).to be(expected)
      end
    end

    it "戻り値は、真偽値（true・false）で、nil ではない" do
      expect([ policy.exceeded?(sent_bytes: 0, budget_gb: 10), policy.exceeded?(sent_bytes: 10_000_000_000, budget_gb: 10) ]).to eq([ false, true ])
    end

    it "単調: 積算が増えると、不可から可には戻らない（積算の 1 億バイト刻み）" do
      results = (0..120).map { |step| policy.exceeded?(sent_bytes: step * 100_000_000, budget_gb: 10) }

      expect(results.index(true)).to eq(100)
      expect(results.drop(100)).to all(be(true))
      expect(results.take(100)).to all(be(false))
    end

    it "設定の既定値（月 10 GB）を、Settings から渡せる" do
      budget = Settings.defaults.monthly_transfer_budget_gb

      expect(policy.exceeded?(sent_bytes: (budget * 1_000_000_000) - 1, budget_gb: budget)).to be(false)
      expect(policy.exceeded?(sent_bytes: budget * 1_000_000_000, budget_gb: budget)).to be(true)
    end
  end

  describe "引数の検査（黙って変換しない）" do
    {
      "積算が負" => [ -1, 10 ],
      "積算が Float" => [ 1.5, 10 ],
      "積算が文字列" => [ "100", 10 ],
      "積算が nil" => [ nil, 10 ],
      "積算が true" => [ true, 10 ],
      "予算が負" => [ 0, -1 ],
      "予算が Float" => [ 0, 10.0 ],
      "予算が文字列" => [ 0, "10" ],
      "予算が nil" => [ 0, nil ],
      "予算が false" => [ 0, false ]
    }.each do |label, (sent_bytes, budget_gb)|
      it "#{label}は ArgumentError" do
        expect { policy.exceeded?(sent_bytes: sent_bytes, budget_gb: budget_gb) }.to raise_error(ArgumentError)
      end
    end

    it "キーワード引数の不足は ArgumentError（既定値で補わない）" do
      expect { policy.exceeded?(sent_bytes: 0) }.to raise_error(ArgumentError)
      expect { policy.exceeded?(budget_gb: 10) }.to raise_error(ArgumentError)
    end
  end
end
