# frozen_string_literal: true

module Contract
  # 列挙 login_error（契約独自の列挙（#3）。ログインの失敗の種類（7.1））の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module LoginError
    extend ValueSet

    REGISTRATION_HELD = "registration_held"
    OAUTH_FAILED = "oauth_failed"

    ALL = [
      REGISTRATION_HELD,
      OAUTH_FAILED
    ].freeze
  end
end
