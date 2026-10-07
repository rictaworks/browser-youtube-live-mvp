FactoryBot.define do
  # 接続チケット。要約値のダミー値だけを持つ（チケットそのものの列は無い）。
  # broadcast は、既定では、このアカウントの終了していない配信を 1 件作る。同じアカウントで 2 枚以上を作るときは、broadcast を渡す。
  factory :relay_ticket do
    user
    broadcast { association :broadcast, user: user }
    sequence(:token_digest) { |n| "dummy-ticket-digest-#{n}" }
    epoch { 0 }
    expires_at { 60.seconds.from_now }

    trait :used do
      used_at { Time.current }
    end
  end
end
