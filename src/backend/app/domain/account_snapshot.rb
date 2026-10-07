# frozen_string_literal: true

require "date"

# アカウントの現況（requirements.md 9.2・15 章「開始受付判定」の入力）。開始受付判定（StartAdmission）が参照する、
# 必要な値だけを持つ不変の値。AR モデル・永続化の型を渡さない（Domain Core は、入出力の型を参照しない）。
# ユーザーの識別情報・タイトルを持たない。
#
# アカウントごとの値と、システム全体の値を、あわせて持つ（判定が参照する現況の全体）。
#   usage_date             現況の利用日（JST 03:00 区切り）。利用枠・開始試行の計数が、この利用日のものであること
#   month_key              現況の暦月（JST。"2026-10"）。送信転送量の積算が、この月のものであること
#   broadcast_in_progress  終了していない配信がある（アカウント）
#   connection_state       YouTube の接続状態（契約の youtube_connection_state の符号）
#   consumed_count         当該利用日の利用枠の消費数（アカウント）
#   extra_grants           当該利用日の追加付与の数（開発者の手動リセットによる。アカウント）
#   attempt_count          当該利用日の開始試行の計上数（アカウント）
#   concurrent_count       現在の同時配信数（終了していない配信の数。システム全体）
#   transfer_sent_bytes    当月の送信転送量の積算（バイト。システム全体）
#   quota_day              当該割り当て日の割り当て台帳（システム全体）
# 現況の日付（usage_date・month_key・quota_day の割り当て日）が、判定の時刻のものであるかは、StartAdmission が検査する。
class AccountSnapshot < Data.define(
  :usage_date,
  :month_key,
  :broadcast_in_progress,
  :connection_state,
  :consumed_count,
  :extra_grants,
  :attempt_count,
  :concurrent_count,
  :transfer_sent_bytes,
  :quota_day
)
  # 暦月の形（YYYY-MM。月は 01〜12）。\z で末尾の改行も拒否する
  MONTH_KEY_PATTERN = /\A\d{4}-(0[1-9]|1[0-2])\z/

  def initialize(usage_date:, month_key:, broadcast_in_progress:, connection_state:, consumed_count:, extra_grants:,
                 attempt_count:, concurrent_count:, transfer_sent_bytes:, quota_day:)
    Preconditions.date!(usage_date, "usage_date")
    check_month_key!(month_key)
    Preconditions.boolean!(broadcast_in_progress, "broadcast_in_progress")
    check_connection_state!(connection_state)
    {
      "consumed_count" => consumed_count, "extra_grants" => extra_grants, "attempt_count" => attempt_count,
      "concurrent_count" => concurrent_count, "transfer_sent_bytes" => transfer_sent_bytes
    }.each { |name, value| Preconditions.integer!(value, name, min: 0) }
    Preconditions.kind!(quota_day, QuotaPolicy::Day, "quota_day")

    super(
      usage_date: usage_date, month_key: month_key.dup.freeze, broadcast_in_progress: broadcast_in_progress,
      connection_state: connection_state.dup.freeze, consumed_count: consumed_count, extra_grants: extra_grants,
      attempt_count: attempt_count, concurrent_count: concurrent_count, transfer_sent_bytes: transfer_sent_bytes,
      quota_day: quota_day
    )
  end

  private

  def check_month_key!(value)
    return if value.is_a?(String) && MONTH_KEY_PATTERN.match?(value)

    raise ArgumentError, "month_key must match YYYY-MM, got #{value.class}"
  end

  def check_connection_state!(value)
    return if Contract::YoutubeConnectionState.valid?(value)

    raise ArgumentError, "connection_state must be a Contract::YoutubeConnectionState code, got #{value.class}"
  end
end
