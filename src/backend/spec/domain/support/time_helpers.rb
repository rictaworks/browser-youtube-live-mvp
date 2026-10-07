# Domain Core のスペックで、時刻を読みやすく書くための補助。
#
# 表（describe の本体）と、例（it の中）の両方で使えるよう、example group に extend と include の両方を行う。
#
#   RSpec.describe "..." do
#     extend DomainTimeHelpers
#     include DomainTimeHelpers
#
#     { "ラベル" => [ jst(2026, 10, 7, 3, 0, 0), ... ] }.each { ... }
#   end
module DomainTimeHelpers
  # JST（UTC+9）の日時を、同じ時刻の UTC の Time で返す。
  def jst(year, month, day, hour = 0, minute = 0, second = 0, usec = 0)
    Time.utc(year, month, day, hour, minute, second, usec) - (9 * 3600)
  end

  # UTC の日時の Time
  def utc(year, month, day, hour = 0, minute = 0, second = 0, usec = 0)
    Time.utc(year, month, day, hour, minute, second, usec)
  end
end
