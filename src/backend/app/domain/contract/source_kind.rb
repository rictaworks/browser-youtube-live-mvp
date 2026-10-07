# frozen_string_literal: true

module Contract
  # 列挙 source_kind（requirements.md 20.4（ソース種別）・4 章）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module SourceKind
    extend ValueSet

    CAMERA = "camera"
    SCREEN = "screen"
    MICROPHONE = "microphone"
    SHARED_AUDIO = "shared_audio"
    SLATE = "slate"

    ALL = [
      CAMERA,
      SCREEN,
      MICROPHONE,
      SHARED_AUDIO,
      SLATE
    ].freeze
  end
end
