# 送信転送量（requirements.md 8.3・15 章「転送量の判定」・20.1 の transfer_months）。
#
# 月次の送信転送量の予算は、無料枠の利用枠を配信の転送量が使い切ることを防ぐための上限（29.2）。
# 中継が報告する送出量を、暦月（JST の暦月。利用日の 03:00 区切りではなく 00:00 区切り）ごとに積算し、
# 積算が予算に達した月は、新規の受付を受理しない（進行中の配信は継続するため、積算は予算を上回り得る）。
#
# 判定の規則（1 GB = 10 億バイト。積算が予算以上なら不可）は、Domain Core の TransferBudgetPolicy（#5）。
# このサービスは、DB への原子的な加算と読み取りを行う。
#
#   add!                  transfer_months の月の行を、1 つの upsert 文で、原子的に加算する（行が無ければ作る）
#   sent_bytes            月の積算を読む（行が無い月は 0 バイト。読み取りは、行を作らない）
#   exceeded?             積算を読み、TransferBudgetPolicy で判定する
#   add_for_broadcast!    配信の sent_bytes と月次の積算を、同一のトランザクションで加算する（中継の送出量の報告ごと）
#
# add_for_broadcast! は、トランザクションの内側で使える（呼び出し側のトランザクションがあれば参加し、無ければ自分で開く。
# SAVEPOINT を作らない）。同じ配信の報告が同時に届いても、配信の行を FOR UPDATE で確保するため、積み上げを失わない。
module TransferBudget
  # 暦月の形（YYYY-MM。月は 01〜12）。DB の CHECK 制約（chk_transfer_months_month_format）と同じ規則
  MONTH_FORMAT = TransferMonth::MONTH_FORMAT

  # bigint（sent_bytes の型）の最大値。これを超える加算は、DB の桁あふれになるため、呼び出しの前に拒否する
  BIGINT_MAX = (2**63) - 1

  class << self
    # month_key（"2026-10"）の積算へ、bytes（0 以上の整数）を加算し、加算後の積算を返す。
    # 行が無ければ作る。同時の呼び出しは、DB が直列にする（ON CONFLICT DO UPDATE。読んでから書く 2 段にしない）。
    def add!(month_key:, bytes:)
      check_month_key!(month_key)
      Preconditions.integer!(bytes, "bytes", min: 0, max: BIGINT_MAX)

      result = TransferMonth.upsert_all(
        [ { month: month_key, sent_bytes: bytes } ],
        unique_by: :month,
        on_duplicate: Arel.sql("sent_bytes = transfer_months.sent_bytes + EXCLUDED.sent_bytes"),
        returning: %w[ sent_bytes ]
      )
      result.first.fetch("sent_bytes")
    end

    # 月の積算（バイト）。行が無い月は 0（まだ何も送出していない月であって、読み取りの失敗ではない）。行は作らない。
    def sent_bytes(month_key:)
      check_month_key!(month_key)

      TransferMonth.where(month: month_key).pick(:sent_bytes) || 0
    end

    # 月の積算が、予算（settings.monthly_transfer_budget_gb）に達しているなら true（新規の受付を受理しない）。
    def exceeded?(month_key:, settings:)
      Preconditions.kind!(settings, Settings, "settings")

      TransferBudgetPolicy.exceeded?(
        sent_bytes: sent_bytes(month_key: month_key),
        budget_gb: settings.monthly_transfer_budget_gb
      )
    end

    # 中継の送出量の報告（増分 delta_bytes）を、配信の sent_bytes と、now の暦月（JST）の積算へ、同一のトランザクションで加算する。
    # 月次の積算（加算後）を返す。呼び出し側のメモリ上の配信にも、加算後の sent_bytes を反映する。
    # 終了した配信の最後の報告も、加算する（送出した分は、予算に数える）。
    def add_for_broadcast!(broadcast, delta_bytes:, now:)
      Preconditions.kind!(broadcast, Broadcast, "broadcast")
      raise ArgumentError, "broadcast must be persisted" unless broadcast.persisted?

      Preconditions.integer!(delta_bytes, "delta_bytes", min: 0, max: BIGINT_MAX)
      month_key = UsageCalendar.month_key(now)

      locked = nil
      month_total = ApplicationRecord.transaction do
        # 配信の行を確保してから、加算する。配信が無ければ（RecordNotFound）、月次の積算へも、何も加算しない
        locked = Broadcast.owned_by(broadcast.user_id).lock.find(broadcast.id)
        locked.update_columns(sent_bytes: locked.sent_bytes + delta_bytes)
        add!(month_key: month_key, bytes: delta_bytes)
      end

      broadcast.assign_attributes(sent_bytes: locked.sent_bytes)
      broadcast.clear_attribute_changes(%w[ sent_bytes ])
      month_total
    end

    private

    def check_month_key!(month_key)
      return if month_key.is_a?(String) && MONTH_FORMAT.match?(month_key)

      raise ArgumentError, "month_key must match YYYY-MM, got #{month_key.class}"
    end
  end
end
