# 頻度制限の方針（名前付き）（issue #7。requirements.md 28.1。src/contracts/http-api.md 1.7）。
#
#   login_start     ログインの開始。IP 単位で 30 回 / 時（固定値）
#   connect_start   YouTube 接続の開始。IP 単位で 30 回 / 時（固定値。ログインの開始とは、別の計数）
#   recheck         再確認。アカウント単位で 1 回 / 分と 20 回 / 日（直近 24 時間）。2 つの規則を、不可分に評価する
#   intake(limit)   受付（POST /api/broadcasts）。アカウント単位で、設定値 intake_rate_per_hour 回 / 時。
#                   上限は設定値（管理画面で変えられる）なので、呼び出し側が、現在の設定（Settings#intake_rate_per_hour）を渡す
#
# 固定値は、契約（Contract::Limits::RATE_LIMITS = limits.json の rate_limits）から作る。
# 方針は、値だけを持つ。計数は RateLimiter（#check）。適用（呼び出し）は、各エンドポイントを作る issue（#8・#11・#12）。
# 超過は、429 rate_limited（details の retry_at は、枠が空く時刻）。Api::BaseController#enforce_rate_limit! が返す。
class RateLimitPolicy
  # 契約の rate_limits.intake の limit_setting（上限の出どころの設定）
  INTAKE_LIMIT_SETTING = Contract::SettingKey::INTAKE_RATE_PER_HOUR

  # 方針の中の 1 つの規則。name は計数の鍵の接頭辞（方針・規則ごとに別の計数）
  Rule = Data.define(:name, :limit, :window_seconds)

  attr_reader :name, :scope, :rules

  # scope は :ip または :account
  def initialize(name:, scope:, rules:)
    @name = name.freeze
    @scope = scope
    @rules = rules.dup.freeze
    freeze
  end

  # 対象（IP・アカウント識別子の文字列）ごとの、計数の鍵つきの規則（RateLimiter::Rule）
  def rules_for(subject)
    raise ArgumentError, "subject must be a non-empty String" unless subject.is_a?(String) && !subject.strip.empty?

    rules.map { |rule| RateLimiter::Rule.new(key: "#{rule.name}:#{subject}", limit: rule.limit, window: rule.window_seconds) }
  end

  class << self
    def login_start
      LOGIN_START
    end

    def connect_start
      CONNECT_START
    end

    def recheck
      RECHECK
    end

    # per_hour は、現在の設定 intake_rate_per_hour（1 以上の整数）
    def intake(per_hour)
      raise ArgumentError, "per_hour must be an Integer of at least 1" unless per_hour.is_a?(Integer) && per_hour >= 1

      window = Contract::Limits::RATE_LIMITS.fetch("intake").fetch("window_seconds")
      new(name: "intake", scope: scope_of("intake"), rules: [ Rule.new(name: "intake", limit: per_hour, window_seconds: window) ])
    end

    private

    # 契約の rate_limits の 1 項目（固定の上限）から、規則を作る
    def fixed_rule(key)
      definition = Contract::Limits::RATE_LIMITS.fetch(key)
      Rule.new(name: key, limit: definition.fetch("limit"), window_seconds: definition.fetch("window_seconds"))
    end

    def scope_of(key)
      Contract::Limits::RATE_LIMITS.fetch(key).fetch("scope").to_sym
    end
  end

  LOGIN_START = new(name: "login_start", scope: scope_of("login_start"), rules: [ fixed_rule("login_start") ])
  CONNECT_START = new(name: "connect_start", scope: scope_of("connect_start"), rules: [ fixed_rule("connect_start") ])
  RECHECK = new(
    name: "recheck", scope: scope_of("recheck_per_minute"),
    rules: [ fixed_rule("recheck_per_minute"), fixed_rule("recheck_per_day") ]
  )
end
