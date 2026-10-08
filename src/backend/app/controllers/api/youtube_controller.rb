# YouTube 接続の API（src/contracts/http-api.md 3 章。issue #11。requirements.md 7.2・7.3・23.1・28.1）。
#
#   POST /api/youtube/connect/start     接続の開始（段階的な認可）。入力の検証 -> 進行中の配信（接続・再接続を受け付けない）-> 頻度制限（IP 単位 30 回 / 時）->
#                                       bot 判定（行為名 youtube_connect）-> 認可 URL を返す。state・PKCE の検証子は bl_oauth（暗号化・短命の Cookie。用途 connect と
#                                       内部のアカウント識別子つき）に持つ。測定イベント connect_started
#   GET  /api/youtube/connect/callback  Google からの戻り先。bl_oauth の state の照合・ログイン中のセッションのアカウントとの一致・コードの交換・接続時の確認
#                                       -> 302 /account?connect=<connect_result>（公開オリジンの絶対 URL）。測定イベント connect_completed / connect_failed。
#                                       bl_oauth は、成功・失敗のどちらでも失効させる。ブラウザの遷移なので、ログインしていなくても受けて（匿名と宣言する）、
#                                       アカウントとの不一致として unverifiable で戻す（JSON の 401 を、画面に出さない）。CSRF の対象外（state で守る）
#   POST /api/youtube/recheck           再確認（ライブ配信が有効かの確認）。アカウント単位で 1 分に 1 回・1 日 20 回（超過は 429 rate_limited・retry_at）。
#                                       接続が無ければ 409 not_connected。認可失効は再確認せず 200（state: revoked）。接続済み・ライブ未有効のとき、チャンネルと
#                                       ライブの有効を再確認し、connected と live_not_enabled を更新して 200 {"youtube":{state, channel_title: null, can_recheck_at}}。
#                                       確認不能（共通枠の枯渇・一時的な失敗・チャンネルが見つからない）は 503 unverifiable（接続状態は変更しない）
#
# 手続きは YouTubeConnectService（HTTP・Cookie・セッションを知らない）。Google・bot 判定は ExternalServices、YouTube は YouTubeServices が選ぶ実装
# （環境の判定で、疑似 / 実物）。トークン・コード・state・検証子・チャンネル名・sub を、ログ・応答に出さない。
module Api
  class YoutubeController < BaseController
    requires_login only: %i[ connect_start recheck ]
    allow_anonymous only: %i[ connect_callback ]

    # reCAPTCHA の行為名（契約 1.8）
    RECAPTCHA_ACTION = "youtube_connect".freeze
    # Google の戻り先（公開オリジンの経路）と、接続の結果を伝えるアカウント画面（/account?connect=<connect_result>）
    CALLBACK_PATH = "/api/youtube/connect/callback".freeze
    ACCOUNT_PATH = "/account".freeze
    CONNECT_QUERY = "connect".freeze

    def connect_start
      token = recaptcha_token!
      raise Error::BroadcastInProgress.new(reason: :broadcast_in_progress) if connect_service.broadcast_in_progress?(current_user)

      enforce_rate_limit!(RateLimitPolicy.connect_start, client_ip.to_s)
      verify_bot!(token)

      started = connect_service.start(user: current_user, redirect_uri: callback_uri)
      issue_oauth_cookie(
        purpose: YouTubeConnectService::OAUTH_PURPOSE, state: started.state, nonce: started.nonce,
        code_verifier: started.code_verifier, user_id: current_user.id
      )
      UsageRecorder.record(user_id: current_user.id, type: Contract::UsageEventType::CONNECT_STARTED)
      render json: { authorization_url: started.authorization_url }
    end

    def connect_callback
      payload = open_oauth_state
      completion = connect_service.complete(
        user: current_user, payload: payload, code: params[:code], state: params[:state], error: params[:error],
        redirect_uri: callback_uri, now: current_time
      )
      record_connect_event(completion)
      redirect_to_public("#{ACCOUNT_PATH}?#{CONNECT_QUERY}=#{completion.result}")
    end

    def recheck
      enforce_rate_limit!(RateLimitPolicy.recheck, current_user.id)

      outcome = connect_service.recheck(user: current_user, now: current_time)
      raise Error::NotConnected.new(reason: :not_connected) if outcome.not_connected?
      raise Error::Unverifiable.new(reason: :recheck_unverifiable) if outcome.unverifiable?

      render json: { youtube: youtube_view(outcome.state) }
    end

    private

    # --- connect_start ---

    # recaptcha_token: 空でない文字列（長すぎない）。そうでなければ 422 invalid_input
    def recaptcha_token!
      token = params[:recaptcha_token]
      valid = token.is_a?(String) && !token.strip.empty? && token.length <= RecaptchaVerifier::TOKEN_MAX_LENGTH
      raise Error::InvalidInput.new(fields: %w[ recaptcha_token ], reason: :recaptcha_token_invalid) unless valid

      token
    end

    # bot 判定。不合格・判定不能（検証サービスに届かない場合を含む）は、403 bot_check_failed（受理側へ倒さない）
    def verify_bot!(token)
      verdict = gateways.recaptcha_verifier.verify(
        token: token, expected_action: RECAPTCHA_ACTION, hostname: public_hostname, now: current_time
      )
      raise Error::BotCheckFailed.new(reason: verdict) unless verdict == :pass
    end

    # --- connect_callback ---

    # bl_oauth の状態を取り出す（Cookie は、成功・失敗のどちらでも失効させる）。無い・改ざん・期限切れ・用途違いは nil
    def open_oauth_state
      consume_oauth_cookie(expected_purpose: YouTubeConnectService::OAUTH_PURPOSE)
    rescue OAuthStateCookie::InvalidCookie
      nil
    end

    # 成立は connect_completed、不成立は connect_failed。理由の符号（結果）だけを残す。ログインしていなければ、アカウントに紐づけない
    def record_connect_event(completion)
      type = completion.success? ? Contract::UsageEventType::CONNECT_COMPLETED : Contract::UsageEventType::CONNECT_FAILED
      UsageRecorder.record(user_id: current_user&.id, type: type, reason_code: completion.result)
    end

    # --- recheck ---

    # 契約 2.3 の youtube。channel_title は常に null（チャンネル名は GET /api/state?with_channel=1 だけが返す）。
    # can_recheck_at は、次に再確認できる時刻（今の要求の分を数えたあと。無ければ null）。秒の端数は切り上げる
    def youtube_view(state)
      { state: state, channel_title: nil, can_recheck_at: recheck_gate.next_allowed_at(current_user)&.ceil&.iso8601 }
    end

    # --- 共通 ---

    def gateways
      @gateways ||= ExternalServices.current
    end

    def connect_service
      @connect_service ||= YouTubeConnectService.current
    end

    def recheck_gate
      @recheck_gate ||= RecheckGate.new
    end

    # Google へ渡し、コードの交換でも同じ値を使う戻り先（公開オリジンの /api/youtube/connect/callback）
    def callback_uri
      public_origin.url_for(CALLBACK_PATH)
    end

    # 公開オリジンのホスト名（ポートを除く）。bot 判定の発行元の検証に使う
    def public_hostname
      URI.parse(public_origin.to_s).host
    end
  end
end
