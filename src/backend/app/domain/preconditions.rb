# frozen_string_literal: true

require "date"

# Domain Core の引数・値の検査。違反は ArgumentError にする（黙って変換しない・既定値へ倒さない）。
#
# メッセージは ASCII で、型の名前と、整数の範囲だけを載せる。利用者の入力の内容（タイトルなど）は、例外へ出さない
# （配信のタイトルを、ログ・例外へ出さない。CLAUDE.md の不変条件）。
module Preconditions
  class << self
    # Time（そのサブクラスを含む）であること。Date・DateTime・文字列・数値は拒否する。
    def time!(value, name)
      return value if value.is_a?(Time)

      raise ArgumentError, "#{name} must be a Time, got #{value.class}"
    end

    # 時刻を持たない Date であること。DateTime は拒否する。
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

    # true または false であること（nil・文字列・数値は拒否）。
    def boolean!(value, name)
      return value if [ true, false ].include?(value)

      raise ArgumentError, "#{name} must be true or false, got #{value.class}"
    end

    # klass のインスタンスであること。
    def kind!(value, klass, name)
      return value if value.is_a?(klass)

      raise ArgumentError, "#{name} must be a #{klass}, got #{value.class}"
    end

    # call を持つこと（Proc・Method など。遅延評価の引数）。値そのもの（シンボル・Hash・nil）は拒否する。
    def callable!(value, name)
      return value if value.respond_to?(:call)

      raise ArgumentError, "#{name} must respond to call, got #{value.class}"
    end
  end
end
