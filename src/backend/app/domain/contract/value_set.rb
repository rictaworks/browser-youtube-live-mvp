# frozen_string_literal: true

module Contract
  # 列挙のモジュール（Contract::EndReason など）が extend する、共通の述語。
  # 列挙のモジュールは、凍結した配列 ALL（契約の順の、符号の文字列）を持つ。
  module ValueSet
    # value が、この列挙の符号（文字列）なら true。
    # 符号に似ていても、文字列でないもの（シンボル・nil・数値）や、大文字・空白つきの文字列は false。
    def valid?(value)
      value.is_a?(String) && self::ALL.include?(value)
    end
  end
end
