# PostgreSQL のエラーメッセージから、行の値を除く（requirements.md 6.1・7.3・10.1・28.2。issue #4 のレビュー指摘）。
#
# 既定の error verbosity では、PostgreSQL のエラーに DETAIL 行が付き、ActiveRecord の例外のメッセージに、値が入る。
#   CHECK 違反    DETAIL: Failing row contains (…)             行のすべての列の値（配信のタイトル・更新トークンの暗号文など）
#   一意違反      DETAIL: Key (google_sub)=(…) already exists  Google の利用者識別子・セッションの要約値など
#   外部キー違反  DETAIL: Key (user_id)=(…) is not present in table "users"
# 例外のメッセージは、ログ・応答へ出うる。配信キー・トークン・配信のタイトルを、DB・ログ・ブラウザへ出さない（CLAUDE.md の不変条件）。
# ActiveRecord::Base.filter_attributes は、inspect と SQL のバインド値だけを伏せ、例外のメッセージには効かない。
#
# そこで、接続の設定のたびに、libpq の error verbosity を TERSE（severity と主メッセージだけ）にする。
#   残るもの  例外の種類（SQLSTATE から決まる。CheckViolation・RecordNotUnique・NotNullViolation・InvalidForeignKey）と、
#             主メッセージ（relation と制約の名前。例: violates check constraint "chk_broadcasts_state"）
#   消えるもの  DETAIL・HINT・CONTEXT（行の値・キーの値）
# 設定は、接続ごと（libpq の接続の属性）。ActiveRecord の configure_connection は、新しい接続・reconnect!・reset!・
# 接続の検証（verify!）のあとの再設定のたびに呼ばれるので、そこで設定する（再接続のあとも、有効）。
#
# 開発時に詳しい DETAIL が要るときは、PostgreSQL のサーバーのログを見る（scripts/dc.sh logs db。サーバー側のログの設定は、
# このクライアント側の設定の影響を受けない）。
# 検査は、spec/config/postgres_error_verbosity_spec.rb と spec/models/sensitive_attributes_spec.rb。
module PostgresErrorVerbosity
  private

  def configure_connection
    super
    @raw_connection.set_error_verbosity(PG::PQERRORS_TERSE)
  end
end

ActiveSupport.on_load(:active_record_postgresqladapter) do
  prepend PostgresErrorVerbosity
end
