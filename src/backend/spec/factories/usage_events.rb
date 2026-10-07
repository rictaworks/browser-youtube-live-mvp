FactoryBot.define do
  # 測定イベント。アカウントの削除時に、アカウントとの紐づけを外す（user が空になる）
  factory :usage_event do
    user
    occurred_at { Time.current }
    event_type { "login_started" }

    trait :detached do
      user { nil }
    end
  end
end
