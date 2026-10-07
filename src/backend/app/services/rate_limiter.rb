# 頻度制限（issue #7。requirements.md 20.3・28.1。src/contracts/http-api.md 1.7）。
#
# 計数は、アプリケーションのプロセス内（Mutex・メモリ）に持ち、永続化しない（DB・ファイルへ書かない）。
# 時計は、引数（clock。呼び出すと時刻を返すもの）で受け取る。テストで時刻を進められる。
#
# 方式は、滑る窓（sliding window）。鍵ごとに、許可した時刻を持ち、窓（window 秒）の内の許可が limit 件に達していれば、拒否する。
#   - 拒否したときの retry_at は、枠が空く時刻（窓の内で最も古い許可の時刻 + window）
#   - 拒否した呼び出しは、計数に入れない（拒否され続けても、枠が空く時刻が遅れない）
#   - 複数の規則（再確認の 1 回 / 分と 20 回 / 日）は、hit_all で不可分に評価する（全部が許可のときだけ、すべてに計数する）
#
# メモリが際限なく増えない。
#   - 窓の過ぎた鍵は、一定の間隔（SWEEP_INTERVAL）で捨てる
#   - 鍵の数に上限（max_keys）があり、超えたら、最も古く使われた鍵から捨てる（捨てた鍵の計数は、戻る）
#   - 1 つの鍵が持つ許可の時刻は、limit 件を超えない
#
# 複数のスレッドが同時に呼んでも、上限を超えて許可しない（1 つの Mutex で、評価と計数を不可分にする）。
# 鍵（IP・アカウント識別子を含む）を、inspect・ログへ出さない。
class RateLimiter
  DEFAULT_MAX_KEYS = 100_000
  # 窓の過ぎた鍵を捨てる間隔（秒。時計の時刻で測る）
  SWEEP_INTERVAL = 60

  # 1 つの規則。key は計数の鍵（文字列）、limit は窓の内の許可の上限（1 以上の整数）、window は窓（秒。正の数または期間）
  class Rule < Data.define(:key, :limit, :window)
    def initialize(key:, limit:, window:)
      raise ArgumentError, "key must be a non-empty String" unless key.is_a?(String) && !key.empty?
      raise ArgumentError, "limit must be an Integer of at least 1" unless limit.is_a?(Integer) && limit >= 1
      raise ArgumentError, "window must be a positive number of seconds" unless window.is_a?(Numeric) && window.to_f.positive?

      super
    end

    def window_seconds
      window.to_f
    end
  end

  # 評価の結果。allowed は許可か、retry_at は、拒否のときの、枠が空く時刻（許可のときは nil）
  Result = Data.define(:allowed, :retry_at) do
    def allowed?
      allowed
    end
  end

  # 鍵ごとの、許可した時刻と、窓
  Entry = Struct.new(:times, :window)
  private_constant :Entry

  SHARED_LOCK = Mutex.new
  private_constant :SHARED_LOCK

  # このプロセスで、1 つの計数（Puma の 1 プロセスにつき 1 つ。実時計を使う）。永続化しない
  def self.shared
    SHARED_LOCK.synchronize { @shared ||= new }
  end

  def initialize(clock: SystemClock.method(:now), max_keys: DEFAULT_MAX_KEYS)
    raise ArgumentError, "max_keys must be an Integer of at least 1" unless max_keys.is_a?(Integer) && max_keys >= 1

    @clock = clock
    @max_keys = max_keys
    @entries = {}
    @last_sweep = nil
    @mutex = Mutex.new
  end

  def hit(key, limit:, window:)
    hit_all([ Rule.new(key: key, limit: limit, window: window) ])
  end

  # 規則のすべてを評価する。すべて許可なら、すべてに計数して許可。1 つでも拒否なら、どれにも計数せず、拒否
  # （retry_at は、拒否した規則のうち、最も遅い時刻）。
  def hit_all(rules)
    validate_rules!(rules)

    @mutex.synchronize do
      now = current_time
      sweep(now)
      evaluated = rules.map { |rule| [ rule, purged_times(rule, now) ] }
      denied = evaluated.select { |rule, times| times.size >= rule.limit }

      if denied.empty?
        evaluated.each { |rule, times| record(rule, times, now) }
        Result.new(allowed: true, retry_at: nil)
      else
        Result.new(allowed: false, retry_at: denied.map { |rule, times| times.min + rule.window_seconds }.max)
      end
    end
  end

  # 名前付きの方針（RateLimitPolicy）を、対象（IP・アカウント識別子）ごとの鍵で評価する
  def check(policy, subject)
    hit_all(policy.rules_for(subject))
  end

  # 持っている鍵の数
  def size
    @mutex.synchronize { @entries.size }
  end

  # 鍵（IP・アカウント識別子）を出さない。ロックを取らない（例外の途中でも、呼べる）
  def inspect
    "#<#{self.class.name} keys=#{@entries.size}>"
  end

  private

  def validate_rules!(rules)
    raise ArgumentError, "rules must be a non-empty Array of RateLimiter::Rule" unless rules.is_a?(Array) && !rules.empty? && rules.all?(Rule)
    raise ArgumentError, "rule keys must be unique" unless rules.map(&:key).uniq.size == rules.size
  end

  def current_time
    now = @clock.call
    raise ArgumentError, "clock must return a Time" unless now.is_a?(Time)

    now
  end

  # 窓の外の許可を捨てた、鍵の許可の時刻（鍵が無ければ、空の配列。まだ、保存しない）
  def purged_times(rule, now)
    entry = @entries[rule.key]
    return [] if entry.nil?

    cutoff = now - rule.window_seconds
    entry.times.reject! { |time| time <= cutoff }
    entry.times
  end

  # 許可を計数する。鍵を、末尾（最も新しく使われた位置）へ移し、鍵の数が上限を超えたら、先頭（最も古く使われた鍵）から捨てる
  def record(rule, times, now)
    @entries.delete(rule.key)
    @entries[rule.key] = Entry.new(times << now, rule.window_seconds)
    @entries.shift while @entries.size > @max_keys
  end

  # 窓の過ぎた鍵を捨てる（前回から SWEEP_INTERVAL 秒が過ぎていれば）
  def sweep(now)
    return if @last_sweep && now - @last_sweep < SWEEP_INTERVAL

    @entries.delete_if { |_key, entry| entry.times.empty? || entry.times.max + entry.window <= now }
    @last_sweep = now
  end
end
