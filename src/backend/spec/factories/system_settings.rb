FactoryBot.define do
  # 制限値・受付停止。キーは、契約の列挙 setting_key の 9 種を順に使う（キーが主キーなので、重ならない）
  factory :system_setting do
    sequence(:key) { |n| Contract::SettingKey::ALL.fetch((n - 1) % Contract::SettingKey::ALL.size) }
    value { "1" }
    updated_at { Time.current }
  end
end
