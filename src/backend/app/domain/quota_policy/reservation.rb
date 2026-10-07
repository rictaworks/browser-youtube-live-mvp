# frozen_string_literal: true

module QuotaPolicy
  # 配信 1 本の予約（550 = 準備・確認枠 340 + 終了・清算枠 210）の、現在の状態。
  #   quota_date              予約を計上している割り当て日（割り当て日をまたぐと、移し替えで更新する）
  #   prep_remaining_units    準備・確認枠の残額
  #   settle_remaining_units  終了・清算枠の残額
  # 空（残額 0・0）の予約は、解放済み。
  class Reservation < Data.define(:quota_date, :prep_remaining_units, :settle_remaining_units)
    def initialize(quota_date:, prep_remaining_units:, settle_remaining_units:)
      Preconditions.date!(quota_date, "quota_date")
      Preconditions.integer!(prep_remaining_units, "prep_remaining_units", min: 0)
      Preconditions.integer!(settle_remaining_units, "settle_remaining_units", min: 0)
      super
    end

    # 両方の枠の残額の合計（台帳の予約中に含まれている額）。
    def remaining_units
      prep_remaining_units + settle_remaining_units
    end

    # bucket（:prep・:settle）の残額。
    def remaining(bucket)
      case bucket
      when :prep then prep_remaining_units
      when :settle then settle_remaining_units
      else raise ArgumentError, "bucket must be :prep or :settle, got #{bucket.class}"
      end
    end

    # bucket の残額を units 減らした予約。
    def reduced(bucket, units)
      case bucket
      when :prep then with(prep_remaining_units: prep_remaining_units - units)
      when :settle then with(settle_remaining_units: settle_remaining_units - units)
      else raise ArgumentError, "bucket must be :prep or :settle, got #{bucket.class}"
      end
    end

    # 割り当て日を、新しい割り当て日にした予約（残額は同じ）。
    def moved_to(new_quota_date)
      with(quota_date: new_quota_date)
    end

    # 残額をすべて解放した（0・0 の）予約。
    def emptied
      with(prep_remaining_units: 0, settle_remaining_units: 0)
    end
  end
end
