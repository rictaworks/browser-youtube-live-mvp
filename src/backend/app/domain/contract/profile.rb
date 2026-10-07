# frozen_string_literal: true

module Contract
  # 列挙 profile（requirements.md 20.4（エンコードプロファイル）・11.7）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。例外：720p は P720・480p は P480（数字で始まる名前・予約語を避ける）。
  module Profile
    extend ValueSet

    P720 = "720p"
    P480 = "480p"

    ALL = [
      P720,
      P480
    ].freeze
  end
end
