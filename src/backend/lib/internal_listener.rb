# ルーティングの制約: 内部側の口（3101）の要求にだけ一致する（issue #7）。/internal は、内部側の口だけで応答する
# （呼び出しは、中継からアプリケーションへの一方向。外部から到達できない経路でのみ受ける）。
# 公開側の口の要求には一致せず、最後の経路（NotFoundApp）が 404 を返す。口の番号が分からない要求は、例外にする（内部側と見なさない）。
#
#   constraints(InternalListener.new) do
#     namespace(:internal) { ... }
#   end
class InternalListener
  def matches?(request)
    ListenerPort.internal?(request.env)
  end
end
