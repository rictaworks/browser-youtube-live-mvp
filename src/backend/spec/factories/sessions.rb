FactoryBot.define do
  # ログインセッション。token_digest は要約値（セッション識別子そのものではない）のダミー値
  factory :session do
    user
    sequence(:token_digest) { |n| "dummy-session-digest-#{n}" }
    last_used_at { Time.current }
    expires_at { 30.days.from_now }
  end
end
