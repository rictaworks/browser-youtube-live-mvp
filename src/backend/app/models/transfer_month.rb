# 暦月ごとの送信転送量の積算（requirements.md 8.3・20.1）。システム全体の表。主キーは、暦月の文字列（"2026-10"。JST の暦月）。
class TransferMonth < ApplicationRecord
  self.primary_key = "month"

  MONTH_FORMAT = /\A[0-9]{4}-(0[1-9]|1[0-2])\z/

  validates :month, format: { with: MONTH_FORMAT }
  validates :sent_bytes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
