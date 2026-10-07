# 制限値・受付停止（requirements.md 8 章・19 章・20.1）。システム全体の表。主キーは、設定のキー（契約の列挙 setting_key）。
# 値は文字列で保存する。行が無ければ既定値（#5 の Settings）。初期値は DB に入れない。
class SystemSetting < ApplicationRecord
  self.primary_key = "key"

  validates :key, inclusion: { in: Contract::SettingKey::ALL }
  validates :value, presence: true
end
