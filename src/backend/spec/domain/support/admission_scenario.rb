require "date"

# 開始受付判定（StartAdmission）のスペックの共通部品。
#
# 「すべて通る」入力（基準）を作り、拒否理由ごとに、その理由だけが該当するように変える（violate）。
# 遅延評価の引数（bot 判定・現況）は、呼び出し回数を数える疑似（CountingProvider）で渡す。
#
# Domain Core の定数は、スペックのファイルの読み込み中には参照できない（domain_loader.rb の説明）。
# このファイルのクラスは、インスタンスを作る時（例の中）に、Domain Core の定数を参照する。

# 呼び出すと値を返す関数。呼び出された回数を数える。block を渡したときは、block の値を返す。
class CountingProvider
  attr_reader :calls

  def initialize(value = nil, &block)
    @value = value
    @block = block
    @calls = 0
  end

  def call
    @calls += 1
    @block ? @block.call : @value
  end
end

class AdmissionScenario
  # 基準の時刻: JST 2026-10-07 13:30（利用日 2026-10-07・暦月 2026-10）、太平洋時間 2026-10-06 21:30（割り当て日 2026-10-06）。
  # 利用日と割り当て日が違う時刻にして、取り違えを検出する。
  NOW = Time.utc(2026, 10, 7, 4, 30, 0)
  # 頻度制限の枠が空く時刻（呼び出し側が渡す）
  RATE_LIMIT_RETRY_AT = Time.utc(2026, 10, 7, 4, 45, 0)

  # 再試行の目安時刻（retry_at）を持つ拒否理由 => ISO 8601（JST）。基準の時刻 NOW のとき。持たない理由は、キーに無い
  EXPECTED_RETRY_AT = {
    "rate_limited" => "2026-10-07T13:45:00+09:00",
    "allowance_consumed" => "2026-10-08T03:00:00+09:00",
    "attempts_exhausted" => "2026-10-08T03:00:00+09:00",
    "transfer_budget_exceeded" => "2026-11-01T00:00:00+09:00",
    "quota_insufficient" => "2026-10-07T16:00:00+09:00"
  }.freeze

  attr_accessor :input, :session_valid, :rate_limit, :bot_verdict, :snapshot, :settings, :now
  attr_reader :bot_provider, :snapshot_provider

  def self.valid_input
    StartAdmission::Input.new(title: "ライブ配信 2026-10-07 13:30", privacy_status: "unlisted", made_for_kids: false)
  end

  def self.valid_snapshot
    AccountSnapshot.new(
      usage_date: Date.new(2026, 10, 7),
      month_key: "2026-10",
      broadcast_in_progress: false,
      connection_state: "connected",
      consumed_count: 0,
      extra_grants: 0,
      attempt_count: 0,
      concurrent_count: 0,
      transfer_sent_bytes: 0,
      quota_day: QuotaPolicy::Day.new(quota_date: Date.new(2026, 10, 6), used_units: 0, reserved_units: 0, common_used_units: 0)
    )
  end

  # すべての判定を通る入力（受理される）
  def initialize
    @input = self.class.valid_input
    @session_valid = true
    @rate_limit = StartAdmission::RateLimit.within_limit
    @bot_verdict = :pass
    @snapshot = self.class.valid_snapshot
    @settings = Settings.defaults
    @now = NOW
  end

  # 判定の時刻と、その時刻の利用日・暦月・割り当て日（現況が持つ日付）を、明示して変える。
  # 日付は、算出規則（UsageCalendar）を使わず、スペックの表に書いた値で渡す（算出規則とは独立に検証するため）。
  def at(time, usage_date:, month_key:, quota_date:)
    self.now = time
    amend(usage_date: usage_date, month_key: month_key)
    amend_quota_day(quota_date: quota_date)
  end

  # 現況の項目を、変える
  def amend(**changes)
    self.snapshot = snapshot.with(**changes)
  end

  # 台帳の項目を、変える
  def amend_quota_day(**changes)
    amend(quota_day: snapshot.quota_day.with(**changes))
  end

  # 拒否理由 reason が該当するように、入力を変える（ほかの理由は、該当しないまま）。
  # 順 5・6・7 は、接続状態の 1 つの値で表すため、同時には成り立たない（最後に呼んだものが有効）。
  def violate(reason)
    case reason
    when "invalid_input" then self.input = input.with(title: "")
    when "not_logged_in" then self.session_valid = false
    when "rate_limited" then self.rate_limit = StartAdmission::RateLimit.exceeded_until(RATE_LIMIT_RETRY_AT)
    when "bot_check_failed" then self.bot_verdict = :fail
    when "broadcast_in_progress" then amend(broadcast_in_progress: true)
    when "youtube_not_connected" then amend(connection_state: "not_connected")
    when "authorization_revoked" then amend(connection_state: "revoked")
    when "live_not_enabled" then amend(connection_state: "live_not_enabled")
    when "allowance_consumed" then amend(consumed_count: 1)
    when "attempts_exhausted" then amend(attempt_count: 3)
    when "intake_paused" then self.settings = settings.with(intake_paused: true)
    when "transfer_budget_exceeded" then amend(transfer_sent_bytes: 10_000_000_000)
    when "capacity_full" then amend(concurrent_count: 3)
    when "quota_insufficient" then amend_quota_day(reserved_units: 8_451)
    else raise ArgumentError, "unknown reason: #{reason}"
    end
    self
  end

  # 判定を実行する。bot 判定・現況は、呼び出し回数を数える疑似で渡す（bot_provider・snapshot_provider）。
  def decide
    @bot_provider = CountingProvider.new(bot_verdict)
    @snapshot_provider = CountingProvider.new(snapshot)
    StartAdmission.decide(
      input: input,
      session_valid: session_valid,
      rate_limit: rate_limit,
      bot_verdict: bot_provider,
      snapshot: snapshot_provider,
      settings: settings,
      now: now
    )
  end
end
