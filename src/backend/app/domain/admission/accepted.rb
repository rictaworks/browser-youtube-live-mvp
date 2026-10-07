# frozen_string_literal: true

module Admission
  # 受理（requirements.md 9.3）。ユーザーの識別情報・タイトルを含まない。
  #   usage_date         受理した時刻の利用日（利用枠・開始試行の計上先。8.1）
  #   quota_date         受理した時刻の割り当て日（割り当ての予約の計上先。8.4）
  #   reservation_units  割り当ての予約額（配信 1 本分。550）
  #   limits             適用される上限（AppliedLimits）
  class Accepted < Data.define(:usage_date, :quota_date, :reservation_units, :limits)
    def initialize(usage_date:, quota_date:, reservation_units:, limits:)
      Preconditions.date!(usage_date, "usage_date")
      Preconditions.date!(quota_date, "quota_date")
      Preconditions.integer!(reservation_units, "reservation_units", min: 1)
      Preconditions.kind!(limits, AppliedLimits, "limits")
      super
    end

    def accepted?
      true
    end

    def rejected?
      false
    end
  end
end
