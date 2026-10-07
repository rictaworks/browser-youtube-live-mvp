FactoryBot.define do
  # 削除したアカウントの再登録の保留。sub_digest は、Google 識別子の要約値のダミー値
  factory :deletion_hold do
    sequence(:sub_digest) { |n| "dummy-sub-digest-#{n}" }
    hold_usage_date { Date.new(2026, 10, 7) }
  end
end
