# frozen_string_literal: true

module Contract
  # 列挙 interrupt_cause（契約独自の列挙（#3）。internal-api.md の事象（中断）の原因）の符号。値の順は契約の一部。
  # 画面に出す文言は、フロントエンドの文言カタログにあり、ここには持たない。
  # 値の定数名は、値を大文字にしたもの。
  module InterruptCause
    extend ValueSet

    BROWSER_DISCONNECTED = "browser_disconnected"
    MEDIA_STALLED = "media_stalled"
    RTMPS_DISCONNECTED = "rtmps_disconnected"
    BUFFER_OVERFLOW = "buffer_overflow"

    ALL = [
      BROWSER_DISCONNECTED,
      MEDIA_STALLED,
      RTMPS_DISCONNECTED,
      BUFFER_OVERFLOW
    ].freeze
  end
end
