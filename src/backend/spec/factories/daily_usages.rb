FactoryBot.define do
  # 利用日ごとの利用実績。同じアカウントで重ならないよう、利用日は連番で進める
  factory :daily_usage do
    user
    sequence(:usage_date) { |n| Date.new(2026, 1, 1) + n }
  end
end
