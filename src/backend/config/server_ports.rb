# 待ち受けの口の番号。設定の定数であり、環境変数ではない（新しい環境変数名を増やさない。requirements.md 6.1・11.9）。
# config/puma.rb が読み込む（Puma は Rails より先に設定を読むため、素の Ruby で書く）。
module ServerPorts
  # 公開側の口の既定値。環境変数 PORT があれば、それを使う（Railway が与える）。
  PUBLIC_DEFAULT = 3001

  # 内部通信の口（中継からアプリケーションへの一方向）。外部から到達できない経路でのみ受ける。
  # docker compose では、内部ネットワークだけに開き、ホストへ公開しない。
  INTERNAL = 3101
end
