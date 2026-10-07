# frozen_string_literal: true

class Settings
  # 設定の入力が不正なときのエラー。
  #   key     失敗した項目（契約の setting_key。未知のキーのときは、渡されたキーそのまま）
  #   reason  :unknown_key（未知のキー）・:duplicate_key（同じ項目を文字列とシンボルで重複）・
  #           :invalid_type（型違い）・:out_of_range（範囲外）
  # メッセージは ASCII で、項目・理由・入力の値（先頭の一部だけ）を含む。設定の値は秘密ではないので、デバッグのために載せる。
  class InvalidSetting < ArgumentError
    # メッセージに載せる、入力の値の長さの上限（文字）
    EXCERPT_LIMIT = 40
    NO_VALUE = Object.new.freeze
    private_constant :NO_VALUE

    attr_reader :key, :reason

    def initialize(key:, reason:, value: NO_VALUE)
      @key = key
      @reason = reason
      super(build_message(value))
    end

    private

    def build_message(value)
      parts = [ "invalid_setting", "key=#{label(key)}", "reason=#{reason}" ]
      parts << "value=#{excerpt(value)}" unless NO_VALUE.equal?(value)
      parts.join(" ")
    end

    def label(name)
      name.is_a?(String) || name.is_a?(Symbol) ? name.to_s : name.inspect
    end

    def excerpt(value)
      text = value.inspect
      text = "#{text[0, EXCERPT_LIMIT]}..." if text.length > EXCERPT_LIMIT
      text.encode(Encoding::US_ASCII, invalid: :replace, undef: :replace, replace: "?")
    end
  end
end
