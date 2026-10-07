# ルーティングの制約: 公開側の口の要求にだけ一致する（issue #7）。/api・/admin・/up は、公開側の口だけで応答する。
# 内部側の口の要求には一致せず、最後の経路（NotFoundApp）が 404 を返す。口の番号が分からない要求は、例外にする（公開側と見なさない）。
#
#   constraints(PublicListener.new) do
#     get "up" => "rails/health#show"
#     namespace(:api) { ... }
#   end
class PublicListener
  def matches?(request)
    ListenerPort.public?(request.env)
  end
end
