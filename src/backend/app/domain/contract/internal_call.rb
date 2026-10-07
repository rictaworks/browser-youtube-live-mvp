# frozen_string_literal: true

module Contract
  # 列挙 internal_call（requirements.md 20.4（内部通信の呼び出し）・11.9）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module InternalCall
    extend ValueSet

    VERIFY = "verify"
    PROVISION = "provision"
    HEARTBEAT = "heartbeat"
    EVENT = "event"

    ALL = [
      VERIFY,
      PROVISION,
      HEARTBEAT,
      EVENT
    ].freeze
  end
end
