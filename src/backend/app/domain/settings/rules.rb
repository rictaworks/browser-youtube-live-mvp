# frozen_string_literal: true

class Settings
  # 設定の型・範囲の規則と、入力（文字列・型付きの値）の型変換。
  #
  # 範囲は、requirements.md に定めが無いため、次の仮置き（Settings の検査の対象）。
  #   整数        0 以上 INT32_MAX（32 ビット符号付き整数。DB の integer 型に収まる）以下
  #               ただし、時間上限（分）・受付要求の頻度（回 / 時）は 1 以上
  #               （0 は、配信がすぐ終わる・受付がすべて拒否される、の意味になるため）
  #               1 日の割り当て（ユニット）は、共通枠 + 安全余裕以上
  #               （配信に使える上限 = 1 日の割り当て - 共通枠 - 安全余裕 が、負にならないため）
  #   bot 判定のスコアの閾値  0 以上 1 以下（reCAPTCHA v3 のスコアの範囲）
  # 入力の文字列は、厳密に解釈する（前後の空白・桁区切り・符号の + ・16 進・全角の数字は、型違い）。
  module Rules
    # 32 ビット符号付き整数の最大値
    INT32_MAX = 2_147_483_647

    # type は :integer・:float・:boolean。min・max は両端を含む（boolean は nil）。
    Rule = Data.define(:type, :min, :max)

    QUOTA_FLOOR = Contract::Limits::QUOTA.fetch("common_units") + Contract::Limits::QUOTA.fetch("safety_margin_units")

    BY_KEY = {
      Contract::SettingKey::DAILY_ALLOWANCE => Rule.new(type: :integer, min: 0, max: INT32_MAX),
      Contract::SettingKey::ATTEMPT_LIMIT => Rule.new(type: :integer, min: 0, max: INT32_MAX),
      Contract::SettingKey::CONCURRENT_LIMIT => Rule.new(type: :integer, min: 0, max: INT32_MAX),
      Contract::SettingKey::TIME_LIMIT_MINUTES => Rule.new(type: :integer, min: 1, max: INT32_MAX),
      Contract::SettingKey::INTAKE_RATE_PER_HOUR => Rule.new(type: :integer, min: 1, max: INT32_MAX),
      Contract::SettingKey::MONTHLY_TRANSFER_BUDGET_GB => Rule.new(type: :integer, min: 0, max: INT32_MAX),
      Contract::SettingKey::DAILY_QUOTA_UNITS => Rule.new(type: :integer, min: QUOTA_FLOOR, max: INT32_MAX),
      Contract::SettingKey::BOT_SCORE_THRESHOLD => Rule.new(type: :float, min: 0.0, max: 1.0),
      Contract::SettingKey::INTAKE_PAUSED => Rule.new(type: :boolean, min: nil, max: nil)
    }.freeze

    # 整数: 符号（- だけ）と、ASCII の数字。\z で末尾の改行も拒否する
    INTEGER_PATTERN = /\A-?\d+\z/
    # 浮動小数点数: 整数部（必須）・小数部・指数部。Float#to_s の指数表記（1.0e-05）の往復を通す
    FLOAT_PATTERN = /\A-?\d+(\.\d+)?([eE][+-]?\d+)?\z/
    BOOLEAN_STRINGS = { "true" => true, "false" => false }.freeze

    # 数値として解釈する文字列の長さの上限（文字）。これを超える文字列は、型違い（巨大な数の生成・Float の範囲外の警告を避ける）
    MAX_NUMERIC_LENGTH = 64

    class << self
      # 契約の setting_key か。
      def known?(key)
        BY_KEY.key?(key)
      end

      # 入力（文字列または型付きの値）を、設定の型へ変換する。型違いは InvalidSetting（:invalid_type）。範囲は検査しない（check!）。
      def parse(key, raw)
        case BY_KEY.fetch(key).type
        when :integer then parse_integer(key, raw)
        when :float then parse_float(key, raw)
        else parse_boolean(key, raw)
        end
      end

      # 型付きの値の、型と範囲を検査する。文字列は受け付けない。型違いは :invalid_type、範囲外は :out_of_range。
      def check!(key, value)
        rule = BY_KEY.fetch(key)
        case rule.type
        when :integer then check_number!(key, value, rule, Integer)
        when :float then check_number!(key, value, rule, Float)
        else raise InvalidSetting.new(key: key, reason: :invalid_type, value: value) unless [ true, false ].include?(value)
        end
      end

      private

      def parse_integer(key, raw)
        case raw
        when Integer then raw
        when String
          raise InvalidSetting.new(key: key, reason: :invalid_type, value: raw) unless numeric_text?(raw, INTEGER_PATTERN)

          Integer(raw, 10)
        else raise InvalidSetting.new(key: key, reason: :invalid_type, value: raw)
        end
      end

      def parse_float(key, raw)
        case raw
        when Float then raw
        when Integer then raw.to_f
        when String
          raise InvalidSetting.new(key: key, reason: :invalid_type, value: raw) unless numeric_text?(raw, FLOAT_PATTERN)

          Float(raw)
        else raise InvalidSetting.new(key: key, reason: :invalid_type, value: raw)
        end
      end

      def numeric_text?(raw, pattern)
        raw.length <= MAX_NUMERIC_LENGTH && pattern.match?(raw)
      end

      def parse_boolean(key, raw)
        return raw if [ true, false ].include?(raw)

        BOOLEAN_STRINGS.fetch(raw) { raise InvalidSetting.new(key: key, reason: :invalid_type, value: raw) }
      end

      def check_number!(key, value, rule, type)
        raise InvalidSetting.new(key: key, reason: :invalid_type, value: value) unless value.is_a?(type)
        raise InvalidSetting.new(key: key, reason: :invalid_type, value: value) if value.is_a?(Float) && !value.finite?
        raise InvalidSetting.new(key: key, reason: :out_of_range, value: value) if value < rule.min || value > rule.max
      end
    end
  end
end
