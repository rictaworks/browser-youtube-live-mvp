FactoryBot.define do
  # YouTube の接続。refresh_token_ciphertext は、暗号文に見えるだけのダミー値（本物の更新トークンではない）
  factory :youtube_connection do
    user
    state { "connected" }
    sequence(:refresh_token_ciphertext) { |n| "dummy-ciphertext-#{n}" }
    connected_at { Time.current }
    last_verified_at { Time.current }

    trait :live_not_enabled do
      state { "live_not_enabled" }
    end

    trait :revoked do
      state { "revoked" }
    end

    # 配信用ストリームの識別子を持つ（識別子であって、配信キーではない）
    trait :with_stream do
      sequence(:youtube_stream_id) { |n| "dummy-stream-id-#{n}" }
      stream_verified_at { Time.current }
    end
  end
end
