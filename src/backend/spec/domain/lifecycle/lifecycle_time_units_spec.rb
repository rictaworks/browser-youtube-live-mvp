require "spec_helper"
require_relative "../support/domain_loader"

# 単位の換算（分・日 → 秒）。期限・間隔・保持期間の数値（90 秒・30 日など）は、契約（limits.json）から取り、
# 規則のコードに数値を直書きしない。換算の係数だけを、ここに 1 か所で持つ（lifecycle_purity_spec が、ほかのファイルの数値の直書きを検知する）。
RSpec.describe "単位の換算（LifecycleTimeUnits）" do
  it "1 分は 60 秒、1 日は 86,400 秒" do
    expect(LifecycleTimeUnits::SECONDS_PER_MINUTE).to eq(60)
    expect(LifecycleTimeUnits::SECONDS_PER_DAY).to eq(86_400)
    expect(LifecycleTimeUnits::SECONDS_PER_DAY).to eq(LifecycleTimeUnits::SECONDS_PER_MINUTE * 60 * 24)
  end

  it "定数は整数" do
    expect(LifecycleTimeUnits.constants.map { |name| LifecycleTimeUnits.const_get(name) }).to all(be_an(Integer))
  end
end
