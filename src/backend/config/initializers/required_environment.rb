# 本番の必須の環境変数の検査（requirements.md 29.4。issue #7）。
# 本番で、アプリケーション層の必須の環境変数が欠けていれば、起動を失敗させる（どの名前が欠けているかを、例外に書く。値は書かない）。
# 開発・テストでは検査しない。名前の一覧と規則は config/required_environment.rb。
RequiredEnvironment.verify!(AppEnvironment.current, ENV)
