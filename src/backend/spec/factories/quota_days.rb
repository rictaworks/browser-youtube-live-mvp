FactoryBot.define do
  # 割り当て日ごとの台帳（太平洋時間の日付）
  factory :quota_day do
    sequence(:quota_date) { |n| Date.new(2026, 1, 1) + n }
  end
end
