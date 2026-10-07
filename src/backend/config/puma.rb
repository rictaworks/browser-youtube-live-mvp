# Puma の設定。
#
# 公開側の口（PORT。既定 3001）と、内部通信の口（3101）の 2 つで待ち受ける（requirements.md 6.1・11.9）。
# 口の番号は config/server_ports.rb の定数。内部側の口は、docker compose の内部ネットワークだけに開く。
# 公開側と内部側で応答する経路を分ける実装は、この設定の外（ルーティング）で行う。
#
# 起動は `bundle exec puma -C config/puma.rb`（`bin/rails server` は -p・-b の指定で、ここの口を上書きするため使わない）。
require_relative "server_ports"

threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

port ENV.fetch("PORT", ServerPorts::PUBLIC_DEFAULT)
port ServerPorts::INTERNAL
