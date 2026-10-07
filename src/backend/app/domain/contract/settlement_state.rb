# frozen_string_literal: true

module Contract
  # 列挙 settlement_state（requirements.md 20.4（清算状態）・25.2）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module SettlementState
    extend ValueSet

    NONE = "none"
    PENDING = "pending"
    SETTLED = "settled"
    ABANDONED = "abandoned"

    ALL = [
      NONE,
      PENDING,
      SETTLED,
      ABANDONED
    ].freeze
  end
end
