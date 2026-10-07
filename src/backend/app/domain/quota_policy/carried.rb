# frozen_string_literal: true

module QuotaPolicy
  # 割り当て日の移し替えの結果。
  #   from         予約の残額を引いた、元の割り当て日の台帳
  #   to           予約の残額を足した、新しい割り当て日の台帳
  #   reservation  割り当て日を新しい割り当て日にした予約
  class Carried < Data.define(:from, :to, :reservation)
    def initialize(from:, to:, reservation:)
      Preconditions.kind!(from, Day, "from")
      Preconditions.kind!(to, Day, "to")
      Preconditions.kind!(reservation, Reservation, "reservation")
      super
    end
  end
end
