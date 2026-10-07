# FactoryBot の create・build などを、スペックの中で直接呼べるようにする。
# ファクトリの定義は spec/factories（factory_bot_rails が、アプリケーションの初期化のあとに読み込む）。
require "factory_bot_rails"

RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods
end
