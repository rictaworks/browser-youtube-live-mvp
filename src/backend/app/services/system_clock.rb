# 実時計を読む、アプリケーション層のサービスの中で、唯一の場所（issue #7）。
# ほかのサービス（RateLimiter・UsageRecorder・SessionStore など）は、時計・時刻を引数で受け取る（テストで時刻を進められる）。
# 時計として渡せる（SystemClock.method(:now)）。
module SystemClock
  def self.now
    Time.current
  end
end
