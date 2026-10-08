# /api の全コントローラの親（issue #7）。ブラウザ → フロントエンド（BFF）→ アプリケーションの HTTP API の共通の規約
# （src/contracts/http-api.md 1 章）を、ここで実装する。後続の API（#8・#11・#12・#16）は、これを継承する。
#
# 要求は、次の順に評価する（process_action。本体の動作・パラメータの解釈・ログのための解釈より前に行う）。
#   1. X-BFF-Secret（BFF の確認）                              403 forbidden
#   2. ログインの方針の宣言（requires_login か allow_anonymous のどちらか 1 つ）   500 internal_error（宣言が無い・矛盾。issue #8）
#   3. 状態を変える要求は、X-BL-Client: web                      403 csrf_invalid
#   4. 状態を変える要求で、ログイン済みなら X-CSRF-Token。Origin があれば、公開オリジンと一致   403 csrf_invalid
#   5. セッションの最終利用の更新（ここまでを通った要求だけ）
#   6. ログインが要る動作（requires_login）は、セッションが有効     401 not_logged_in
#   7. 動作の本体
# すべての動作は、requires_login（ログインが要る）か allow_anonymous（匿名で受ける）のどちらか 1 つを、明示して宣言する。
# 宣言を書き忘れた API が、匿名で到達できる事故を防ぐため（OWASP A01・A04）。宣言が無い動作・両方に宣言した動作は、本体を実行しない。
# 失敗は、契約のエラーの形（{"error":{"code","details"}}）で返す（未ログイン 401・CSRF 403・存在しない 404・不正な入力 422・
# 頻度 429・想定外の例外 500）。HTML のエラーページを返さない。すべての応答に Cache-Control: no-store を付ける。
#
# 想定外の例外は、500 internal_error（詳細を応答に出さない）。ログには、識別子（リクエスト ID）と原因（例外のクラスと、
# アプリケーションの発生の位置）を出す。例外のメッセージは、出さない（PostgreSQL の一意違反のメッセージは、キーの値を含む）。
#
# Rails 標準のセッション（Cookie ストア）・CSRF 対策（authenticity_token）は使わない（ActionController::API。自前の方式）。
# 共通の部品（start_session!・redirect_to_public・enforce_rate_limit! など）は、private（public のメソッドは、動作として扱われる）。
module Api
  class BaseController < ActionController::API
    include ActionController::Cookies

    # JSON の本文を、コントローラ名のキー（usage_event など）の下へ複製しない（契約の本文は、平らなキー。複製は、ログの Parameters を
    # 二重にし、本文の解釈を、動作より前（ParamsWrapper）へ持ち込む）
    wrap_parameters false

    # ログインが要る動作の規則（requires_login）・匿名で受ける動作の規則（allow_anonymous）。子クラスごとに持つ（親・別の子クラスへ影響しない）
    class_attribute :login_rule, instance_accessor: false, instance_predicate: false, default: nil
    class_attribute :anonymous_rule, instance_accessor: false, instance_predicate: false, default: nil

    # 動作の中で起きた例外は、ここで受けて、応答にする（Rails の計測の内側。ログの "Completed 404 Not Found" が、実際の状態になる）。
    # rescue_from は使わない。Rails は、rescue_from で受けた例外の、メッセージを、ログへ出す（"rescue_from handled ... (メッセージ)"）。
    # PostgreSQL の例外のメッセージは、キーの値を含むため、機密がログに出る。子クラスも、rescue_from を使わない
    # （動作に固有の例外は、動作の中で受けて、Api::Error にして、投げ直す）。
    # 確認（BFF・CSRF・ログイン）の失敗と、パラメータの解釈の失敗は、計測より外で起きるので、process_action が受ける。
    around_action :render_action_errors

    # 状態を変えない HTTP メソッド（CSRF の対象外）。ここに無いメソッドは、状態を変える要求として扱う（拒否側へ倒す）
    SAFE_METHODS = %w[ GET HEAD OPTIONS ].freeze

    CLIENT_HEADER = "HTTP_X_BL_CLIENT".freeze
    CLIENT_HEADER_VALUE = "web".freeze
    CSRF_HEADER = "HTTP_X_CSRF_TOKEN".freeze
    ORIGIN_HEADER = "HTTP_ORIGIN".freeze
    BFF_SECRET_HEADER = "HTTP_X_BFF_SECRET".freeze

    class << self
      # ログインが要る API の宣言。クラスの先頭に書く。only・except で、動作を絞れる（引数なしなら、すべての動作）。
      #   requires_login
      #   requires_login only: %i[ logout ]
      def requires_login(only: nil, except: nil)
        self.login_rule = build_rule(only, except)
      end

      # 匿名で受ける API の宣言（ログインしていなくても到達できる動作を、明示する）。書き方は requires_login と同じ。
      #   allow_anonymous only: %i[ login_start callback ]
      # 宣言が無い動作・requires_login と両方に宣言した動作は、要求時に 500 internal_error で拒否する（login_policy_for）。
      def allow_anonymous(only: nil, except: nil)
        self.anonymous_rule = build_rule(only, except)
      end

      def login_required_for?(action_name)
        rule_covers?(login_rule, action_name)
      end

      def anonymous_allowed_for?(action_name)
        rule_covers?(anonymous_rule, action_name)
      end

      # 動作ごとのログインの方針。
      #   :login        ログインが要る（requires_login）
      #   :anonymous    匿名で受ける（allow_anonymous）
      #   :undeclared   どちらも宣言していない（宣言し忘れ）
      #   :conflict     両方に宣言している（矛盾）
      # :login と :anonymous だけが、動作できる。
      def login_policy_for(action_name)
        login = login_required_for?(action_name)
        anonymous = anonymous_allowed_for?(action_name)
        return :conflict if login && anonymous
        return :login if login
        return :anonymous if anonymous

        :undeclared
      end

      private

      def build_rule(only, except)
        { only: Array(only).map(&:to_s).freeze, except: Array(except).map(&:to_s).freeze }.freeze
      end

      def rule_covers?(rule, action_name)
        return false if rule.nil?

        name = action_name.to_s
        return false if rule.fetch(:except).include?(name)

        rule.fetch(:only).empty? || rule.fetch(:only).include?(name)
      end
    end

    # どの経路にも当てはまらない /api の要求（config/routes.rb の /api の最後の経路）。BFF の確認・CSRF の検査のあと、404。
    # ログインの有無によらず 404 を返す（匿名と宣言する）。
    allow_anonymous only: :route_not_found

    def route_not_found
      raise Error::NotFound.new(reason: :route)
    end

    private

    # --- 要求の評価の順と、エラーの境界 ---

    # 動作・パラメータの解釈（ログのための解釈を含む）より前に、確認を行う。確認の失敗と、パラメータの解釈の失敗
    # （壊れた JSON の本文・壊れたクエリ文字列。Rails の計測が、ログのために、パラメータを解釈する）は、
    # rescue_from より外で起きるので、ここで受ける。確認が先なので、確認を通らない要求は、本文の不備ではなく、403 になる。
    def process_action(*)
      response.headers["Cache-Control"] = ApiErrorBody::CACHE_CONTROL
      authorize_request!
      super
    rescue StandardError => error
      render_error(error)
    end

    def render_action_errors
      yield
    rescue StandardError => error
      render_error(error)
    end

    def authorize_request!
      verify_bff!
      policy = declared_login_policy!
      verify_csrf! if state_changing_request?
      touch_session!
      require_login! if policy == :login
    end

    def state_changing_request?
      !SAFE_METHODS.include?(request.request_method)
    end

    # 1. フロントエンドからの要求であること（X-BFF-Secret を、定数時間で比較する）。確認を通った要求だけが、転送ヘッダを読める
    def verify_bff!
      @bff_request = BffGuard.from_environment(ENV).verify!(request.get_header(BFF_SECRET_HEADER), ForwardedHeaders.fetch(request.env))
    rescue BffGuard::Rejected
      raise Error::Forbidden.new(reason: :bff_secret_rejected)
    end

    # 2. ログインの方針の宣言（requires_login か allow_anonymous のどちらか 1 つ）。宣言が無い・矛盾する動作は、本体を実行せず、500。
    # 応答には詳細を出さない（internal_error）。原因（方針・コントローラ・動作・リクエスト ID）は、ログに出す。宣言された方針を返す
    def declared_login_policy!
      policy = self.class.login_policy_for(action_name)
      return policy if %i[ login anonymous ].include?(policy)

      logger.error("[api] login policy is not usable policy=#{policy} controller=#{self.class.name} action=#{action_name} request_id=#{request.request_id}")
      raise Error::InternalError.new(reason: :"login_policy_#{policy}")
    end

    # 3・4. X-BL-Client: web。Origin（あれば）が公開オリジンと一致すること。ログイン済みなら、X-CSRF-Token
    def verify_csrf!
      raise Error::CsrfInvalid.new(reason: :client_header) unless request.get_header(CLIENT_HEADER) == CLIENT_HEADER_VALUE

      verify_origin!
      verify_csrf_token!
    end

    def verify_origin!
      origin = request.get_header(ORIGIN_HEADER)
      return if origin.nil?
      raise Error::CsrfInvalid.new(reason: :origin_mismatch) unless public_origin.matches_origin?(origin)
    rescue PublicOrigin::InvalidError
      # 公開オリジンが分からず、照合できない。拒否側へ倒す
      raise Error::CsrfInvalid.new(reason: :origin_unverifiable)
    end

    def verify_csrf_token!
      return if current_session.nil?

      provided = request.get_header(CSRF_HEADER)
      raise Error::CsrfInvalid.new(reason: :token_mismatch) unless csrf.valid?(session_token, provided)
    end

    # セッションが有効なら、最終利用を更新する（BFF の確認・CSRF の検査を通った要求だけ）
    def touch_session!
      session_store.touch(current_session, now: current_time) if current_session
    end

    def require_login!
      raise Error::NotLoggedIn.new(reason: :no_session) unless current_user
    end

    # --- エラーの応答 ---

    def render_error(error)
      api_error = translate(error)
      log_error(api_error, error)
      return if performed?

      render json: ApiErrorBody.build(api_error.code, api_error.details), status: api_error.status
    end

    # 例外を、API のエラーへ対応づける
    def translate(error)
      case error
      when Error then error
      when ActiveRecord::RecordNotFound then Error::NotFound.new(reason: :record_not_found)
      when ActionController::ParameterMissing then Error::InvalidInput.new(fields: [ error.param ], reason: :parameter_missing)
      when ActionController::BadRequest, ActionDispatch::Http::Parameters::ParseError
        Error::InvalidInput.new(reason: :unparsable_request)
      else Error::InternalError.new(reason: :unexpected)
      end
    end

    # ログへ出すのは、符号・理由・リクエスト ID と、想定外の例外のときの原因（クラスと位置）だけ。例外のメッセージは出さない
    def log_error(api_error, error)
      if api_error.is_a?(Error::InternalError)
        logger.error("[api] internal_error status=#{api_error.status} request_id=#{request.request_id} #{describe_cause(error)}")
      elsif api_error.reason
        logger.info("[api] rejected code=#{api_error.code} status=#{api_error.status} reason=#{api_error.reason} request_id=#{request.request_id}")
      end
    end

    # 例外のクラスと、アプリケーションの発生の位置（gem・フレームワークを除いた、先頭の 1 件）。原因（cause）のクラス
    def describe_cause(error)
      location = Rails.backtrace_cleaner.clean(error.backtrace || []).first
      parts = [ "error_class=#{error.class.name}", "at=#{location.inspect}" ]
      parts << "cause_class=#{error.cause.class.name}" if error.cause
      parts.join(" ")
    end

    # --- 要求から得るもの（確認を通った要求） ---

    def verified_bff
      @bff_request || raise(ForwardedHeaders::NotInstalledError, "BFF request has not been verified")
    end

    # 利用者の IP（X-Forwarded-For の先頭）。頻度制限の計数にだけ使う。DB・測定イベント・ログへ記録しない
    def client_ip
      verified_bff.client_ip
    end

    # 公開オリジン（フロントエンドのオリジン）。無い・正しくなければ PublicOrigin::InvalidError（500）
    def public_origin
      verified_bff.public_origin
    end

    # リダイレクト（302）。Location は、公開オリジンの絶対 URL（バックエンドのホストを含めない）。path は / で始まる経路
    def redirect_to_public(path)
      redirect_to public_origin.url_for(path), allow_other_host: true, status: :found
    end

    # --- セッション ---

    def session_cookie_value
      cookies[SessionCookie::NAME]
    end

    alias_method :session_token, :session_cookie_value

    # 現在のセッション（有効なものだけ。Cookie の識別子から、サーバー側で検索する）。1 回の要求で、検索は 1 回
    def current_session
      return @current_session if defined?(@current_session)

      token = session_cookie_value
      @current_session = token.nil? ? nil : session_store.find(token, now: current_time)
    end

    # 現在のアカウント。セッションからだけ得る（本文・ヘッダ・クエリでは、指定できない）
    def current_user
      current_session&.user
    end

    # 現在のセッションに紐づく CSRF トークン（GET /api/state が返す値）。ログインしていなければ nil
    def csrf_token
      current_session && csrf.derive(session_token)
    end

    # ログインの成立。新しいセッションを発行して、Cookie を設定する（既存のセッションは破棄する。セッション固定化の防止）
    def start_session!(user)
      session_store.revoke(current_session) if current_session
      issued = session_store.issue(user: user, now: current_time)
      cookies[SessionCookie::NAME] = SessionCookie.attributes(issued.token)
      @current_session = issued.session
      issued
    end

    # ログアウト。セッションを破棄して、Cookie を失効させる
    def end_session!
      session_store.revoke(current_session) if current_session
      response.delete_cookie(SessionCookie::NAME, SessionCookie.expiry_attributes)
      @current_session = nil
    end

    # --- 認可の途中の状態（bl_oauth） ---

    # 認可の開始。状態を暗号化して、短命の Cookie に入れる（purpose は login または connect。connect は、内部のアカウント識別子が要る）
    def issue_oauth_cookie(purpose:, state:, nonce:, code_verifier:, user_id: nil)
      sealed = oauth_state_cookie.seal(
        state: state, nonce: nonce, code_verifier: code_verifier, purpose: purpose, user_id: user_id, now: current_time
      )
      cookies[OAuthStateCookie::NAME] = OAuthStateCookie.attributes(sealed)
    end

    # 認可の完了（コールバック）。Cookie の状態を取り出し、Cookie を失効させる（成功・失敗のどちらでも。state の再利用を防ぐ）。
    # 無効（Cookie が無い・改ざん・期限切れ・用途違い）なら OAuthStateCookie::InvalidCookie
    def consume_oauth_cookie(expected_purpose:)
      sealed = cookies[OAuthStateCookie::NAME]
      response.delete_cookie(OAuthStateCookie::NAME, OAuthStateCookie.expiry_attributes)
      oauth_state_cookie.open(sealed, expected_purpose: expected_purpose, now: current_time)
    end

    # --- 頻度制限 ---

    # 方針（RateLimitPolicy）を、対象（IP・アカウント識別子の文字列）で評価する。超過なら 429 rate_limited（retry_at）
    def enforce_rate_limit!(policy, subject)
      result = RateLimiter.shared.check(policy, subject)
      raise Error::RateLimited.new(retry_at: result.retry_at, reason: :rate_limited) unless result.allowed?
    end

    # --- 部品（要求ごとに作る。秘密値は、Rails の secret_key_base = SESSION_SECRET） ---

    def session_store
      @session_store ||= SessionStore.new
    end

    def csrf
      @csrf ||= CsrfToken.new(secret: Rails.application.secret_key_base)
    end

    def oauth_state_cookie
      @oauth_state_cookie ||= OAuthStateCookie.new(secret: Rails.application.secret_key_base)
    end

    def current_time
      SystemClock.now
    end
  end
end
