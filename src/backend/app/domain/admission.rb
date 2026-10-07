# frozen_string_literal: true

# 開始受付判定の結果（requirements.md 9.3）の名前空間。
#
#   Admission::Accepted      受理。利用日・割り当て日・予約額（550）・適用される上限（時間上限・プロファイルの範囲）
#   Admission::Rejected      拒否。拒否理由の符号・再試行で解消するかの区分・再試行の目安時刻・不備のある入力項目の名前
#   Admission::AppliedLimits 受理のときに適用される上限
#
# 結果は、ユーザーの識別情報・タイトルを含まない。配信レコード・接続チケット・中継の接続先（9.3 の受理の出力の残り）は、
# 受理を受けて、アプリケーション層が作る（この結果は、判定の結果だけ）。
# 拒否理由の符号・区分・HTTP ステータス・再試行の目安時刻の規則は、契約（Contract::RejectionReason・HttpRejections）。
module Admission
end
