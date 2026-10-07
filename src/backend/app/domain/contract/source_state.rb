# frozen_string_literal: true

module Contract
  # 列挙 source_state（requirements.md 20.4（ソースの状態）・25.5）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module SourceState
    extend ValueSet

    DETACHED = "detached"
    REQUESTING = "requesting"
    ACTIVE = "active"
    DENIED = "denied"
    LOST = "lost"

    ALL = [
      DETACHED,
      REQUESTING,
      ACTIVE,
      DENIED,
      LOST
    ].freeze
  end
end
