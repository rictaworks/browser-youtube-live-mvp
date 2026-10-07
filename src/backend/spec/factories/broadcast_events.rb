FactoryBot.define do
  # 配信中の出来事。detail は、符号と数値のみ（自由記述を入れない）。broadcast の扱いは、relay_ticket と同じ
  factory :broadcast_event do
    user
    broadcast { association :broadcast, user: user }
    occurred_at { Time.current }
    event_type { "accepted" }
    detail { nil }
  end
end
