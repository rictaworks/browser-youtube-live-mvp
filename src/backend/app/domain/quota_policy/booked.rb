# frozen_string_literal: true

module QuotaPolicy
  # 記帳できた結果。更新後の台帳（day）と、更新後の予約（reservation。共通枠の支出では nil）。
  class Booked < Data.define(:day, :reservation)
    def initialize(day:, reservation:)
      Preconditions.kind!(day, Day, "day")
      Preconditions.kind!(reservation, Reservation, "reservation") unless reservation.nil?
      super
    end

    def granted?
      true
    end
  end
end
