# frozen_string_literal: true

# 転送量の判定（requirements.md 8.3・15 章「転送量の判定」）。
#
# 入力は、当月（JST の暦月）の送出量の積算（バイト）と、予算（GB）。積算が予算に達した月は、新規の受付を受理しない
# （進行中の配信は継続するため、積算は、受付の判定後に進行中の配信が送出する分だけ、予算を上回り得る）。
#
# 1 GB = 1,000,000,000 バイト（10 の 9 乗。十進の GB）として扱う。requirements.md は、GB の定義を置いていないため、
# この解釈を置く。2 進の GiB（1,073,741,824 バイト）とすると、同じ「10 GB」でも、約 0.74 GB 多く送れてしまい、
# 無料枠の予算（29.2）を守る側ではなくなる。十進は、先に受付を止める安全側の解釈である。
module TransferBudgetPolicy
  BYTES_PER_GB = 1_000_000_000

  class << self
    # 積算が予算に達した（以上）なら true（受付できない）。
    # sent_bytes・budget_gb は、0 以上の整数。型違い・負の値は ArgumentError（黙って変換しない）。
    def exceeded?(sent_bytes:, budget_gb:)
      Preconditions.integer!(sent_bytes, "sent_bytes", min: 0)
      Preconditions.integer!(budget_gb, "budget_gb", min: 0)

      sent_bytes >= budget_gb * BYTES_PER_GB
    end
  end
end
