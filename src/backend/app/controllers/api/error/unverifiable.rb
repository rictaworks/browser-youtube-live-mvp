# 確認できない（src/contracts/http-api.md 1.6。issue #11。requirements.md 7.2）。503 unverifiable。POST /api/youtube/recheck が返す。
# 共通枠の枯渇・一時的な失敗・チャンネルが見つからない。接続状態は変更しない。reason は、ログ用の符号（応答には出さない）。
module Api
  class Error
    class Unverifiable < Error
      def initialize(reason: nil)
        super(code: "unverifiable", status: 503, reason: reason)
      end
    end
  end
end
