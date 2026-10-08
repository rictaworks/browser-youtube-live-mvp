# 外部サービス（Google・reCAPTCHA）への HTTP を、テストで差し替える補助（issue #8）。
#
# WebMock を有効にして、実際の外部サービスへの通信を、すべて禁止する（stub していない通信は、WebMock::NetConnectNotAllowedError）。
# spec/rails_helper.rb は spec/support を自動では読み込まない。外部への HTTP を呼ぶスペックは、先頭で
#   require "rails_helper"
#   require "support/external_http_support"
# とする。
require "webmock/rspec"

WebMock.disable_net_connect!

# 外部への HTTP を呼ぶスペックの共通の補助
module ExternalHttpSupport
  # Net::HTTP の接続の設定（タイムアウト・TLS の検証など）を、実際の通信なしで調べるための捕捉。
  # ブロックの間に作られた Net::HTTP の接続オブジェクトを、配列で返す
  def capture_connections(&block)
    connections = []
    allow(Net::HTTP).to receive(:new).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap { |connection| connections << connection }
    end
    block.call
    connections
  end
end

RSpec.configure do |config|
  config.include ExternalHttpSupport
end
