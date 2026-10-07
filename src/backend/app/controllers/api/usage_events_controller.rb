# POST /api/usage-events（src/contracts/http-api.md 3 章。requirements.md 18.2・28.2。issue #7）。
# ログイン済みのブラウザが、測定イベントを送る。ベストエフォート（失敗しても、配信を妨げない）。204 を返す。
#
# ブラウザが送れる種別は、capability_detected・source_granted・source_denied・line_measured・watch_url_copied の 5 つだけ
# （それ以外は 422 unsupported_event）。ほかの測定イベントは、サーバーが記録する。
# 数値（value）は、区分に変換して記録する。測定イベントは、内部のアカウント識別子（セッションのアカウント）にだけ紐づける。
# 氏名・メールアドレス・チャンネル名・タイトル・IP・端末を特定する文字列は、受け取らない・保存しない。
module Api
  class UsageEventsController < BaseController
    requires_login

    def create
      event = BrowserUsageEvent.parse(request.request_parameters)
      UsageRecorder.record(
        user_id: current_user.id, type: event.type, reason_code: event.reason_code,
        bucket: event.bucket, browser_class: event.browser_class
      )
      head :no_content
    rescue BrowserUsageEvent::InvalidInput => error
      raise Error::InvalidInput.new(fields: error.fields, reason: :invalid_input)
    rescue BrowserUsageEvent::UnsupportedType
      raise Error::UnsupportedEvent.new(reason: :unsupported_event)
    end
  end
end
