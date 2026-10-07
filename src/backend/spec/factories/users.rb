FactoryBot.define do
  # アカウント。google_sub は、Google の不透明な識別子に見えるダミー値
  factory :user do
    sequence(:google_sub) { |n| "dummy-google-sub-#{n}" }
    last_login_at { Time.current }
  end
end
