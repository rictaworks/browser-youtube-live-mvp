# YouTube が未接続（src/contracts/http-api.md 1.6。issue #11）。409 not_connected。POST /api/youtube/recheck が返す。
# 接続の行が無い（解除した・まだ接続していない）。reason は、ログ用の符号（応答には出さない）。
module Api
  class Error
    class NotConnected < Error
      def initialize(reason: nil)
        super(code: "not_connected", status: 409, reason: reason)
      end
    end
  end
end
