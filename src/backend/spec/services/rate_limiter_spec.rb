require "rails_helper"
require "support/model_support"
require "support/log_capture"

# 頻度制限（issue #7。requirements.md 20.3・28.1。src/contracts/http-api.md 1.7）。
# 計数は、アプリケーションのプロセス内（Mutex・メモリ）に持ち、永続化しない。時計は引数で受け取る。
RSpec.describe RateLimiter do
  # 進められる時計。clock.call で時刻を返す
  let(:clock_state) { { now: Time.utc(2026, 10, 7, 4, 30, 0) } }
  let(:clock) { -> { clock_state[:now] } }
  let(:limiter) { described_class.new(clock: clock) }

  def advance(seconds)
    clock_state[:now] += seconds
  end

  describe "#hit（固定の件数・窓）" do
    it "上限までは許可し、超えたら拒否する" do
      results = Array.new(4) { limiter.hit("k", limit: 3, window: 60) }

      expect(results.map(&:allowed?)).to eq([ true, true, true, false ])
    end

    it "許可のとき retry_at は nil" do
      expect(limiter.hit("k", limit: 3, window: 60).retry_at).to be_nil
    end

    it "拒否のとき、枠が空く時刻（retry_at）を返す。最も古い計数が、窓から外れる時刻" do
      first_at = clock_state[:now]
      limiter.hit("k", limit: 2, window: 60)
      advance(10)
      limiter.hit("k", limit: 2, window: 60)
      advance(5)

      result = limiter.hit("k", limit: 2, window: 60)

      expect(result).not_to be_allowed
      expect(result.retry_at).to eq(first_at + 60)
    end

    it "retry_at の時刻になれば、また許可される（窓が滑る）" do
      first_at = clock_state[:now]
      2.times { limiter.hit("k", limit: 2, window: 60) }
      expect(limiter.hit("k", limit: 2, window: 60)).not_to be_allowed

      clock_state[:now] = first_at + 60

      expect(limiter.hit("k", limit: 2, window: 60)).to be_allowed
    end

    it "retry_at の 1 秒前は、まだ拒否される" do
      first_at = clock_state[:now]
      2.times { limiter.hit("k", limit: 2, window: 60) }

      clock_state[:now] = first_at + 59

      expect(limiter.hit("k", limit: 2, window: 60)).not_to be_allowed
    end

    it "窓の途中で、古い計数だけが外れる（1 件ずつ、枠が空く）" do
      start = clock_state[:now]
      limiter.hit("k", limit: 3, window: 60)
      advance(20)
      limiter.hit("k", limit: 3, window: 60)
      advance(20)
      limiter.hit("k", limit: 3, window: 60)

      expect(limiter.hit("k", limit: 3, window: 60).retry_at).to eq(start + 60)

      clock_state[:now] = start + 60
      expect(limiter.hit("k", limit: 3, window: 60)).to be_allowed
      expect(limiter.hit("k", limit: 3, window: 60).retry_at).to eq(start + 80)
    end

    it "拒否した呼び出しは、計数に入れない（拒否され続けても、枠が空く時刻が遅れない）" do
      start = clock_state[:now]
      limiter.hit("k", limit: 1, window: 60)

      10.times do
        advance(5)
        expect(limiter.hit("k", limit: 1, window: 60).retry_at).to eq(start + 60)
      end

      clock_state[:now] = start + 60
      expect(limiter.hit("k", limit: 1, window: 60)).to be_allowed
    end

    it "鍵ごとに、独立に数える" do
      expect(limiter.hit("a", limit: 1, window: 60)).to be_allowed
      expect(limiter.hit("a", limit: 1, window: 60)).not_to be_allowed
      expect(limiter.hit("b", limit: 1, window: 60)).to be_allowed
    end

    it "上限が 1 の場合（再確認: 1 回 / 分）" do
      expect(limiter.hit("recheck", limit: 1, window: 60)).to be_allowed
      expect(limiter.hit("recheck", limit: 1, window: 60).retry_at).to eq(clock_state[:now] + 60)
    end

    it "窓は、ActiveSupport::Duration でも渡せる" do
      limiter.hit("k", limit: 1, window: 1.hour)

      expect(limiter.hit("k", limit: 1, window: 1.hour).retry_at).to eq(clock_state[:now] + 3600)
    end

    it "retry_at は Time" do
      limiter.hit("k", limit: 1, window: 60)

      expect(limiter.hit("k", limit: 1, window: 60).retry_at).to be_a(Time)
    end

    it "時計は、呼び出しのたびに、引数の時計から読む（実時計に依存しない）" do
      expect(clock).to receive(:call).and_call_original.at_least(:once)

      limiter.hit("k", limit: 1, window: 60)
    end
  end

  describe "#hit（引数の検査）" do
    [ nil, "", 123, :key ].each do |key|
      it "鍵 #{key.inspect} は、例外にする" do
        expect { limiter.hit(key, limit: 1, window: 60) }.to raise_error(ArgumentError)
      end
    end

    [ 0, -1, 1.5, nil, "3" ].each do |limit|
      it "上限 #{limit.inspect} は、例外にする（1 以上の整数）" do
        expect { limiter.hit("k", limit: limit, window: 60) }.to raise_error(ArgumentError)
      end
    end

    [ 0, -1, nil, "60" ].each do |window|
      it "窓 #{window.inspect} は、例外にする（正の数・期間）" do
        expect { limiter.hit("k", limit: 1, window: window) }.to raise_error(ArgumentError)
      end
    end

    it "時計が時刻を返さなければ、例外にする（黙って 0 時にしない）" do
      broken = described_class.new(clock: -> { nil })

      expect { broken.hit("k", limit: 1, window: 60) }.to raise_error(ArgumentError)
    end
  end

  describe "#hit_all（複数の規則を、不可分に評価する）" do
    let(:minute) { RateLimiter::Rule.new(key: "recheck_per_minute:u", limit: 1, window: 60) }
    let(:day) { RateLimiter::Rule.new(key: "recheck_per_day:u", limit: 3, window: 86_400) }

    it "すべての規則が許可すれば、すべてに計数する" do
      expect(limiter.hit_all([ minute, day ])).to be_allowed
      advance(61)
      expect(limiter.hit_all([ minute, day ])).to be_allowed
      advance(61)
      expect(limiter.hit_all([ minute, day ])).to be_allowed
      advance(61)

      expect(limiter.hit_all([ minute, day ])).not_to be_allowed # 1 日の上限（3 回）
    end

    it "1 つでも拒否すれば、拒否し、どの規則にも計数しない（拒否された要求が、他の規則の枠を消費しない）" do
      expect(limiter.hit_all([ minute, day ])).to be_allowed
      advance(10)
      expect(limiter.hit_all([ minute, day ])).not_to be_allowed # 1 分の上限

      advance(51)
      expect(limiter.hit_all([ minute, day ])).to be_allowed
      advance(61)
      expect(limiter.hit_all([ minute, day ])).to be_allowed # 1 日に、許可されたのは 3 回目（拒否の 1 回は、数えない）
      advance(61)
      expect(limiter.hit_all([ minute, day ])).not_to be_allowed
    end

    it "拒否のときの retry_at は、拒否した規則のうち、最も遅い時刻（すべての規則の枠が空く時刻）" do
      start = clock_state[:now]
      3.times do
        limiter.hit_all([ minute, day ])
        advance(61)
      end
      # ここで、1 日の上限（3 回）に達している。1 分の枠は、空いている

      result = limiter.hit_all([ minute, day ])

      expect(result).not_to be_allowed
      expect(result.retry_at).to eq(start + 86_400)
    end

    it "1 分の枠と 1 日の枠が、同時に拒否なら、遅い方（1 日）の時刻" do
      start = clock_state[:now]
      3.times do
        limiter.hit_all([ minute, day ])
        advance(61)
      end
      limiter.hit("recheck_per_minute:u", limit: 1, window: 60) # 1 分の枠を、直前に使う（1 日の枠は、すでに上限）

      result = limiter.hit_all([ minute, day ])

      expect(result.retry_at).to eq(start + 86_400)
    end

    it "規則が空なら、例外にする" do
      expect { limiter.hit_all([]) }.to raise_error(ArgumentError)
    end

    it "同じ鍵の規則が重なっていれば、例外にする（別々に数えると、上限を誤る）" do
      expect { limiter.hit_all([ minute, minute ]) }.to raise_error(ArgumentError)
    end

    it "規則でないものがあれば、例外にする" do
      expect { limiter.hit_all([ minute, "x" ]) }.to raise_error(ArgumentError)
    end
  end

  describe "メモリ（古い鍵を捨てて、際限なく増えない）" do
    it "窓の過ぎた鍵は、一定の間隔で捨てる（size が戻る）" do
      1_000.times { |index| limiter.hit("ip:#{index}", limit: 30, window: 3600) }
      expect(limiter.size).to eq(1_000)

      advance(3600 + described_class::SWEEP_INTERVAL + 1)
      limiter.hit("fresh", limit: 30, window: 3600)

      expect(limiter.size).to eq(1)
    end

    it "窓の内の鍵は、捨てない（捨てると、上限を超える許可が出る）" do
      limiter.hit("keep", limit: 1, window: 3600)
      advance(described_class::SWEEP_INTERVAL + 1)
      limiter.hit("other", limit: 1, window: 3600)

      expect(limiter.hit("keep", limit: 1, window: 3600)).not_to be_allowed
    end

    it "窓の短い鍵と、長い鍵が混ざっていても、それぞれの窓で捨てる" do
      limiter.hit("short", limit: 1, window: 60)
      limiter.hit("long", limit: 1, window: 86_400)

      advance(described_class::SWEEP_INTERVAL + 61)
      limiter.hit("trigger", limit: 1, window: 60)

      expect(limiter.size).to eq(2) # long と trigger
      expect(limiter.hit("long", limit: 1, window: 86_400)).not_to be_allowed
    end

    it "鍵の数に上限がある。超えたら、最も古く使われた鍵から捨てる" do
      small = described_class.new(clock: clock, max_keys: 3)
      %w[ a b c d e ].each { |key| small.hit(key, limit: 1, window: 3600) }

      expect(small.size).to eq(3)
      expect(small.hit("e", limit: 1, window: 3600)).not_to be_allowed # 新しい鍵は残る
      expect(small.hit("a", limit: 1, window: 3600)).to be_allowed     # 古い鍵は、捨てられた（計数が戻る）
    end

    it "鍵の上限は、既定で 10 万（大きな値）" do
      expect(described_class::DEFAULT_MAX_KEYS).to eq(100_000)
    end

    [ 0, -1, nil, 1.5 ].each do |max_keys|
      it "鍵の上限 #{max_keys.inspect} は、例外にする" do
        expect { described_class.new(clock: clock, max_keys: max_keys) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "並行（複数のスレッドの同時の呼び出し）" do
    it "同じ鍵への同時の呼び出しで、上限を超えて許可しない" do
      limit = 10
      results = Array.new(64) { Thread.new { limiter.hit("shared", limit: limit, window: 3600) } }.map(&:value)

      expect(results.count(&:allowed?)).to eq(limit)
      expect(results.count { |result| !result.allowed? }).to eq(64 - limit)
    end

    it "繰り返しても、上限を超えない（開始をそろえた 8 スレッドが、各 50 回）" do
      limit = 25
      start = Queue.new
      threads = Array.new(8) do
        Thread.new do
          start.pop
          Array.new(50) { limiter.hit("shared", limit: limit, window: 3600).allowed? }
        end
      end
      8.times { start << true }

      expect(threads.flat_map(&:value).count(true)).to eq(limit)
    end

    it "別の鍵は、同時でも、互いの上限に影響しない" do
      results = Array.new(40) { |index| Thread.new { limiter.hit("key-#{index % 4}", limit: 3, window: 3600) } }.map(&:value)

      expect(results.count(&:allowed?)).to eq(12) # 4 つの鍵 x 3 回
    end

    it "複数の規則の評価も、同時に呼ばれても、上限を超えない" do
      rules = [
        RateLimiter::Rule.new(key: "m", limit: 5, window: 60),
        RateLimiter::Rule.new(key: "d", limit: 7, window: 86_400)
      ]

      results = Array.new(50) { Thread.new { limiter.hit_all(rules) } }.map(&:value)

      expect(results.count(&:allowed?)).to eq(5)
    end
  end

  describe "秘匿" do
    it "inspect に、鍵（IP・アカウント識別子）を出さない" do
      limiter.hit("login_start:203.0.113.5", limit: 30, window: 3600)

      expect(limiter.inspect).not_to include("203.0.113.5")
      expect(limiter.inspect).not_to include("login_start")
    end

    it "永続化しない（DB・ファイルへ書かない）" do
      statements = capture_sql { limiter.hit("k", limit: 1, window: 60) }

      expect(statements).to be_empty
    end

    it "ログへ出さない" do
      output = capture_logs { 3.times { limiter.hit("login_start:203.0.113.5", limit: 1, window: 3600) } }

      expect(output).not_to include("203.0.113.5")
    end
  end

  describe ".shared（このプロセスで、1 つの計数）" do
    it "同じインスタンスを返す" do
      expect(described_class.shared).to be(described_class.shared)
    end

    it "実時計を使う" do
      expect(described_class.shared.hit("shared-spec-#{SecureRandom.hex(4)}", limit: 1, window: 60)).to be_allowed
    end
  end

  describe "#check（名前付きの方針と、対象）" do
    it "方針の規則を、対象ごとの鍵で評価する" do
      policy = RateLimitPolicy.login_start

      expect(limiter.check(policy, "203.0.113.5")).to be_allowed
      30.times { limiter.check(policy, "203.0.113.5") }
      expect(limiter.check(policy, "203.0.113.5")).not_to be_allowed
      expect(limiter.check(policy, "203.0.113.6")).to be_allowed
    end

    it "対象が空なら、例外にする" do
      expect { limiter.check(RateLimitPolicy.login_start, "") }.to raise_error(ArgumentError)
      expect { limiter.check(RateLimitPolicy.login_start, nil) }.to raise_error(ArgumentError)
    end
  end
end
