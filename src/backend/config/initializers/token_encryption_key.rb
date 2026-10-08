# 更新トークンの暗号鍵（TOKEN_ENCRYPTION_KEY）の形式の検査（issue #11。#10 のレビューの申し送り。requirements.md 7.3・28.1・29.4）。
#
# 鍵は、64 桁の 16 進数（32 バイト）。形式の検査（TokenVault.parse_key）が、初回の使用時にしか働かないと、形式の誤りが、
# 最初の YouTube 接続（利用者の操作）まで見つからない。そこで、起動時に検査し、設定されていて形式が誤りなら、環境を問わず
# （開発・テスト・本番のすべてで）起動を失敗させる。例外のメッセージは、変数の名前と期待する形式だけ（鍵の値を書かない）。
#
# 未設定・空・空白だけは、この検査では通す。本番は、必須の環境変数の検査（config/required_environment.rb）が、先に起動を失敗させる。
# 開発・テストは、疑似を使う最初の使用（YouTubeServices）で止まる（CI は、鍵なしで DB の準備と RSpec を動かす）。
#
# TokenVault は、アプリケーションの定数（app/gateways）なので、イニシャライザの本体では参照できない（読み込みの設定の後）。
# 初期化が終わった後（after_initialize）に検査する。
Rails.application.config.after_initialize do
  key = ENV[TokenVault::KEY_NAME]
  TokenVault.parse_key(key) unless key.to_s.strip.empty?
end
