FactoryBot.define do
  # 健全性の標本（10 秒間隔）。broadcast の扱いは、relay_ticket と同じ
  factory :health_sample do
    user
    broadcast { association :broadcast, user: user }
    sampled_at { Time.current }
    sent_kbps { 4500 }
    target_kbps { 4500 }
    backlog_ms { 120 }
    dropped_video_frames { 0 }
    relay_out_kbps { 4620 }
    state { "live" }
  end
end
