require "rails_helper"

# 頻度制限の方針（名前付き）（issue #7。requirements.md 28.1。src/contracts/http-api.md 1.7・limits.json の rate_limits）。
#   ログインの開始・YouTube 接続の開始  IP 単位で 30 回 / 時（固定値。別々の計数）
#   再確認                              アカウント単位で 1 回 / 分と 20 回 / 日（直近 24 時間）
#   受付                                アカウント単位で intake_rate_per_hour 回 / 時（設定値。呼び出し側が、値を渡す）
# 方針そのもののスペック。適用（呼び出し）は、各エンドポイントの issue（#8・#11・#12）。
RSpec.describe RateLimitPolicy do
  describe "ログインの開始" do
    subject(:policy) { described_class.login_start }

    it "IP 単位で、30 回 / 時（3600 秒）" do
      expect(policy.name).to eq("login_start")
      expect(policy.scope).to eq(:ip)
      expect(policy.rules.map { |rule| [ rule.name, rule.limit, rule.window_seconds ] }).to eq([ [ "login_start", 30, 3600 ] ])
    end
  end

  describe "YouTube 接続の開始" do
    subject(:policy) { described_class.connect_start }

    it "IP 単位で、30 回 / 時（ログインの開始とは、別の計数）" do
      expect(policy.name).to eq("connect_start")
      expect(policy.scope).to eq(:ip)
      expect(policy.rules.map { |rule| [ rule.name, rule.limit, rule.window_seconds ] }).to eq([ [ "connect_start", 30, 3600 ] ])
    end

    it "ログインの開始と、規則の名前（計数の鍵）が違う" do
      expect(described_class.connect_start.rules.map(&:name)).not_to eq(described_class.login_start.rules.map(&:name))
    end
  end

  describe "再確認" do
    subject(:policy) { described_class.recheck }

    it "アカウント単位で、1 回 / 分（60 秒）と 20 回 / 日（直近 24 時間 = 86400 秒）の 2 つの規則" do
      expect(policy.name).to eq("recheck")
      expect(policy.scope).to eq(:account)
      expect(policy.rules.map { |rule| [ rule.name, rule.limit, rule.window_seconds ] }).to eq(
        [ [ "recheck_per_minute", 1, 60 ], [ "recheck_per_day", 20, 86_400 ] ]
      )
    end
  end

  describe "受付" do
    it "アカウント単位で、設定値（intake_rate_per_hour）回 / 時。値は、呼び出し側が渡す" do
      policy = described_class.intake(10)

      expect(policy.name).to eq("intake")
      expect(policy.scope).to eq(:account)
      expect(policy.rules.map { |rule| [ rule.name, rule.limit, rule.window_seconds ] }).to eq([ [ "intake", 10, 3600 ] ])
    end

    it "設定値を変えれば、上限が変わる" do
      expect(described_class.intake(3).rules.first.limit).to eq(3)
      expect(described_class.intake(1000).rules.first.limit).to eq(1000)
    end

    [ 0, -1, nil, "10", 1.5, true ].each do |value|
      it "設定値 #{value.inspect} は、例外にする（1 以上の整数。既定値へ黙って倒さない）" do
        expect { described_class.intake(value) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "契約との一致（limits.json の rate_limits）" do
    it "固定値の方針は、契約の定数（Contract::Limits::RATE_LIMITS）から作る" do
      contract = Contract::Limits::RATE_LIMITS

      expect(described_class.login_start.rules.first).to have_attributes(limit: contract.dig("login_start", "limit"), window_seconds: contract.dig("login_start", "window_seconds"))
      expect(described_class.connect_start.rules.first).to have_attributes(limit: contract.dig("connect_start", "limit"), window_seconds: contract.dig("connect_start", "window_seconds"))
      expect(described_class.recheck.rules.map(&:limit)).to eq([ contract.dig("recheck_per_minute", "limit"), contract.dig("recheck_per_day", "limit") ])
      expect(described_class.recheck.rules.map(&:window_seconds)).to eq([ contract.dig("recheck_per_minute", "window_seconds"), contract.dig("recheck_per_day", "window_seconds") ])
      expect(described_class.intake(10).rules.first.window_seconds).to eq(contract.dig("intake", "window_seconds"))
    end

    it "単位（IP・アカウント）が、契約の scope と一致する" do
      contract = Contract::Limits::RATE_LIMITS

      expect(described_class.login_start.scope.to_s).to eq(contract.dig("login_start", "scope"))
      expect(described_class.connect_start.scope.to_s).to eq(contract.dig("connect_start", "scope"))
      expect(described_class.recheck.scope.to_s).to eq(contract.dig("recheck_per_minute", "scope"))
      expect(described_class.recheck.scope.to_s).to eq(contract.dig("recheck_per_day", "scope"))
      expect(described_class.intake(10).scope.to_s).to eq(contract.dig("intake", "scope"))
    end

    it "受付の上限の出どころは、設定 intake_rate_per_hour（契約の limit_setting）" do
      expect(Contract::Limits::RATE_LIMITS.dig("intake", "limit_setting")).to eq("intake_rate_per_hour")
      expect(described_class::INTAKE_LIMIT_SETTING).to eq(Contract::SettingKey::INTAKE_RATE_PER_HOUR)
    end
  end

  describe "#rules_for（対象ごとの計数の鍵）" do
    it "規則の名前と対象から、鍵を作る。対象が違えば鍵が違い、方針が違えば鍵が違う" do
      keys = described_class.login_start.rules_for("203.0.113.5").map(&:key)

      expect(keys).to eq([ "login_start:203.0.113.5" ])
      expect(described_class.login_start.rules_for("203.0.113.6").map(&:key)).not_to eq(keys)
      expect(described_class.connect_start.rules_for("203.0.113.5").map(&:key)).not_to eq(keys)
    end

    it "再確認は、2 つの規則の鍵を返す（アカウント識別子ごと）" do
      keys = described_class.recheck.rules_for("7c9d1e2f-3a4b-4c5d-8e6f-0a1b2c3d4e5f").map(&:key)

      expect(keys).to eq([ "recheck_per_minute:7c9d1e2f-3a4b-4c5d-8e6f-0a1b2c3d4e5f", "recheck_per_day:7c9d1e2f-3a4b-4c5d-8e6f-0a1b2c3d4e5f" ])
    end

    [ nil, "", "  ", 123 ].each do |subject|
      it "対象 #{subject.inspect} は、例外にする" do
        expect { described_class.login_start.rules_for(subject) }.to raise_error(ArgumentError)
      end
    end

    it "規則は、RateLimiter::Rule（鍵・上限・窓）" do
      rule = described_class.recheck.rules_for("u").first

      expect(rule).to be_a(RateLimiter::Rule)
      expect(rule).to have_attributes(key: "recheck_per_minute:u", limit: 1, window: 60)
    end
  end

  describe "RateLimiter での動作（時刻を進めて確かめる）" do
    let(:clock_state) { { now: Time.utc(2026, 10, 7, 4, 30, 0) } }
    let(:limiter) { RateLimiter.new(clock: -> { clock_state[:now] }) }

    def advance(seconds)
      clock_state[:now] += seconds
    end

    it "ログインの開始: 同じ IP の 31 回目が拒否される。別の IP は影響を受けない。1 時間後に、また許可される" do
      start = clock_state[:now]
      results = Array.new(31) { limiter.check(described_class.login_start, "203.0.113.5") }

      expect(results.first(30)).to all(be_allowed)
      expect(results.last).not_to be_allowed
      expect(results.last.retry_at).to eq(start + 3600)
      expect(limiter.check(described_class.login_start, "203.0.113.6")).to be_allowed

      clock_state[:now] = start + 3600
      expect(limiter.check(described_class.login_start, "203.0.113.5")).to be_allowed
    end

    it "ログインの開始と接続の開始は、別々に数える（ログインを 30 回しても、接続は許可される）" do
      30.times { limiter.check(described_class.login_start, "203.0.113.5") }

      expect(limiter.check(described_class.login_start, "203.0.113.5")).not_to be_allowed
      expect(limiter.check(described_class.connect_start, "203.0.113.5")).to be_allowed
    end

    it "再確認: 1 分に 1 回。1 日（直近 24 時間）に 20 回" do
      start = clock_state[:now]
      account = "7c9d1e2f-3a4b-4c5d-8e6f-0a1b2c3d4e5f"

      first = limiter.check(described_class.recheck, account)
      advance(30)
      second = limiter.check(described_class.recheck, account)

      expect(first).to be_allowed
      expect(second).not_to be_allowed
      expect(second.retry_at).to eq(start + 60)

      advance(31)
      19.times do
        expect(limiter.check(described_class.recheck, account)).to be_allowed
        advance(61)
      end

      # 1 日の 21 回目（これまでに 20 回の許可）
      twenty_first = limiter.check(described_class.recheck, account)
      expect(twenty_first).not_to be_allowed
      expect(twenty_first.retry_at).to eq(start + 86_400)
    end

    it "再確認は、アカウントごとに数える" do
      limiter.check(described_class.recheck, "account-a-0000-0000-0000-000000000001")

      expect(limiter.check(described_class.recheck, "account-a-0000-0000-0000-000000000001")).not_to be_allowed
      expect(limiter.check(described_class.recheck, "account-b-0000-0000-0000-000000000002")).to be_allowed
    end

    it "受付: 設定値の回数まで。超えたら拒否（拒否された要求も、到着のたびに数える側の呼び出し方は、呼び出し側）" do
      policy = described_class.intake(3)
      account = "7c9d1e2f-3a4b-4c5d-8e6f-0a1b2c3d4e5f"

      results = Array.new(4) { limiter.check(policy, account) }

      expect(results.map(&:allowed?)).to eq([ true, true, true, false ])
    end

    it "受付: 設定値が変われば、次の呼び出しから、新しい上限で判定する（進行中の計数は、そのまま）" do
      account = "7c9d1e2f-3a4b-4c5d-8e6f-0a1b2c3d4e5f"
      2.times { limiter.check(described_class.intake(3), account) }

      expect(limiter.check(described_class.intake(2), account)).not_to be_allowed
      expect(limiter.check(described_class.intake(5), account)).to be_allowed
    end
  end

  it "方針は、凍結された値（呼び出し側が書き換えられない）" do
    [ described_class.login_start, described_class.connect_start, described_class.recheck, described_class.intake(10) ].each do |policy|
      expect(policy).to be_frozen
      expect(policy.rules).to be_frozen
    end
  end
end
