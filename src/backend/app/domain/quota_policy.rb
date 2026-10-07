# frozen_string_literal: true

# 割り当て台帳の規則（requirements.md 8.4・15 章「割り当ての予約」「割り当ての記帳」）。純粋な値の変換で、不変の値を返す。
# DB・時刻・設定は持たない。台帳の 1 日（Day）と予約（Reservation）を受け取り、更新後の値を返す（永続化は、呼び出し側）。
#
# 規則（8.4）
#   配信に使える上限  1 日の割り当て（設定。既定 10,000）- 共通枠 500 - 安全余裕 500（既定で 9,000）
#   予約              受理の時に、配信 1 本につき 550（準備・確認枠 340 + 終了・清算枠 210）を計上する。
#                     当該割り当て日の「配信の使用済み + 予約中 + 新規の予約」が上限を超えるときは、予約しない。
#                     台帳の計上に反して YouTube から割り当て超過が返った日（Day#exhausted）は、日の終わりまで予約しない
#   記帳              配信に関する API 呼び出しは、当該配信の予約からのみ支出する。実費を使用済みへ、同額を予約の該当する枠から取り崩す。
#                     準備・確認枠の残額が足りないときは、終了・清算枠から取り崩さず、支出しない（終了と清算に必要な支出が、
#                     それ以前の支出で不足しないため）。終了・清算枠は、呼び出し側が :settle で指定した、終了・清算の用途の支出だけが使う
#   共通枠            配信に属さない呼び出し（接続時の確認・再確認・チャンネル名の取得）は、共通枠 500 から支出する。尽きたら支出しない
#   移し替え          割り当て日をまたいだ配信の予約の残額は、またいだ後の最初の支出の時に、新しい割り当て日へ移す
#                     （新しい割り当て日の空きは検査しない。進行中の配信の終了・清算に必要な額を取り上げないため）
#   解放              予約の残額は、清算状態が終端に達した時点で解放する（配信レコードの終了時点では解放しない）
#
# 結果の型
#   Booked    記帳できた。更新後の台帳（day）と予約（reservation。共通枠の支出では nil）
#   Refused   できなかった（reason: :ledger_full・:day_exhausted・:bucket_insufficient・:common_exhausted）。台帳・予約は変わらない
#   Carried   割り当て日の移し替え（from・to の台帳と、移した予約）
# 呼び出し側の誤り（型違い・割り当て日の不一致・台帳と予約の矛盾）は、例外にする。
#   ArgumentError（型違い・範囲外）・DayMismatch（割り当て日の不一致）・InconsistentLedger（台帳と予約の矛盾）
module QuotaPolicy
  COMMON_UNITS = Contract::Limits::QUOTA.fetch("common_units")
  SAFETY_MARGIN_UNITS = Contract::Limits::QUOTA.fetch("safety_margin_units")
  RESERVATION_UNITS = Contract::Limits::QUOTA.fetch("broadcast_reservation_units")
  PREP_UNITS = Contract::Limits::QUOTA.fetch("prep_reservation_units")
  SETTLE_UNITS = Contract::Limits::QUOTA.fetch("settle_reservation_units")

  # 予約の枠。:prep は準備・確認枠、:settle は終了・清算枠
  BUCKETS = %i[prep settle].freeze

  # 予約と台帳の割り当て日が違う（呼び出し側の誤り。先に carry_over で移し替える）。
  class DayMismatch < ArgumentError; end

  # 台帳の予約中が、予約の残額より少ない（台帳の破損。予約中が負になる）。
  class InconsistentLedger < StandardError; end

  class << self
    # 配信に使える上限。1 日の割り当て - 共通枠 - 安全余裕。
    def usable_units(daily_total:)
      Preconditions.integer!(daily_total, "daily_total", min: 0)

      daily_total - COMMON_UNITS - SAFETY_MARGIN_UNITS
    end

    # 配信の使用済み + 予約中 + 新規の予約 <= 配信に使える上限 のとき true（共通枠は含めない）。
    # 割り当て超過が返った日（day.exhausted）は、空きがあっても false。
    def can_reserve?(day, units:, daily_total:)
      Preconditions.kind!(day, Day, "day")
      Preconditions.integer!(units, "units", min: 1)
      return false if day.exhausted

      day.used_units + day.reserved_units + units <= usable_units(daily_total: daily_total)
    end

    # 配信 1 本分（550）を予約する。Booked（予約中が増えた台帳と、新しい予約）または Refused（:day_exhausted・:ledger_full）。
    def reserve(day, daily_total:)
      unless can_reserve?(day, units: RESERVATION_UNITS, daily_total: daily_total)
        return Refused.new(reason: day.exhausted ? :day_exhausted : :ledger_full)
      end

      Booked.new(
        day: day.with(reserved_units: day.reserved_units + RESERVATION_UNITS),
        reservation: Reservation.new(quota_date: day.quota_date, prep_remaining_units: PREP_UNITS, settle_remaining_units: SETTLE_UNITS)
      )
    end

    # 配信の予約の bucket（:prep・:settle）から、実費 units を支出する。
    # Booked（使用済みが増え、予約中と枠の残額が同額減る）または Refused（:bucket_insufficient。その枠の残額が足りない）。
    # day は、予約の割り当て日の台帳（違うときは DayMismatch）。
    def spend(reservation, bucket:, units:, day:)
      check_holding!(reservation, day)
      check_bucket!(bucket)
      Preconditions.integer!(units, "units", min: 1)
      return Refused.new(reason: :bucket_insufficient) if units > reservation.remaining(bucket)

      Booked.new(
        day: day.with(used_units: day.used_units + units, reserved_units: day.reserved_units - units),
        reservation: reservation.reduced(bucket, units)
      )
    end

    # 配信に属さない呼び出しの実費 units を、共通枠から支出する。
    # Booked（共通枠の使用済みが増えた台帳。reservation は nil）または Refused（:common_exhausted）。
    def spend_common(day, units:)
      Preconditions.kind!(day, Day, "day")
      Preconditions.integer!(units, "units", min: 1)
      return Refused.new(reason: :common_exhausted) if day.common_used_units + units > COMMON_UNITS

      Booked.new(day: day.with(common_used_units: day.common_used_units + units), reservation: nil)
    end

    # 割り当て日をまたいだ予約の残額を、from（予約の割り当て日の台帳）から to（新しい割り当て日の台帳）へ移す。
    # 使用済み・共通枠は移さない。to の空きは検査しない。to は from より後の割り当て日。
    def carry_over(reservation, from:, to:)
      Preconditions.kind!(reservation, Reservation, "reservation")
      Preconditions.kind!(from, Day, "from")
      Preconditions.kind!(to, Day, "to")
      check_same_day!(reservation, from)
      raise ArgumentError, "to.quota_date must be later than from.quota_date" unless to.quota_date > from.quota_date

      check_covered!(from, reservation)
      remaining = reservation.remaining_units
      Carried.new(
        from: from.with(reserved_units: from.reserved_units - remaining),
        to: to.with(reserved_units: to.reserved_units + remaining),
        reservation: reservation.moved_to(to.quota_date)
      )
    end

    # 予約の残額を解放する（台帳の予約中から引き、予約を空にする）。冪等（空の予約の解放は、台帳を変えない）。
    def release(reservation, day:)
      check_holding!(reservation, day)

      Booked.new(
        day: day.with(reserved_units: day.reserved_units - reservation.remaining_units),
        reservation: reservation.emptied
      )
    end

    private

    # 予約と台帳の型・割り当て日の一致・予約中の整合を、まとめて検査する。
    def check_holding!(reservation, day)
      Preconditions.kind!(reservation, Reservation, "reservation")
      Preconditions.kind!(day, Day, "day")
      check_same_day!(reservation, day)
      check_covered!(day, reservation)
    end

    def check_same_day!(reservation, day)
      return if reservation.quota_date == day.quota_date

      raise DayMismatch,
            "reservation.quota_date (#{reservation.quota_date}) differs from day.quota_date (#{day.quota_date}); call carry_over first"
    end

    def check_covered!(day, reservation)
      return if day.reserved_units >= reservation.remaining_units

      raise InconsistentLedger,
            "day.reserved_units (#{day.reserved_units}) is less than the reservation remaining units (#{reservation.remaining_units}) on #{day.quota_date}"
    end

    def check_bucket!(bucket)
      return if BUCKETS.include?(bucket)

      raise ArgumentError, "bucket must be one of #{BUCKETS.inspect}, got #{bucket.class}"
    end
  end
end
