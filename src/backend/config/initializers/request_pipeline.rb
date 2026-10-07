# 要求を受けるミドルウェアの構成（issue #7。requirements.md 6.1・28.1・28.2）。
#
#   1. ForwardedHeaders  先頭。X-Forwarded-*（IP・公開オリジン）を env から取り除いて、別の場所へ保管する。
#                        BFF の確認（X-BFF-Secret）を通った要求だけが、保管した値を読める。確認の前に、Rails・Rack が読まない
#                        （Rails の HostAuthorization が、X-Forwarded-Host も検査して、BFF の要求を拒否してしまう問題も、避ける）
#   2. ListenerPort      要求を受けた口の番号を、env["bl.listener_port"] に置く。口の番号が分からなければ、例外にする
#   3. RequestLogger     Rails 標準の Rails::Rack::Logger の代わり。要求の開始のログに、IP アドレスを出さない
#
# どれも lib/ にあり、再読み込みしない（config.autoload_lib_once）。標準の Logger と同じ位置・同じログのタグを使う。
Rails.application.config.middleware.insert_before 0, ForwardedHeaders
Rails.application.config.middleware.insert_after ForwardedHeaders, ListenerPort
Rails.application.config.middleware.swap Rails::Rack::Logger, RequestLogger, Rails.application.config.log_tags
