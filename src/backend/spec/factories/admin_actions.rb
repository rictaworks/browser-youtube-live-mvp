FactoryBot.define do
  # 管理操作の記録。target は対象の内部識別子、detail は符号と数値のみ
  factory :admin_action do
    action { "update_setting" }
    target { "daily_allowance" }
    detail { "value=1" }
    occurred_at { Time.current }
  end
end
