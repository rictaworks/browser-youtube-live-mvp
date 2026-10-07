# frozen_string_literal: true

# 制限値・設定（requirements.md 8 章・19 章・20.4）。9 設定（契約の setting_key）を持つ、不変の値オブジェクト。
#
#   daily_allowance・attempt_limit・concurrent_limit・time_limit_minutes・intake_rate_per_hour・
#   monthly_transfer_budget_gb・daily_quota_units・bot_score_threshold・intake_paused
#
# 既定値は、契約の limits.json（Contract::Limits::SETTING_DEFAULTS）。
# 生成の経路は 2 つ。
#   Settings.defaults        既定値だけの設定
#   Settings.from_raw(raw)   文字列（管理画面・DB から）または型付きの値の Hash を、型変換して検証する。
#                            指定しなかった項目は既定値。指定した項目が不正なら、既定値へ黙って戻さず、InvalidSetting にする。
# 型付きの生成（new・with）は、型と範囲を検証し、文字列を受け付けない。範囲・型の規則は Settings::Rules。
#
# 時刻・現況は持たない。受付判定（StartAdmission）などへ、引数として渡す。
class Settings < Data.define(
  :daily_allowance,
  :attempt_limit,
  :concurrent_limit,
  :time_limit_minutes,
  :intake_rate_per_hour,
  :monthly_transfer_budget_gb,
  :daily_quota_units,
  :bot_score_threshold,
  :intake_paused
)
  class << self
    # 既定値（契約の setting_defaults）だけの設定。
    def defaults
      new(**default_values)
    end

    # 文字列または型付きの値の Hash から、設定を作る。キーは、契約の setting_key（文字列またはシンボル）。
    # 指定しなかった項目は既定値になる。不正な入力（未知のキー・同じ項目の重複・型違い・範囲外）は、InvalidSetting。
    # 複数の項目が不正なときは、契約の setting_key の順で最初のものを報告する。
    def from_raw(raw)
      Preconditions.kind!(raw, Hash, "raw")

      given = normalize_keys(raw)
      values = Contract::SettingKey::ALL.to_h do |key|
        value = given.key?(key) ? Rules.parse(key, given.fetch(key)) : default_values.fetch(key.to_sym)
        Rules.check!(key, value)
        [ key.to_sym, value ]
      end
      new(**values)
    end

    private

    def default_values
      Contract::Limits::SETTING_DEFAULTS.transform_keys(&:to_sym)
    end

    # キーを文字列にそろえ、未知のキー・重複を拒否する。
    def normalize_keys(raw)
      raw.each_with_object({}) do |(key, value), given|
        name = key.is_a?(Symbol) ? key.to_s : key
        raise InvalidSetting.new(key: key, reason: :unknown_key) unless Contract::SettingKey.valid?(name)
        raise InvalidSetting.new(key: name, reason: :duplicate_key) if given.key?(name)

        given[name] = value
      end
    end
  end

  def initialize(**values)
    values.each { |key, value| Rules.check!(key.to_s, value) if Rules.known?(key.to_s) }
    super
  end

  # 項目名（シンボル）と型付きの値の Hash。凍結して返す。
  def to_h
    super.freeze
  end
end
