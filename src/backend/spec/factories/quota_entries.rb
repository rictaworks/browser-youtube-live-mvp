FactoryBot.define do
  # 割り当ての記帳の明細。列名 method は、Object#method と衝突し、DSL では宣言できないため、add_attribute で宣言する。
  # broadcast は空（配信に属さない呼び出し）。配信に属する明細は、create(:quota_entry, broadcast: ..., quota_day: ...) で作る
  factory :quota_entry do
    quota_day
    add_attribute(:method) { "liveBroadcasts.list" }
    units { 1 }
    result { "ok" }
    bucket { "prep" }
    called_at { Time.current }

    # 配信に属さない呼び出し（共通枠）
    trait :common do
      bucket { "common" }
    end
  end
end
