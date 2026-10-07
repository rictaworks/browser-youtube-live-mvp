module QuotaLedger
  # 台帳の行（quota_days・broadcasts）の確保・変換・保存。QuotaLedger の内部の部品で、外から使わない。
  #
  # 確保（FOR UPDATE）した行から、Domain Core（QuotaPolicy）の値（Day・Reservation）を作り、規則が返した値を、行へ保存する。
  # 規則（判定・計算）は QuotaPolicy にあり、ここには持たない（規則の SSOT を、Domain Core に置く）。
  # 保存は、確保した行に対する UPDATE（update_columns。検証・コールバックを通さず、渡した列だけを書く）。
  # したがって、配信のタイトル（pending_title）など、台帳に関係しない列は、書き換えず、ログ・例外のメッセージにも出さない。
  #
  # 行ロックの順序は、配信の行 → 台帳の行（割り当て日の昇順）。台帳の記帳・予約・移し替え・解放のすべてで同じ順序にする
  # （順序が食い違うと、同時の呼び出しがデッドロックする）。
  module Rows
    class << self
      # 配信の行を、アカウントで絞り込んで、FOR UPDATE で確保する。無ければ ActiveRecord::RecordNotFound。
      # 呼び出し側が渡した配信（メモリ上）の値は、古いかもしれない。判定は、確保した行の値で行う。
      def lock_broadcast!(broadcast)
        Broadcast.owned_by(broadcast.user_id).lock.find(broadcast.id)
      end

      # 割り当て日の行を、無ければ作り（INSERT ... ON CONFLICT DO NOTHING。同時の作成と競合しない）、FOR UPDATE で確保する。
      # 確保は、呼び出し側のトランザクションが終わるまで続く。
      def lock_day!(quota_date)
        QuotaDay.insert_all([ { quota_date: quota_date } ], unique_by: :quota_date)
        QuotaDay.lock.find(quota_date)
      end

      # 台帳の行から、QuotaPolicy::Day（不変の値）を作る。
      def day_value(row)
        QuotaPolicy::Day.new(
          quota_date: row.quota_date,
          used_units: row.used_units,
          reserved_units: row.reserved_units,
          common_used_units: row.common_used_units,
          exhausted: row.exhausted
        )
      end

      # 配信の行（確保した行）から、QuotaPolicy::Reservation（不変の値）を作る。
      def reservation_value(broadcast)
        QuotaPolicy::Reservation.new(
          quota_date: broadcast.quota_date,
          prep_remaining_units: broadcast.prep_reserved_units,
          settle_remaining_units: broadcast.settle_reserved_units
        )
      end

      # 規則が返した台帳の 1 日の値を、確保した台帳の行へ保存する（超過の印は、ここでは書かない。mark_exhausted! だけが書く）。
      def store_day!(row, day)
        row.update_columns(used_units: day.used_units, reserved_units: day.reserved_units, common_used_units: day.common_used_units)
      end

      # 規則が返した予約の値を、確保した配信の行へ保存する（準備・確認枠・終了・清算枠の残額と、予約が属する割り当て日）。
      def store_reservation!(broadcast, reservation)
        broadcast.update_columns(
          prep_reserved_units: reservation.prep_remaining_units,
          settle_reserved_units: reservation.settle_remaining_units,
          quota_date: reservation.quota_date
        )
      end

      # 確保した配信の行の値（columns）を、呼び出し側のメモリ上の配信へ反映する（変更済みの印は付けない）。
      def sync!(broadcast, locked, columns)
        names = columns.map(&:to_s)
        broadcast.assign_attributes(locked.attributes.slice(*names))
        broadcast.clear_attribute_changes(names)
      end
    end
  end
end
