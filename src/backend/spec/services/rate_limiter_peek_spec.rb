require "rails_helper"
require "support/model_support"

# 頻度制限の「計数しない評価」（issue #11。requirements.md 7.2・28.1。src/contracts/http-api.md 2.3 の can_recheck_at）。
# peek_all・peek は、hit_all・check と同じ規則（滑る窓）で評価するが、計数しない。
# 「次に再確認できる時刻」を、再確認を消費せずに求めるために使う（アカウント画面が、再確認を無効にする時刻を示す）。
RSpec.describe RateLimiter, "#peek_all・#peek（計数しない評価）" do
  let(:clock_state) { { now: Time.utc(2026, 10, 8, 4, 30, 0) } }
  let(:clock) { -> { clock_state[:now] } }
  let(:limiter) { described_class.new(clock: clock) }

  def advance(seconds)
    clock_state[:now] += seconds
  end

  def rule(key, limit:, window:)
    RateLimiter::Rule.new(key: key, limit: limit, window: window)
  end

  describe "#peek_all" do
    it "計数が無い鍵は、許可（retry_at は nil）" do
      result = limiter.peek_all([ rule("k", limit: 1, window: 60) ])

      expect(result).to be_allowed
      expect(result.retry_at).to be_nil
    end

    it "計数しない: 何度 peek しても、上限までの hit は許可される" do
      5.times { limiter.peek_all([ rule("k", limit: 2, window: 60) ]) }

      results = Array.new(3) { limiter.hit("k", limit: 2, window: 60) }

      expect(results.map(&:allowed?)).to eq([ true, true, false ])
    end

    it "計数しない: 未知の鍵を peek しても、鍵を増やさない（メモリを使わない）" do
      expect { limiter.peek_all([ rule("never-seen", limit: 1, window: 60) ]) }.not_to change(limiter, :size)
    end

    it "上限に達していれば拒否。retry_at は、hit_all の拒否と同じ（最も古い計数が窓から外れる時刻）" do
      first_at = clock_state[:now]
      limiter.hit("k", limit: 2, window: 60)
      advance(10)
      limiter.hit("k", limit: 2, window: 60)
      advance(5)
      rules = [ rule("k", limit: 2, window: 60) ]

      peeked = limiter.peek_all(rules)
      hit = limiter.hit_all(rules)

      expect(peeked).not_to be_allowed
      expect(peeked.retry_at).to eq(first_at + 60)
      expect(peeked.retry_at).to eq(hit.retry_at)
    end

    it "拒否を peek しても、計数は増えない（retry_at が遅れない）" do
      first_at = clock_state[:now]
      limiter.hit("k", limit: 1, window: 60)

      10.times do
        advance(1)
        expect(limiter.peek_all([ rule("k", limit: 1, window: 60) ]).retry_at).to eq(first_at + 60)
      end
    end

    it "retry_at の時刻になれば、許可（境界: 1 秒前は拒否、ちょうどで許可。hit_all と同じ）" do
      first_at = clock_state[:now]
      limiter.hit("k", limit: 1, window: 60)

      clock_state[:now] = first_at + 59
      expect(limiter.peek_all([ rule("k", limit: 1, window: 60) ])).not_to be_allowed

      clock_state[:now] = first_at + 60
      expect(limiter.peek_all([ rule("k", limit: 1, window: 60) ])).to be_allowed
    end

    it "複数の規則: すべてが許可のときだけ許可。拒否した規則のうち、最も遅い retry_at" do
      start = clock_state[:now]
      limiter.hit_all([ rule("minute", limit: 1, window: 60), rule("day", limit: 2, window: 86_400) ])
      advance(61)
      limiter.hit_all([ rule("minute", limit: 1, window: 60), rule("day", limit: 2, window: 86_400) ])
      rules = [ rule("minute", limit: 1, window: 60), rule("day", limit: 2, window: 86_400) ]

      result = limiter.peek_all(rules)

      expect(result).not_to be_allowed
      expect(result.retry_at).to eq(start + 86_400)
    end

    it "規則の一部だけが拒否のときも、拒否（許可した規則の計数は、変わらない）" do
      limiter.hit("minute", limit: 1, window: 60)
      rules = [ rule("minute", limit: 1, window: 60), rule("day", limit: 5, window: 86_400) ]

      expect(limiter.peek_all(rules)).not_to be_allowed
      expect(limiter.size).to eq(1)
    end

    it "鍵ごとに独立（別の鍵の計数に影響されない）" do
      limiter.hit("a", limit: 1, window: 60)

      expect(limiter.peek_all([ rule("a", limit: 1, window: 60) ])).not_to be_allowed
      expect(limiter.peek_all([ rule("b", limit: 1, window: 60) ])).to be_allowed
    end

    it "規則の検査は hit_all と同じ（空・規則でないもの・鍵の重複は ArgumentError）" do
      expect { limiter.peek_all([]) }.to raise_error(ArgumentError, /rules/)
      expect { limiter.peek_all([ "k" ]) }.to raise_error(ArgumentError, /rules/)
      expect { limiter.peek_all([ rule("k", limit: 1, window: 60), rule("k", limit: 2, window: 60) ]) }.to raise_error(ArgumentError, /unique/)
    end

    it "時計が Time を返さなければ ArgumentError（黙って通さない）" do
      broken = described_class.new(clock: -> { 123 })

      expect { broken.peek_all([ rule("k", limit: 1, window: 60) ]) }.to raise_error(ArgumentError, /Time/)
    end
  end

  describe "#peek（名前付きの方針。RateLimitPolicy）" do
    it "再確認の方針: 計数が無ければ許可" do
      expect(limiter.peek(RateLimitPolicy.recheck, "user-1")).to be_allowed
    end

    it "再確認の方針: 1 回の check のあと、1 分間は拒否。retry_at は check の 60 秒後。60 秒後に許可" do
      hit_at = clock_state[:now]
      expect(limiter.check(RateLimitPolicy.recheck, "user-1")).to be_allowed

      advance(30)
      peeked = limiter.peek(RateLimitPolicy.recheck, "user-1")
      expect(peeked).not_to be_allowed
      expect(peeked.retry_at).to eq(hit_at + 60)

      clock_state[:now] = hit_at + 60
      expect(limiter.peek(RateLimitPolicy.recheck, "user-1")).to be_allowed
    end

    it "再確認の方針: 直近 24 時間で 20 回に達すると、最も古い計数から 24 時間後まで拒否（1 分の規則より遅い時刻）" do
      start = clock_state[:now]
      20.times do
        expect(limiter.check(RateLimitPolicy.recheck, "user-1")).to be_allowed
        advance(61)
      end

      result = limiter.peek(RateLimitPolicy.recheck, "user-1")

      expect(result).not_to be_allowed
      expect(result.retry_at).to eq(start + 86_400)
    end

    it "アカウントごとに独立（別のアカウントの再確認は、影響しない）" do
      limiter.check(RateLimitPolicy.recheck, "user-1")

      expect(limiter.peek(RateLimitPolicy.recheck, "user-1")).not_to be_allowed
      expect(limiter.peek(RateLimitPolicy.recheck, "user-2")).to be_allowed
    end

    it "対象が空の文字列なら ArgumentError（方針の規則と同じ）" do
      expect { limiter.peek(RateLimitPolicy.recheck, "") }.to raise_error(ArgumentError, /subject/)
    end
  end

  describe "並行" do
    it "複数のスレッドが peek と hit を同時に呼んでも、例外にならず、上限を超えて許可しない" do
      allowed = Queue.new
      threads = Array.new(8) do |index|
        Thread.new do
          20.times do
            limiter.peek_all([ rule("k", limit: 3, window: 60) ])
            allowed << index if limiter.hit("k", limit: 3, window: 60).allowed?
          end
        end
      end
      threads.each(&:join)

      expect(allowed.size).to eq(3)
    end
  end
end
