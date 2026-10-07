# frozen_string_literal: true

require "date"
require "tzinfo"

# 利用日・割り当て日・暦月の算出（requirements.md 8.1・8.4・15 章）。
#
#   利用日      JST 03:00 を区切りとする 1 日。時刻から 3 時間を引いた JST の日付（利用枠・開始試行の単位）
#   割り当て日  YouTube API の割り当てがリセットされる単位。太平洋時間（America/Los_Angeles）の日付
#   暦月        JST の暦月（月次の送信転送量の予算の単位）。03:00 区切りではなく、JST 00:00 区切り
#
# 利用日の切り替え（JST 03:00）は、定期ジョブではなく、この算出規則で成立する（8.1）。ジョブの失敗が、切り替えの失敗にならない。
# 割り当て日は、固定の時差（UTC-8・UTC-7）ではなく、タイムゾーン定義（夏時間を含む）で算出する（8.4）。
# 時刻は引数で受け取り、実時計（Time.now など）を参照しない。同じ入力に同じ出力を返す（27 章の再現性）。
# 戻り値の Date・Time・文字列は、凍結されている。
module UsageCalendar
  # 利用日が切り替わる、JST の時（8.1）
  USAGE_DAY_START_HOUR = 3

  # タイムゾーン定義（IANA）。実行環境に、タイムゾーンのデータ（システムの zoneinfo か tzinfo-data）が要る。
  JST = TZInfo::Timezone.get("Asia/Tokyo")
  QUOTA_ZONE = TZInfo::Timezone.get("America/Los_Angeles")

  class << self
    # 利用日。JST へ変換して 3 時間を引いた日付（JST 02:59:59 は前日、03:00:00 は当日）。
    def usage_date(time)
      local = JST.to_local(utc_of(time))
      date = calendar_date(local)
      (local.hour < USAGE_DAY_START_HOUR ? date.prev_day : date).freeze
    end

    # 割り当て日。太平洋時間のタイムゾーン定義による日付。
    def quota_date(time)
      calendar_date(QUOTA_ZONE.to_local(utc_of(time))).freeze
    end

    # 次の利用日の始まり（次の JST 03:00）。time より後で、最も早いもの。JST（+09:00）の Time。
    def next_usage_date_start(time)
      local_start(JST, usage_date(time).next_day, USAGE_DAY_START_HOUR)
    end

    # 次の割り当て日の始まり（次の太平洋時間 0 時）を、JST（+09:00）の Time で表したもの。time より後で、最も早いもの。
    # 夏時間の切り替えの日は、23 時間・25 時間になる。
    def next_quota_date_start(time)
      local_start(QUOTA_ZONE, quota_date(time).next_day, 0)
    end

    # JST の暦月（例: "2026-10"）。
    def month_key(time)
      local = JST.to_local(utc_of(time))
      format("%04d-%02d", local.year, local.month).freeze
    end

    # 翌月 1 日 00:00 JST。JST（+09:00）の Time。
    def next_month_start(time)
      local = JST.to_local(utc_of(time))
      local_start(JST, Date.new(local.year, local.month, 1).next_month, 0)
    end

    # 同じ時刻を、JST（+09:00）の Time で表す。応答の時刻（ISO 8601。JST）の表記をそろえるために使う。
    def to_jst(time)
      jst_time(utc_of(time))
    end

    private

    def utc_of(time)
      Preconditions.time!(time, "time").getutc
    end

    def calendar_date(local)
      Date.new(local.year, local.month, local.day)
    end

    # zone の date の hour 時 00 分の時刻を、JST（+09:00）の Time で返す。
    # 太平洋時間の 0 時と、JST の 0 時・3 時は、夏時間の切り替え（2 時台）にかからないので、曖昧にも存在しないことにもならない。
    def local_start(zone, date, hour)
      jst_time(zone.local_to_utc(Time.utc(date.year, date.month, date.day, hour)))
    end

    def jst_time(utc)
      utc.getlocal(JST.period_for_utc(utc).utc_total_offset).freeze
    end
  end
end
