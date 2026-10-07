require "spec_helper"
require "date"
require "time"
require_relative "support/domain_loader"
require_relative "support/time_helpers"

# 利用日・割り当て日・暦月の算出（requirements.md 8.1・8.4・15 章）。
# 利用日は JST 03:00 区切り、割り当て日は太平洋時間（America/Los_Angeles のタイムゾーン定義。夏時間を含む）の日付、
# 暦月は JST。時刻は引数で受け取り、実時計を参照しない。
#
# 表の時刻は、読みやすいように JST で書く（jst）か、UTC で書く（utc）。
# 太平洋時間の夏時間は、2026-03-08（PST から PDT へ。その日は 23 時間）と 2026-11-01（PDT から PST へ。その日は 25 時間）に切り替わる。
#   2026-03-08 02:00 PST = 2026-03-08T10:00:00Z に、03:00 PDT へ進む
#   2026-11-01 02:00 PDT = 2026-11-01T09:00:00Z に、01:00 PST へ戻る
RSpec.describe "利用日・割り当て日・暦月の算出（UsageCalendar）" do
  extend DomainTimeHelpers
  include DomainTimeHelpers

  let(:calendar) { UsageCalendar }

  describe ".usage_date（JST へ変換して 3 時間を引いた日付）" do
    {
      "JST 02:59:59 は前日" => [ jst(2026, 10, 7, 2, 59, 59), Date.new(2026, 10, 6) ],
      "JST 03:00:00 は当日" => [ jst(2026, 10, 7, 3, 0, 0), Date.new(2026, 10, 7) ],
      "JST 02:59:59.999999 は前日（1 マイクロ秒前）" => [ jst(2026, 10, 7, 2, 59, 59, 999_999), Date.new(2026, 10, 6) ],
      "JST 03:00:00.000001 は当日" => [ jst(2026, 10, 7, 3, 0, 0, 1), Date.new(2026, 10, 7) ],
      "JST 00:00:00 は前日（暦の日付が変わっても、03:00 までは前の利用日）" => [ jst(2026, 10, 7, 0, 0, 0), Date.new(2026, 10, 6) ],
      "JST 01:30:00 は前日" => [ jst(2026, 10, 7, 1, 30, 0), Date.new(2026, 10, 6) ],
      "JST 12:00:00 は当日" => [ jst(2026, 10, 7, 12, 0, 0), Date.new(2026, 10, 7) ],
      "JST 23:59:59 は当日" => [ jst(2026, 10, 7, 23, 59, 59), Date.new(2026, 10, 7) ],
      "JST 翌日 00:00:00 は、まだ前日の利用日" => [ jst(2026, 10, 8, 0, 0, 0), Date.new(2026, 10, 7) ],
      "年末: JST 2027-01-01 02:59:59 は前年の最終日" => [ jst(2027, 1, 1, 2, 59, 59), Date.new(2026, 12, 31) ],
      "年始: JST 2027-01-01 03:00:00 は新年" => [ jst(2027, 1, 1, 3, 0, 0), Date.new(2027, 1, 1) ],
      "閏日の前: JST 2028-02-29 02:00:00 は 2 月 28 日" => [ jst(2028, 2, 29, 2, 0, 0), Date.new(2028, 2, 28) ],
      "閏日: JST 2028-03-01 02:59:59 は 2 月 29 日" => [ jst(2028, 3, 1, 2, 59, 59), Date.new(2028, 2, 29) ],
      "月末: JST 2026-11-01 02:59:59 は 10 月 31 日" => [ jst(2026, 11, 1, 2, 59, 59), Date.new(2026, 10, 31) ],
      "UTC で表した JST 02:59:59（2026-10-06T17:59:59Z）は 10 月 6 日" => [ utc(2026, 10, 6, 17, 59, 59), Date.new(2026, 10, 6) ],
      "UTC で表した JST 03:00:00（2026-10-06T18:00:00Z）は 10 月 7 日" => [ utc(2026, 10, 6, 18, 0, 0), Date.new(2026, 10, 7) ],
      "+09:00 の Time の 03:00:00 は当日" => [ Time.new(2026, 10, 7, 3, 0, 0, "+09:00"), Date.new(2026, 10, 7) ],
      "+09:00 の Time の 02:59:59 は前日" => [ Time.new(2026, 10, 7, 2, 59, 59, "+09:00"), Date.new(2026, 10, 6) ],
      "-07:00 の Time（2026-10-06 11:00 は、JST 10-07 03:00 ちょうど）は 10 月 7 日" => [ Time.new(2026, 10, 6, 11, 0, 0, "-07:00"), Date.new(2026, 10, 7) ],
      "-07:00 の Time（2026-10-06 10:59:59 は、JST 10-07 02:59:59）は 10 月 6 日" => [ Time.new(2026, 10, 6, 10, 59, 59, "-07:00"), Date.new(2026, 10, 6) ],
      "エポック秒から作った Time（1970-01-01T00:00:00Z は JST 09:00）" => [ Time.at(0), Date.new(1970, 1, 1) ]
    }.each do |label, (time, expected)|
      it label do
        expect(calendar.usage_date(time)).to eq(expected)
      end
    end

    it "戻り値は、時刻を持たない Date で、凍結されている" do
      result = calendar.usage_date(jst(2026, 10, 7, 12, 0, 0))

      expect(result).to be_instance_of(Date)
      expect(result).to be_frozen
    end
  end

  describe ".quota_date（太平洋時間のタイムゾーン定義による日付。固定の時差で計算しない）" do
    # [ 時刻（UTC）, 期待する割り当て日, 固定の時差で計算すると誤る時差（時間。なければ nil） ]
    {
      "冬（PST）: 2026-01-15T07:59:59Z は前日（太平洋時間 23:59:59）" => [ utc(2026, 1, 15, 7, 59, 59), Date.new(2026, 1, 14), nil ],
      "冬（PST）: 2026-01-15T08:00:00Z は当日（太平洋時間 00:00:00）" => [ utc(2026, 1, 15, 8, 0, 0), Date.new(2026, 1, 15), nil ],
      "夏（PDT）: 2026-07-15T06:59:59Z は前日（太平洋時間 23:59:59）" => [ utc(2026, 7, 15, 6, 59, 59), Date.new(2026, 7, 14), nil ],
      "夏（PDT）: 2026-07-15T07:00:00Z は当日（太平洋時間 00:00:00）" => [ utc(2026, 7, 15, 7, 0, 0), Date.new(2026, 7, 15), nil ],
      "春の切り替えの日（2026-03-08）: 07:59:59Z は前日。UTC-7 の固定では 00:59:59 で当日になり誤る" => [ utc(2026, 3, 8, 7, 59, 59), Date.new(2026, 3, 7), -7 ],
      "春の切り替えの日の始まり: 2026-03-08T08:00:00Z は当日（PST の 00:00:00）" => [ utc(2026, 3, 8, 8, 0, 0), Date.new(2026, 3, 8), nil ],
      "春の切り替えの直前: 2026-03-08T09:59:59Z は当日（PST の 01:59:59）" => [ utc(2026, 3, 8, 9, 59, 59), Date.new(2026, 3, 8), nil ],
      "春の切り替えの直後: 2026-03-08T10:00:00Z は当日（PDT の 03:00:00）" => [ utc(2026, 3, 8, 10, 0, 0), Date.new(2026, 3, 8), nil ],
      "春の切り替えの日の終わり: 2026-03-09T06:59:59Z は当日（PDT の 23:59:59）" => [ utc(2026, 3, 9, 6, 59, 59), Date.new(2026, 3, 8), nil ],
      "春の切り替えの翌日の始まり: 2026-03-09T07:00:00Z は翌日（PDT の 00:00:00）。UTC-8 の固定では 23:00 で前日になり誤る" => [ utc(2026, 3, 9, 7, 0, 0), Date.new(2026, 3, 9), -8 ],
      "春の切り替えの翌日: 2026-03-09T07:30:00Z は翌日（PDT の 00:30:00）。UTC-8 の固定では前日になり誤る" => [ utc(2026, 3, 9, 7, 30, 0), Date.new(2026, 3, 9), -8 ],
      "秋の切り替えの前日の終わり: 2026-11-01T06:59:59Z は 10 月 31 日（PDT の 23:59:59）" => [ utc(2026, 11, 1, 6, 59, 59), Date.new(2026, 10, 31), nil ],
      "秋の切り替えの日の始まり: 2026-11-01T07:00:00Z は 11 月 1 日（PDT の 00:00:00）。UTC-8 の固定では 23:00 で前日になり誤る" => [ utc(2026, 11, 1, 7, 0, 0), Date.new(2026, 11, 1), -8 ],
      "秋の切り替えの日: 2026-11-01T07:30:00Z は 11 月 1 日（PDT の 00:30:00）。UTC-8 の固定では前日になり誤る" => [ utc(2026, 11, 1, 7, 30, 0), Date.new(2026, 11, 1), -8 ],
      "秋の切り替えの前（1 回目の 01:30）: 2026-11-01T08:30:00Z は 11 月 1 日（PDT の 01:30:00）" => [ utc(2026, 11, 1, 8, 30, 0), Date.new(2026, 11, 1), nil ],
      "秋の切り替えの後（2 回目の 01:30）: 2026-11-01T09:30:00Z は 11 月 1 日（PST の 01:30:00）" => [ utc(2026, 11, 1, 9, 30, 0), Date.new(2026, 11, 1), nil ],
      "秋の切り替えの日の終わり近く: 2026-11-02T07:30:00Z は 11 月 1 日（PST の 23:30:00）。UTC-7 の固定では翌日になり誤る" => [ utc(2026, 11, 2, 7, 30, 0), Date.new(2026, 11, 1), -7 ],
      "秋の切り替えの日の終わり: 2026-11-02T07:59:59Z は 11 月 1 日（PST の 23:59:59）。UTC-7 の固定では翌日になり誤る" => [ utc(2026, 11, 2, 7, 59, 59), Date.new(2026, 11, 1), -7 ],
      "秋の切り替えの翌日の始まり: 2026-11-02T08:00:00Z は 11 月 2 日（PST の 00:00:00）" => [ utc(2026, 11, 2, 8, 0, 0), Date.new(2026, 11, 2), nil ],
      "年末: 2026-12-31T07:59:59Z は 12 月 30 日" => [ utc(2026, 12, 31, 7, 59, 59), Date.new(2026, 12, 30), nil ],
      "年始: 2027-01-01T08:00:00Z は新年" => [ utc(2027, 1, 1, 8, 0, 0), Date.new(2027, 1, 1), nil ],
      "利用日と割り当て日が違う時刻: 2026-10-07T04:30:00Z（JST 13:30。太平洋時間 10-06 21:30）は 10 月 6 日" => [ utc(2026, 10, 7, 4, 30, 0), Date.new(2026, 10, 6), nil ],
      "-07:00 の Time（2026-10-06 21:30 PDT）は 10 月 6 日" => [ Time.new(2026, 10, 6, 21, 30, 0, "-07:00"), Date.new(2026, 10, 6), nil ],
      "+09:00 の Time（JST 2026-10-07 16:00 = 太平洋時間 10-07 00:00）は 10 月 7 日" => [ Time.new(2026, 10, 7, 16, 0, 0, "+09:00"), Date.new(2026, 10, 7), nil ],
      "+09:00 の Time（JST 2026-10-07 15:59:59 = 太平洋時間 10-06 23:59:59）は 10 月 6 日" => [ Time.new(2026, 10, 7, 15, 59, 59, "+09:00"), Date.new(2026, 10, 6), nil ]
    }.each do |label, (time, expected, wrong_fixed_offset)|
      it label do
        expect(calendar.quota_date(time)).to eq(expected)
      end

      next unless wrong_fixed_offset

      it "（検査の妥当性）#{label.split(':').first}: UTC#{wrong_fixed_offset} の固定の時差で計算すると、この時刻では誤った日付になる" do
        fixed = (time.getutc + (wrong_fixed_offset * 3600)).to_date

        expect(fixed).not_to eq(expected)
      end
    end

    it "戻り値は、時刻を持たない Date で、凍結されている" do
      result = calendar.quota_date(utc(2026, 10, 7, 4, 30, 0))

      expect(result).to be_instance_of(Date)
      expect(result).to be_frozen
    end

    it "夏時間のある日の長さ: 2026-03-08 は 23 時間、2026-11-01 は 25 時間、ふつうの日は 24 時間" do
      lengths = {
        Date.new(2026, 3, 8) => 23,
        Date.new(2026, 11, 1) => 25,
        Date.new(2026, 10, 7) => 24,
        Date.new(2026, 1, 15) => 24
      }
      lengths.each do |date, hours|
        # date の UTC 00:00 から 36 時間、1 時間ごとの時刻（正時）のうち、割り当て日が date であるものを数える。
        # 割り当て日 date は、UTC では date の 07:00〜08:00 に始まり、翌日の 07:00〜08:00 に終わる（36 時間の範囲に収まる）
        start = Time.utc(date.year, date.month, date.day)
        count = (0...36).count { |step| calendar.quota_date(start + (step * 3600)) == date }

        expect(count).to eq(hours), "#{date} の長さが #{hours} 時間ではありません（#{count} 時間）"
      end
    end
  end

  describe ".next_usage_date_start（次の JST 03:00。厳密にその時刻より後）" do
    {
      "JST 02:59:59 の次は、同じ日の 03:00:00" => [ jst(2026, 10, 7, 2, 59, 59), "2026-10-07T03:00:00+09:00" ],
      "JST 03:00:00 ちょうどの次は、翌日の 03:00:00" => [ jst(2026, 10, 7, 3, 0, 0), "2026-10-08T03:00:00+09:00" ],
      "JST 03:00:00.000001 の次は、翌日の 03:00:00" => [ jst(2026, 10, 7, 3, 0, 0, 1), "2026-10-08T03:00:00+09:00" ],
      "JST 03:00:01 の次は、翌日の 03:00:00" => [ jst(2026, 10, 7, 3, 0, 1), "2026-10-08T03:00:00+09:00" ],
      "JST 12:00:00 の次は、翌日の 03:00:00" => [ jst(2026, 10, 7, 12, 0, 0), "2026-10-08T03:00:00+09:00" ],
      "JST 23:59:59 の次は、翌日の 03:00:00" => [ jst(2026, 10, 7, 23, 59, 59), "2026-10-08T03:00:00+09:00" ],
      "JST 翌日 00:00:00 の次は、その日の 03:00:00（まだ前の利用日）" => [ jst(2026, 10, 8, 0, 0, 0), "2026-10-08T03:00:00+09:00" ],
      "年末: JST 2026-12-31 12:00 の次は、2027-01-01 03:00" => [ jst(2026, 12, 31, 12, 0, 0), "2027-01-01T03:00:00+09:00" ],
      "月末: JST 2026-10-31 12:00 の次は、11-01 03:00" => [ jst(2026, 10, 31, 12, 0, 0), "2026-11-01T03:00:00+09:00" ],
      "閏日の前日: JST 2028-02-28 12:00 の次は、02-29 03:00" => [ jst(2028, 2, 28, 12, 0, 0), "2028-02-29T03:00:00+09:00" ],
      "閏日: JST 2028-02-29 12:00 の次は、03-01 03:00" => [ jst(2028, 2, 29, 12, 0, 0), "2028-03-01T03:00:00+09:00" ],
      "UTC で表した時刻（2026-10-06T18:00:00Z = JST 10-07 03:00）の次は、10-08 03:00" => [ utc(2026, 10, 6, 18, 0, 0), "2026-10-08T03:00:00+09:00" ],
      "-07:00 の Time（2026-10-07 04:30 PDT は 11:30Z、JST 20:30）の次は、10-08 03:00" => [ Time.new(2026, 10, 7, 4, 30, 0, "-07:00"), "2026-10-08T03:00:00+09:00" ]
    }.each do |label, (time, expected)|
      it label do
        result = calendar.next_usage_date_start(time)

        expect(result.iso8601).to eq(expected)
        expect(result.utc_offset).to eq(9 * 3600)
      end
    end

    it "どの時刻でも、その時刻より後で、24 時間以内（JST は夏時間が無い）" do
      time = jst(2026, 10, 7, 0, 0, 0)
      (0...(48 * 4)).each do |step|
        instant = time + (step * 900)
        result = calendar.next_usage_date_start(instant)

        expect(result).to be > instant
        expect(result - instant).to be <= 86_400
      end
    end

    it "戻り値は、JST（+09:00）の Time で、凍結されている" do
      result = calendar.next_usage_date_start(jst(2026, 10, 7, 12, 0, 0))

      expect(result).to be_a(Time)
      expect(result.utc_offset).to eq(32_400)
      expect(result).to be_frozen
    end
  end

  describe ".next_quota_date_start（次の太平洋時間 0 時を、JST で表した時刻。厳密にその時刻より後）" do
    {
      "冬（PST）: 2026-01-15T12:00Z の次は、01-16 00:00 PST = 2026-01-16T08:00Z" => [ utc(2026, 1, 15, 12, 0, 0), utc(2026, 1, 16, 8, 0, 0), "2026-01-16T17:00:00+09:00" ],
      "夏（PDT）: 2026-07-15T12:00Z の次は、07-16 00:00 PDT = 2026-07-16T07:00Z" => [ utc(2026, 7, 15, 12, 0, 0), utc(2026, 7, 16, 7, 0, 0), "2026-07-16T16:00:00+09:00" ],
      "春の切り替えの前日: 2026-03-07T20:00Z（PST 12:00）の次は、03-08 00:00 PST = 2026-03-08T08:00Z" => [ utc(2026, 3, 7, 20, 0, 0), utc(2026, 3, 8, 8, 0, 0), "2026-03-08T17:00:00+09:00" ],
      "春の切り替えの日の始まりの 1 秒前: 2026-03-08T07:59:59Z の次は、2026-03-08T08:00:00Z" => [ utc(2026, 3, 8, 7, 59, 59), utc(2026, 3, 8, 8, 0, 0), "2026-03-08T17:00:00+09:00" ],
      "春の切り替えの日の始まりちょうど: 2026-03-08T08:00:00Z の次は、03-09 00:00 PDT = 2026-03-09T07:00Z（23 時間後）" => [ utc(2026, 3, 8, 8, 0, 0), utc(2026, 3, 9, 7, 0, 0), "2026-03-09T16:00:00+09:00" ],
      "春の切り替えの直後: 2026-03-08T10:00:00Z（PDT 03:00）の次は、2026-03-09T07:00Z（UTC-8 の固定なら 08:00Z で誤る）" => [ utc(2026, 3, 8, 10, 0, 0), utc(2026, 3, 9, 7, 0, 0), "2026-03-09T16:00:00+09:00" ],
      "春の切り替えの日の終わりの 1 秒前: 2026-03-09T06:59:59Z の次は、2026-03-09T07:00:00Z" => [ utc(2026, 3, 9, 6, 59, 59), utc(2026, 3, 9, 7, 0, 0), "2026-03-09T16:00:00+09:00" ],
      "秋の切り替えの前日: 2026-10-31T20:00Z（PDT 13:00）の次は、11-01 00:00 PDT = 2026-11-01T07:00Z" => [ utc(2026, 10, 31, 20, 0, 0), utc(2026, 11, 1, 7, 0, 0), "2026-11-01T16:00:00+09:00" ],
      "秋の切り替えの日の始まりちょうど: 2026-11-01T07:00:00Z の次は、11-02 00:00 PST = 2026-11-02T08:00Z（25 時間後）" => [ utc(2026, 11, 1, 7, 0, 0), utc(2026, 11, 2, 8, 0, 0), "2026-11-02T17:00:00+09:00" ],
      "秋の切り替えの 1 回目の 01:30（PDT）: 2026-11-01T08:30:00Z の次は、2026-11-02T08:00Z（UTC-7 の固定なら 07:00Z で誤る）" => [ utc(2026, 11, 1, 8, 30, 0), utc(2026, 11, 2, 8, 0, 0), "2026-11-02T17:00:00+09:00" ],
      "秋の切り替えの 2 回目の 01:30（PST）: 2026-11-01T09:30:00Z の次は、2026-11-02T08:00Z" => [ utc(2026, 11, 1, 9, 30, 0), utc(2026, 11, 2, 8, 0, 0), "2026-11-02T17:00:00+09:00" ],
      "秋の切り替えの日の終わりの 1 秒前: 2026-11-02T07:59:59Z の次は、2026-11-02T08:00:00Z" => [ utc(2026, 11, 2, 7, 59, 59), utc(2026, 11, 2, 8, 0, 0), "2026-11-02T17:00:00+09:00" ],
      "年末: 2026-12-31T12:00Z（PST 04:00）の次は、2027-01-01 00:00 PST = 2027-01-01T08:00Z" => [ utc(2026, 12, 31, 12, 0, 0), utc(2027, 1, 1, 8, 0, 0), "2027-01-01T17:00:00+09:00" ],
      "利用日と割り当て日が違う時刻: 2026-10-07T04:30Z（太平洋時間 10-06 21:30）の次は、10-07 00:00 PDT = 2026-10-07T07:00Z" => [ utc(2026, 10, 7, 4, 30, 0), utc(2026, 10, 7, 7, 0, 0), "2026-10-07T16:00:00+09:00" ]
    }.each do |label, (time, expected_instant, expected_iso)|
      it label do
        result = calendar.next_quota_date_start(time)

        expect(result).to eq(expected_instant)
        expect(result.iso8601).to eq(expected_iso)
        expect(result.utc_offset).to eq(9 * 3600)
      end
    end

    it "夏時間の日の長さ: 春の切り替えの日は 23 時間、秋の切り替えの日は 25 時間、ふつうの日は 24 時間" do
      {
        utc(2026, 3, 8, 8, 0, 0) => 23 * 3600,
        utc(2026, 11, 1, 7, 0, 0) => 25 * 3600,
        utc(2026, 10, 7, 7, 0, 0) => 24 * 3600,
        utc(2026, 1, 15, 8, 0, 0) => 24 * 3600
      }.each do |day_start, seconds|
        expect(calendar.next_quota_date_start(day_start) - day_start).to eq(seconds)
      end
    end

    it "その時刻の割り当て日の翌日の始まりで、その時刻の 1 秒前までは同じ割り当て日（15 分刻みで 3 日分、切り替えの日を含む）" do
      start = utc(2026, 3, 7, 0, 0, 0)
      (0...(72 * 4)).each do |step|
        instant = start + (step * 900)
        boundary = calendar.next_quota_date_start(instant)

        expect(boundary).to be > instant
        expect(calendar.quota_date(boundary)).to eq(calendar.quota_date(instant) + 1)
        expect(calendar.quota_date(boundary - 1)).to eq(calendar.quota_date(instant))
      end
    end

    it "戻り値は、JST（+09:00）の Time で、凍結されている" do
      result = calendar.next_quota_date_start(utc(2026, 10, 7, 4, 30, 0))

      expect(result).to be_a(Time)
      expect(result.utc_offset).to eq(32_400)
      expect(result).to be_frozen
    end
  end

  describe ".month_key（JST の暦月）" do
    {
      "2026-10-07 JST は 2026-10" => [ jst(2026, 10, 7, 12, 0, 0), "2026-10" ],
      "9 月の最後の 1 秒: JST 2026-09-30 23:59:59 は 2026-09" => [ jst(2026, 9, 30, 23, 59, 59), "2026-09" ],
      "10 月の最初の 1 秒: JST 2026-10-01 00:00:00 は 2026-10" => [ jst(2026, 10, 1, 0, 0, 0), "2026-10" ],
      "UTC で表した 9 月の最後の 1 秒（2026-09-30T14:59:59Z）は 2026-09" => [ utc(2026, 9, 30, 14, 59, 59), "2026-09" ],
      "UTC で表した 10 月の最初（2026-09-30T15:00:00Z）は 2026-10" => [ utc(2026, 9, 30, 15, 0, 0), "2026-10" ],
      "暦月は 03:00 区切りではない: JST 2026-10-01 02:59:59 は 2026-10（利用日は 09-30）" => [ jst(2026, 10, 1, 2, 59, 59), "2026-10" ],
      "年末: JST 2026-12-31 23:59:59 は 2026-12" => [ jst(2026, 12, 31, 23, 59, 59), "2026-12" ],
      "年始: JST 2027-01-01 00:00:00 は 2027-01（月は 2 桁）" => [ jst(2027, 1, 1, 0, 0, 0), "2027-01" ],
      "UTC の年末（2026-12-31T15:00:00Z）は JST では新年の 2027-01" => [ utc(2026, 12, 31, 15, 0, 0), "2027-01" ],
      "閏月: JST 2028-02-29 12:00 は 2028-02" => [ jst(2028, 2, 29, 12, 0, 0), "2028-02" ]
    }.each do |label, (time, expected)|
      it label do
        expect(calendar.month_key(time)).to eq(expected)
      end
    end

    it "戻り値は、凍結された文字列" do
      expect(calendar.month_key(jst(2026, 10, 7, 12, 0, 0))).to be_frozen
    end
  end

  describe ".next_month_start（翌月 1 日 00:00 JST）" do
    {
      "JST 2026-10-07 の次は、2026-11-01 00:00" => [ jst(2026, 10, 7, 12, 0, 0), "2026-11-01T00:00:00+09:00" ],
      "月末の最後の 1 秒: JST 2026-10-31 23:59:59 の次は、2026-11-01 00:00" => [ jst(2026, 10, 31, 23, 59, 59), "2026-11-01T00:00:00+09:00" ],
      "月初ちょうど: JST 2026-11-01 00:00:00 の次は、2026-12-01 00:00（厳密に後）" => [ jst(2026, 11, 1, 0, 0, 0), "2026-12-01T00:00:00+09:00" ],
      "月初の 03:00 前: JST 2026-11-01 02:00 の次は、2026-12-01 00:00" => [ jst(2026, 11, 1, 2, 0, 0), "2026-12-01T00:00:00+09:00" ],
      "年末: JST 2026-12-15 の次は、2027-01-01 00:00" => [ jst(2026, 12, 15, 12, 0, 0), "2027-01-01T00:00:00+09:00" ],
      "閏年の 2 月: JST 2028-02-15 の次は、2028-03-01 00:00" => [ jst(2028, 2, 15, 12, 0, 0), "2028-03-01T00:00:00+09:00" ],
      "平年の 2 月: JST 2027-02-28 23:59:59 の次は、2027-03-01 00:00" => [ jst(2027, 2, 28, 23, 59, 59), "2027-03-01T00:00:00+09:00" ],
      "UTC で表した 9 月の最後の 1 秒（2026-09-30T14:59:59Z）の次は、2026-10-01 00:00 JST" => [ utc(2026, 9, 30, 14, 59, 59), "2026-10-01T00:00:00+09:00" ],
      "UTC で表した 10 月の最初（2026-09-30T15:00:00Z）の次は、2026-11-01 00:00 JST" => [ utc(2026, 9, 30, 15, 0, 0), "2026-11-01T00:00:00+09:00" ]
    }.each do |label, (time, expected)|
      it label do
        result = calendar.next_month_start(time)

        expect(result.iso8601).to eq(expected)
        expect(result.utc_offset).to eq(9 * 3600)
        expect(result).to be > time
      end
    end

    it "戻り値は、JST（+09:00）の Time で、凍結されている" do
      expect(calendar.next_month_start(jst(2026, 10, 7, 12, 0, 0))).to be_frozen
    end
  end

  describe ".to_jst（同じ時刻を、JST（+09:00）の Time で表す）" do
    it "同じ時刻で、UTC オフセットが +09:00 の、凍結された Time を返す" do
      time = utc(2026, 10, 7, 4, 30, 15, 250_000)
      result = calendar.to_jst(time)

      expect(result).to eq(time)
      expect(result.utc_offset).to eq(32_400)
      expect(result.iso8601).to eq("2026-10-07T13:30:15+09:00")
      expect(result.subsec).to eq(time.subsec)
      expect(result).to be_frozen
    end

    it "凍結された時刻を渡しても動く（引数を変更しない）" do
      time = utc(2026, 10, 7, 4, 30, 0).freeze

      expect(calendar.to_jst(time)).to eq(time)
    end
  end

  describe "引数の検査（Time 以外は拒否し、黙って変換しない）" do
    invalid_inputs = {
      "nil" => nil,
      "文字列" => "2026-10-07 12:00:00",
      "Date（時刻を持たない）" => Date.new(2026, 10, 7),
      "DateTime" => DateTime.new(2026, 10, 7, 12, 0, 0),
      "整数（エポック秒）" => 1_791_000_000,
      "浮動小数点" => 1.5,
      "シンボル" => :now,
      "Object" => Object.new
    }

    %i[usage_date quota_date next_usage_date_start next_quota_date_start month_key next_month_start to_jst].each do |function|
      invalid_inputs.each do |label, value|
        it "#{function}: #{label} は ArgumentError" do
          expect { calendar.public_send(function, value) }.to raise_error(ArgumentError, /time/)
        end
      end
    end
  end

  describe "実時計に依存しない（同じ入力に同じ出力。Time.now・Date.today を呼ばない）" do
    it "実時計を呼ぶと失敗する状態でも、すべての関数が動く" do
      time = jst(2026, 10, 7, 12, 0, 0)
      allow(Time).to receive(:now).and_raise("Time.now must not be called")
      allow(Date).to receive(:today).and_raise("Date.today must not be called")

      expect(calendar.usage_date(time)).to eq(Date.new(2026, 10, 7))
      expect(calendar.quota_date(time)).to eq(Date.new(2026, 10, 6))
      expect(calendar.next_usage_date_start(time).iso8601).to eq("2026-10-08T03:00:00+09:00")
      expect(calendar.next_quota_date_start(time).iso8601).to eq("2026-10-07T16:00:00+09:00")
      expect(calendar.month_key(time)).to eq("2026-10")
      expect(calendar.next_month_start(time).iso8601).to eq("2026-11-01T00:00:00+09:00")
    end

    it "同じ入力に、何度呼んでも同じ出力を返す（引数を変更しない）" do
      time = utc(2026, 3, 8, 10, 0, 0).freeze
      first = %i[usage_date quota_date next_usage_date_start next_quota_date_start month_key next_month_start].map { |function| calendar.public_send(function, time) }
      second = %i[usage_date quota_date next_usage_date_start next_quota_date_start month_key next_month_start].map { |function| calendar.public_send(function, time) }

      expect(second).to eq(first)
      expect(time).to eq(utc(2026, 3, 8, 10, 0, 0))
    end
  end
end
