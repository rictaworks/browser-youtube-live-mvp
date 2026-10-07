FactoryBot.define do
  # 配信レコード。既定は、受理直後（reserved）。終了していない配信は 1 アカウントにつき 1 件までなので、
  # 同じアカウントで 2 件以上を作るときは、:ended を使う。
  # daily_usage と user は、同じアカウントのものになる（user を渡せば、daily_usage もそのアカウントで作る）。
  factory :broadcast do
    user
    daily_usage { association :daily_usage, user: user }
    state { "reserved" }
    usage_date { daily_usage.usage_date }
    quota_date { usage_date }
    pending_title { "dummy-title" }
    privacy_status { "unlisted" }
    made_for_kids { false }
    accepted_at { Time.current }
    prep_reserved_units { 340 }
    settle_reserved_units { 210 }

    # YouTube の資源を作った後の状態に共通の属性（識別子を保存した時点で、タイトルは消える）
    trait :provisioned do
      sequence(:youtube_broadcast_id) { |n| "dummy-youtube-broadcast-#{n}" }
      sequence(:youtube_stream_id) { |n| "dummy-youtube-stream-#{n}" }
      bound { true }
      attempt_counted { true }
      profile { "720p" }
      scheduled_start_at { 1.minute.from_now }
      provisioned_at { Time.current }
    end

    trait :awaiting_media do
      provisioned
      state { "awaiting_media" }
    end

    trait :confirming do
      provisioned
      state { "confirming" }
      publish_started_at { Time.current }
    end

    trait :live do
      provisioned
      state { "live" }
      publish_started_at { Time.current }
      live_at { Time.current }
      allowance_consumed { true }
    end

    trait :interrupted do
      live
      state { "interrupted" }
      interrupted_at { Time.current }
    end

    # 終了。終了と同時に、清算状態を定める（YouTube の資源が無ければ none）
    trait :ended do
      state { "ended" }
      end_reason { "user_stop" }
      ended_at { Time.current }
      pending_title { nil }
    end

    # YouTube の資源を持ったまま終了した（清算が済んでいない）
    trait :ended_unsettled do
      provisioned
      ended
      settlement_state { "pending" }
    end
  end
end
