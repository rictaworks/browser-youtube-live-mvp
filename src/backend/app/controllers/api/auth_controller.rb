# 認証 API（src/contracts/http-api.md 3 章。issue #8。requirements.md 7.1・23.1・28.1）。
#
#   POST /api/auth/login/start   ログインの開始。入力の検証 → 頻度制限（IP 単位 30 回 / 時）→ bot 判定（行為名 login）→ 認可 URL を返す。
#                                state・nonce・PKCE の検証子は bl_oauth（暗号化・短命の Cookie）に持つ。測定イベント login_started
#   GET  /api/auth/callback      Google からの戻り先。state の照合 → コードの交換と ID トークンの検証 → sub でアカウントを特定（無ければ作成）→
#                                新しいセッションを発行（既存のセッションは破棄。セッション固定化の防止）→ 302 /studio。測定イベント login_completed。
#                                失敗は 302 /?login_error=oauth_failed、再登録の保留中は 302 /?login_error=registration_held。
#                                bl_oauth は、成功・失敗のどちらでも失効させる。リダイレクト先は、公開オリジン（PublicOrigin）から作る
#   POST /api/auth/logout        セッションを破棄し、bl_session を失効させる（204）。ログイン済みのみ（CSRF の対象）
#
# 手続きは LoginProcedure、アカウントの登録は AccountRegistry、Google・bot 判定は ExternalServices が選ぶ実装（環境の判定で、疑似 / 実物）。
# 認可の開始（login_start）とコールバックは、ログイン前の要求なので、CSRF トークンの検査の対象外（ログイン済みでないため）。
# 認可の開始は bl_oauth の state と PKCE で守る。メール・氏名・プロフィールを要求・保存しない。トークン・コード・state・sub をログに出さない。
module Api
  class AuthController < BaseController
    requires_login only: %i[ logout ]
    allow_anonymous only: %i[ login_start callback ]

    # reCAPTCHA の行為名（契約 1.8）
    RECAPTCHA_ACTION = "login".freeze
    # Google の戻り先（公開オリジンの経路）と、ログイン後の画面
    CALLBACK_PATH = "/api/auth/callback".freeze
    STUDIO_PATH = "/studio".freeze
    OAUTH_PURPOSE = "login".freeze

    def login_start
      token = recaptcha_token!
      enforce_rate_limit!(RateLimitPolicy.login_start, client_ip.to_s)
      verify_bot!(token)

      started = login_procedure.start(redirect_uri: callback_uri)
      issue_oauth_cookie(purpose: OAUTH_PURPOSE, state: started.state, nonce: started.nonce, code_verifier: started.code_verifier)
      UsageRecorder.record(user_id: nil, type: Contract::UsageEventType::LOGIN_STARTED)
      render json: { authorization_url: started.authorization_url }
    end

    def callback
      payload = open_oauth_state
      completion = login_procedure.complete(
        payload: payload, code: params[:code], state: params[:state], error: params[:error], redirect_uri: callback_uri, now: current_time
      )
      finish_login(completion)
    end

    def logout
      end_session!
      head :no_content
    end

    private

    # --- login_start ---

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

    # --- callback ---

    # bl_oauth の状態を取り出す（Cookie は、成功・失敗のどちらでも失効させる）。無い・改ざん・期限切れ・用途違いは nil
    def open_oauth_state
      consume_oauth_cookie(expected_purpose: OAUTH_PURPOSE)
    rescue OAuthStateCookie::InvalidCookie
      nil
    end

    def finish_login(completion)
      return redirect_to_public(login_error_path(Contract::LoginError::REGISTRATION_HELD)) if completion.held?
      return redirect_to_public(login_error_path(Contract::LoginError::OAUTH_FAILED)) if completion.failed?

      start_session!(completion.user)
      UsageRecorder.record(user_id: completion.user.id, type: Contract::UsageEventType::LOGIN_COMPLETED)
      redirect_to_public(STUDIO_PATH)
    end

    def login_error_path(code)
      "/?login_error=#{code}"
    end

    # --- 共通 ---

    def gateways
      @gateways ||= ExternalServices.current
    end

    def login_procedure
      @login_procedure ||= LoginProcedure.new(oidc: gateways.google_oidc)
    end

    # Google へ渡し、トークンの交換でも同じ値を使う戻り先（公開オリジンの /api/auth/callback）
    def callback_uri
      public_origin.url_for(CALLBACK_PATH)
    end

    # 公開オリジンのホスト名（ポートを除く）。bot 判定の発行元の検証に使う
    def public_hostname
      URI.parse(public_origin.to_s).host
    end
  end
end
