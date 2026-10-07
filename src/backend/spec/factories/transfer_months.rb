FactoryBot.define do
  # 暦月ごとの送信転送量の積算。month は "2026-10" の形（YYYY-MM）
  factory :transfer_month do
    sequence(:month) { |n| format("%04d-%02d", 2000 + ((n - 1) / 12), ((n - 1) % 12) + 1) }
    sent_bytes { 0 }
  end
end
