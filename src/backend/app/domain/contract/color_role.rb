# frozen_string_literal: true

module Contract
  # 列挙 color_role（requirements.md 20.4（配色の役割）・17.2）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module ColorRole
    extend ValueSet

    BASE = "base"
    SURFACE = "surface"
    SURFACE_RAISED = "surface_raised"
    DIVIDER = "divider"
    CONTROL_BORDER = "control_border"
    TEXT_PRIMARY = "text_primary"
    TEXT_SECONDARY = "text_secondary"
    ACCENT = "accent"
    LIVE = "live"
    WARNING = "warning"
    SUCCESS = "success"
    FOCUS = "focus"

    ALL = [
      BASE,
      SURFACE,
      SURFACE_RAISED,
      DIVIDER,
      CONTROL_BORDER,
      TEXT_PRIMARY,
      TEXT_SECONDARY,
      ACCENT,
      LIVE,
      WARNING,
      SUCCESS,
      FOCUS
    ].freeze

    # 配色の役割ごとの 16 進値（17.2）
    HEX = {
      "base" => "#0F1115",
      "surface" => "#171A21",
      "surface_raised" => "#1F2430",
      "divider" => "#2B3140",
      "control_border" => "#6B7488",
      "text_primary" => "#F2F4F8",
      "text_secondary" => "#A9B1C1",
      "accent" => "#3FB6A8",
      "live" => "#CE2C31",
      "warning" => "#F5A524",
      "success" => "#46A758",
      "focus" => "#8AB4F8"
    }.freeze

    # 役割の上に載せる文字の色（持つ役割だけ）
    ON_HEX = {
      "accent" => "#06201D",
      "live" => "#FFFFFF"
    }.freeze
  end
end
