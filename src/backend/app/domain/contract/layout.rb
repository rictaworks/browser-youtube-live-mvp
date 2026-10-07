# frozen_string_literal: true

module Contract
  # 列挙 layout（requirements.md 20.4（レイアウト）・11.3）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module Layout
    extend ValueSet

    SCREEN_WITH_WIPE = "screen_with_wipe"
    SCREEN_ONLY = "screen_only"
    CAMERA_ONLY = "camera_only"
    SLATE = "slate"

    ALL = [
      SCREEN_WITH_WIPE,
      SCREEN_ONLY,
      CAMERA_ONLY,
      SLATE
    ].freeze
  end
end
