# frozen_string_literal: true

require "date"

# 配信の生命周期の Domain Core（BroadcastSnapshot・状態遷移・期限の評価・終了処理・清算など）が、引数・値の検査に使う部品。
#
# 違反は ArgumentError にする。黙って変換しない・既定値へ倒さない（フォールバック禁止）。
# メッセージは ASCII で、引数の名前と、型（または契約の列挙の名前と値）だけを載せる。
# 利用者の入力の内容（配信のタイトルなど）・秘密の値は、例外へ出さない。
#
# Domain Core は、他の issue の部品に依存しない（この issue は #5 に依存しない）ため、検査の部品を、ここに持つ。
module LifecycleChecks
  class << self
    # Time（そのサブクラスを含む）であること。
    def time!(value, name)
      return value if value.is_a?(Time)

      raise ArgumentError, "#{name} must be a Time, got #{value.class}"
    end

    # nil、または Time であること。
    def time_or_nil!(value, name)
      return value if value.nil? || value.is_a?(Time)

      raise ArgumentError, "#{name} must be a Time or nil, got #{value.class}"
    end

    # 時刻を持たない Date であること（DateTime・Time・文字列は拒否）。
    def date!(value, name)
      return value if value.instance_of?(Date)

      raise ArgumentError, "#{name} must be a Date, got #{value.class}"
    end

    # Integer であること（true・false・Float は拒否）。min・max を指定したときは、その範囲（両端を含む）。
    def integer!(value, name, min: nil, max: nil)
      raise ArgumentError, "#{name} must be an Integer, got #{value.class}" unless value.is_a?(Integer)
      raise ArgumentError, "#{name} must be >= #{min}, got #{value}" if min && value < min
      raise ArgumentError, "#{name} must be <= #{max}, got #{value}" if max && value > max

      value
    end

    # true または false であること。
    def boolean!(value, name)
      return value if [ true, false ].include?(value)

      raise ArgumentError, "#{name} must be true or false, got #{value.class}"
    end

    # 空でない（空白だけでもない）文字列であること。
    def text!(value, name)
      return value if text?(value)

      raise ArgumentError, "#{name} must be a non-empty String, got #{value.class}"
    end

    # nil、または、空でない文字列であること。
    def text_or_nil!(value, name)
      return value if value.nil? || text?(value)

      raise ArgumentError, "#{name} must be a non-empty String or nil, got #{value.class}"
    end

    # 契約の列挙（Contract::EndReason など。ValueSet を extend したモジュール）の符号（文字列）であること。
    def contract_value!(enum, value, name)
      return value if enum.valid?(value)

      raise ArgumentError, "#{name} must be a #{enum.name} value, got #{value.inspect}"
    end

    # klass のインスタンスであること。
    def kind!(value, klass, name)
      return value if value.is_a?(klass)

      raise ArgumentError, "#{name} must be a #{klass}, got #{value.class}"
    end

    private

    def text?(value)
      value.is_a?(String) && !value.strip.empty?
    end
  end
end
