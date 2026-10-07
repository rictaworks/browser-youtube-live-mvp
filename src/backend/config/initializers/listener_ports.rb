# 待ち受けの口の設定の検査（issue #7。requirements.md 6.1・11.9）。
# 公開側の口（環境変数 PORT。既定 3001）が、内部側の口（ServerPorts::INTERNAL = 3101）と同じなら、起動を失敗させる
# （同じ口なら、内部通信の経路が、公開側から到達できてしまう）。PORT が口の番号として読めない場合も、既定へ倒さず、失敗させる。
ListenerPort.verify_configuration!(ENV)
