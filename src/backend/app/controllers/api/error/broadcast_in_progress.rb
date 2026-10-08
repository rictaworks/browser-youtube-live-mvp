# 終了していない配信がある（src/contracts/http-api.md 1.6。issue #11。requirements.md 7.4）。409 broadcast_in_progress。先に停止する。
# 進行中の配信がある間は、YouTube 接続の開始・再接続（POST /api/youtube/connect/start）を受け付けない。
# 接続の解除・アカウントの削除（#16）も、同じ符号を返す。reason は、ログ用の符号（応答には出さない）。
module Api
  class Error
    class BroadcastInProgress < Error
      def initialize(reason: nil)
        super(code: "broadcast_in_progress", status: 409, reason: reason)
      end
    end
  end
end
