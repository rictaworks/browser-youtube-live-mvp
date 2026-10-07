# frozen_string_literal: true

# 単位の換算（分・日 → 秒）。
#
# 配信の生命周期の規則の期限・間隔・保持期間の数値（90 秒・30 日など）は、契約（Contract::Limits）から取り、規則のコードに
# 数値を直書きしない（spec/domain/lifecycle/lifecycle_purity_spec.rb が、ほかのファイルの数値の直書きを検知する）。
# 設定（time_limit_minutes）と、契約の日数（retention）を秒へ直す、換算の係数だけを、ここに 1 か所で持つ。
module LifecycleTimeUnits
  SECONDS_PER_MINUTE = 60
  SECONDS_PER_DAY = 86_400
end
