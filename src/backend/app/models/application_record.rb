class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # 機密の列は、inspect とログ（SQL のバインド値）に出さない（requirements.md 6.1・7.3・10.1・28.2）。
  # 名前に一致する列が、すべてのモデルで伏せ字（[FILTERED]）になる。新しい機密の列を足すときは、ここへ名前を足す。
  #   refresh_token_ciphertext  暗号化した更新トークン
  #   token_digest              セッション・接続チケットの要約値
  #   pending_title             配信のタイトル
  #   google_sub                Google の利用者識別子
  #   sub_digest                削除したアカウントの Google 識別子の要約値
  SENSITIVE_ATTRIBUTES = %i[ refresh_token_ciphertext token_digest pending_title google_sub sub_digest ].freeze

  # SQL のログ（バインド値）の伏せ字は、ActiveRecord::Base の filter_attributes を使う（ログの購読者が、Base のものを読む）。
  # したがって、ApplicationRecord ではなく、ActiveRecord::Base に足す。inspect の伏せ字も、ここから、すべてのモデルが受け継ぐ。
  # 既存の設定（config.filter_parameters 由来の :token・:title など）は、そのまま残す。再読み込みで重ならないよう、和集合にする。
  ActiveRecord::Base.filter_attributes |= SENSITIVE_ATTRIBUTES
end
