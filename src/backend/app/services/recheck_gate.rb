# 再確認の門（issue #11。requirements.md 7.2・8.4・28.1。src/contracts/http-api.md 2.3 の can_recheck_at）。
#
#   next_allowed_at(user)  次に再確認できる時刻（JST の Time）。今すぐできるなら nil。次の 2 つのうち、遅い方
#     1. 頻度制限    アカウント単位で 1 分に 1 回・1 日（直近 24 時間）20 回（RateLimitPolicy.recheck）。
#                    再確認を消費せずに求める（RateLimiter#peek）。再確認の受け付け（POST /api/youtube/recheck）は、同じ方針で計数する
#     2. 共通枠      共通枠（500 ユニット）が尽きた割り当て日は、その割り当て日の終わり（次の太平洋時間の 0 時）まで、
#                    再確認・接続時の確認を受け付けない（8.4）。再確認 1 回に要するユニット（チャンネルの一覧取得 + 配信の一覧取得）が
#                    残っていなければ、尽きたとみなす（途中の 1 呼び出しで止まって、枠を使い切らない）。
#                    割り当て日は UsageCalendar（太平洋時間のタイムゾーン定義。夏時間を含む）で算出する。定期ジョブに頼らない
#
# 台帳（QuotaLedger.day）は読むだけ（行を作らない・変えない）。時計は注入する（既定は SystemClock）。呼び出しのたびに現在の時刻を読む。
# 頻度制限の計数は、省くとプロセスで共有するもの（RateLimiter.shared）を、呼び出しのたびに引く。
# アカウントの識別子を、ログ・例外に出さない。
class RecheckGate
  # 再確認 1 回に要する共通枠の呼び出し（接続時の確認と同じ。YouTubeGateway#probe_channel）
  PROBE_CALLS = %i[ probe_channel_lookup probe_live_enabled ].freeze

  def initialize(limiter: nil, clock: SystemClock.method(:now))
    @limiter = limiter
    @clock = Preconditions.callable!(clock, "clock")
  end

  # user は User か、アカウントの識別子（UUID の文字列）。次に再確認できる時刻（JST の Time）。今すぐできるなら nil
  def next_allowed_at(user)
    account = OwnerScope.owner_id!(user)
    now = current_time

    latest = [ rate_limited_until(account), quota_exhausted_until(now) ].compact.max
    latest && UsageCalendar.to_jst(latest)
  end

  # 依存するもの（頻度制限の計数）を出さない
  def inspect
    "#<#{self.class.name}>"
  end

  private

  def limiter
    @limiter || RateLimiter.shared
  end

  # 頻度制限が許可する時刻（今すぐ許可なら nil）。再確認を消費しない
  def rate_limited_until(account)
    limiter.peek(RateLimitPolicy.recheck, account).retry_at
  end

  # 共通枠が尽きた割り当て日の終わり（次の割り当て日の始まり）。尽きていなければ nil
  def quota_exhausted_until(now)
    day = QuotaLedger.day(UsageCalendar.quota_date(now))
    return nil if QuotaPolicy.spend_common(day, units: probe_units).granted?

    UsageCalendar.next_quota_date_start(now)
  end

  def probe_units
    PROBE_CALLS.sum { |kind| YouTubeGateway::Calls.fetch(kind).units }
  end

  def current_time
    now = @clock.call
    raise ArgumentError, "clock must return a Time" unless now.is_a?(Time)

    now
  end
end
