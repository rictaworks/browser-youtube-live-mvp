# bot 判定が不合格、または判定不能（src/contracts/http-api.md 1.6。issue #8）。403 bot_check_failed。
# 検証サービスに到達できない場合も、判定不能として、この符号で拒否する（受理側へ倒さない。requirements.md 9.3）。
# reason は、ログ用の判定の符号（fail・indeterminate。応答には出さない）。ログイン・YouTube 接続の開始が使う。
# 配信の開始の受付（POST /api/broadcasts）は、拒否の形が別（rejected）なので、これを使わない。
module Api
  class Error
    class BotCheckFailed < Error
      def initialize(reason: nil)
        super(code: "bot_check_failed", status: 403, reason: reason)
      end
    end
  end
end
