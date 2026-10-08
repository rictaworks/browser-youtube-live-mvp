# 変異の確認用（PR #48 のテスト。mutation_check.sh が、backend コンテナの /tmp へ複写して、rspec の -r で読み込む）。
# 環境変数 MUTATION の名前で、アプリケーションの 1 か所を壊し、該当するスペックが落ちる（スペックが、その仕様を守っている）ことを確かめる。
# アプリケーションのファイルは書き換えない（実行中のプロセスの中で、メソッドを差し替えるだけ）。
module MutationCatalog
  def self.apply(name)
    method_name = "mutate_#{name}"
    raise "unknown mutation: #{name}" unless respond_to?(method_name)

    public_send(method_name)
  end

  # 何も壊さない（基準。変異なしで、スペックが緑であることを確かめる）
  def self.mutate_baseline
    nil
  end

  # --- ログインの手続き ---
  def self.mutate_login_state_unchecked
    LoginProcedure.class_eval do
      private

      def state_matches?(_expected, _given)
        true
      end
    end
  end

  def self.mutate_login_error_param_ignored
    LoginProcedure.class_eval do
      private

      def refusal_reason(payload, code, state, _error)
        return :state_cookie_invalid if payload.nil?
        return :state_mismatch unless state_matches?(payload.state, state)
        return :code_missing unless code.is_a?(String) && !code.strip.empty?

        nil
      end
    end
  end

  def self.mutate_login_last_login_not_updated
    LoginProcedure.class_eval do
      private

      def logged_in(registration, _now)
        Completion.new(status: :logged_in, user: registration.user, reason: nil)
      end
    end
  end

  # --- 疑似の Google ---
  def self.mutate_fake_pkce_unchecked
    FakeGoogleOidc.class_eval do
      private

      def verify_payload!(payload, _code_verifier, nonce, redirect_uri, now)
        failed!(:code_expired) if payload.fetch("exp") <= now.to_i
        failed!(:redirect_uri_mismatch) unless same?(payload.fetch("redirect_uri"), redirect_uri)
        failed!(:nonce_mismatch) unless same?(payload.fetch("nonce"), nonce)
      end
    end
  end

  def self.mutate_fake_code_unsigned
    FakeGoogleOidc.class_eval do
      private

      def sign(_encoded)
        "x"
      end
    end
  end

  def self.mutate_fake_allowed_in_production
    FakeServices.singleton_class.class_eval do
      def verify_environment!(_environment)
        nil
      end
    end
  end

  def self.mutate_production_selects_fake
    AppEnvironment.class_eval do
      def external_services
        :fake
      end
    end
  end

  # --- Google ログイン（実物） ---
  def self.mutate_oidc_nonce_unchecked
    GoogleOidcClient.class_eval do
      private

      def matches?(_actual, _expected)
        true
      end
    end
  end

  def self.mutate_oidc_exp_unchecked
    GoogleOidcClient.class_eval do
      private

      def verify_claims!(claims, nonce, now)
        iat = claims["iat"]
        failed!(:issued_in_future) if iat > now.to_f + IAT_LEEWAY_SECONDS
        failed!(:nonce_mismatch) unless matches?(claims["nonce"], nonce)
        failed!(:subject_invalid) unless claims["sub"].is_a?(String) && SUB_PATTERN.match?(claims["sub"])
      end
    end
  end

  def self.mutate_oidc_algorithms_widened
    GoogleOidcClient.class_eval do
      private

      def decode_options(now)
        {
          algorithms: %w[ RS256 HS256 none ],
          jwks: ->(options) { @jwks_cache.keys(now: now, invalidate: options[:invalidate] == true) },
          verify_iss: true, iss: @issuers, verify_aud: true, aud: @client_id,
          verify_expiration: false, verify_iat: false, required_claims: REQUIRED_CLAIMS
        }
      end
    end
  end

  def self.mutate_oidc_iss_unchecked
    GoogleOidcClient.class_eval do
      private

      def decode_options(now)
        {
          algorithms: ALGORITHMS,
          jwks: ->(options) { @jwks_cache.keys(now: now, invalidate: options[:invalidate] == true) },
          verify_iss: false, verify_aud: true, aud: @client_id,
          verify_expiration: false, verify_iat: false, required_claims: REQUIRED_CLAIMS
        }
      end
    end
  end

  def self.mutate_oidc_aud_unchecked
    GoogleOidcClient.class_eval do
      private

      def decode_options(now)
        {
          algorithms: ALGORITHMS,
          jwks: ->(options) { @jwks_cache.keys(now: now, invalidate: options[:invalidate] == true) },
          verify_iss: true, iss: @issuers, verify_aud: false,
          verify_expiration: false, verify_iat: false, required_claims: REQUIRED_CLAIMS
        }
      end
    end
  end

  def self.mutate_oidc_client_secret_not_sent
    GoogleOidcClient.class_eval do
      private

      def exchange_code(code, code_verifier, redirect_uri)
        response = @http.post_form(
          @token_endpoint,
          form: { code: code, client_id: @client_id, redirect_uri: redirect_uri, grant_type: "authorization_code", code_verifier: code_verifier }
        )
        rejected!(response.status) unless response.status == 200
        response.json.fetch("id_token")
      end
    end
  end

  def self.mutate_oidc_scope_widened
    GoogleOidcClient.class_eval do
      def authorization_url(state:, nonce:, code_challenge:, redirect_uri:)
        uri = URI.parse(@authorization_endpoint)
        uri.query = URI.encode_www_form(
          client_id: @client_id, redirect_uri: redirect_uri, response_type: "code", scope: "openid email profile",
          state: state, nonce: nonce, code_challenge: code_challenge, code_challenge_method: "S256"
        )
        uri.to_s
      end
    end
  end

  # --- 公開鍵のキャッシュ ---
  def self.mutate_jwks_stale_fallback
    GoogleJwksCache.class_eval do
      private

      def refresh(now)
        document = fetch_document
        @document = deep_freeze(document)
        @fetched_at = now
      rescue GoogleOidc::AuthenticationFailed
        raise if @document.nil?
      end
    end
  end

  # --- bot 判定 ---
  def self.mutate_recaptcha_remoteip_sent
    RecaptchaVerifier.class_eval do
      private

      def fetch_verification(token)
        response = @http.post_form(@endpoint, form: { secret: @secret, response: token, remoteip: "203.0.113.10" })
        conclude!(:indeterminate, :http_status) unless response.status == 200

        response.json
      rescue ExternalHttp::Failure => failure
        conclude!(:indeterminate, failure_reason(failure))
      end
    end
  end

  %w[ quota error_codes success action hostname challenge_ts ].each do |check|
    define_singleton_method("mutate_recaptcha_#{check}_unchecked") do
      RecaptchaVerifier.class_eval do
        private

        define_method("check_#{check}!") { |*_args| nil }
      end
    end
  end

  def self.mutate_recaptcha_score_boundary
    RecaptchaVerifier.class_eval do
      private

      def check_score!(body)
        score = body["score"]
        conclude!(:indeterminate, :score_invalid) unless score.is_a?(Numeric) && score.to_f.finite? && score.between?(0, 1)

        threshold = current_threshold
        conclude!(:fail, :low_score, score: score, threshold: threshold) if score <= threshold

        Assessment.new(verdict: :pass, reason: :ok, score: score, threshold: threshold)
      end
    end
  end

  def self.mutate_recaptcha_fail_open_on_unreachable
    RecaptchaVerifier.class_eval do
      private

      def failure_reason(_failure)
        raise Concluded.new(Assessment.new(verdict: :pass, reason: :ok, score: nil, threshold: nil))
      end
    end
  end

  # --- アカウント ---
  def self.mutate_registry_hold_ignored
    AccountRegistry.class_eval do
      private

      def held?(_google_sub, _now)
        false
      end
    end
  end

  def self.mutate_registry_hold_one_day_late
    AccountRegistry.class_eval do
      private

      def held?(google_sub, now)
        DeletionHold.where(sub_digest: digest(google_sub)).where("hold_usage_date >= ?", UsageCalendar.usage_date(now - 1.day)).exists?
      end
    end
  end

  def self.mutate_registry_digest_is_plain_sub
    AccountRegistry.class_eval do
      def digest(google_sub)
        google_sub
      end
    end
  end

  # --- 基盤・コントローラ ---
  def self.mutate_session_not_rotated
    Api::BaseController.class_eval do
      private

      def start_session!(user)
        issued = session_store.issue(user: user, now: current_time)
        cookies[SessionCookie::NAME] = SessionCookie.attributes(issued.token)
        @current_session = issued.session
        issued
      end
    end
  end

  def self.mutate_oauth_cookie_kept
    Api::BaseController.class_eval do
      private

      def consume_oauth_cookie(expected_purpose:)
        oauth_state_cookie.open(cookies[OAuthStateCookie::NAME], expected_purpose: expected_purpose, now: current_time)
      end
    end
  end

  def self.mutate_bot_check_skipped
    Api::AuthController.class_eval do
      private

      def verify_bot!(_token)
        nil
      end
    end
  end

  def self.mutate_bot_indeterminate_passes
    Api::AuthController.class_eval do
      private

      def verify_bot!(token)
        verdict = gateways.recaptcha_verifier.verify(token: token, expected_action: RECAPTCHA_ACTION, hostname: public_hostname, now: current_time)
        raise Api::Error::BotCheckFailed.new(reason: verdict) if verdict == :fail
      end
    end
  end

  def self.mutate_rate_limit_skipped
    Api::AuthController.class_eval do
      private

      def enforce_rate_limit!(*)
        nil
      end
    end
  end

  def self.mutate_redirect_to_backend_host
    Api::BaseController.class_eval do
      private

      def redirect_to_public(path)
        redirect_to "#{request.base_url}#{path}", allow_other_host: true, status: :found
      end
    end
  end

  def self.mutate_logout_keeps_session
    Api::BaseController.class_eval do
      private

      def end_session!
        response.delete_cookie(SessionCookie::NAME, SessionCookie.expiry_attributes)
        @current_session = nil
      end
    end
  end

  def self.mutate_p1_open_by_default
    Api::BaseController.class_eval do
      private

      def declared_login_policy!
        self.class.login_required_for?(action_name) ? :login : :anonymous
      end
    end
  end

  def self.mutate_cookie_secure_off
    CookiePolicy.singleton_class.class_eval do
      def secure?(*)
        false
      end
    end
  end

  def self.mutate_dev_open_redirect
    Dev::GoogleController.class_eval do
      private

      def valid_value?(name, value)
        return false unless value.is_a?(String)
        return value == EXPECTED_FIXED.fetch(name) if EXPECTED_FIXED.key?(name)
        return true if name == "redirect_uri"

        TOKEN_PATTERN.match?(value)
      end
    end
  end

  # --- 外部への HTTP ---
  def self.mutate_http_tls_unverified
    ExternalHttp.class_eval do
      private

      def build_connection(uri)
        connection = Net::HTTP.new(uri.host, uri.port, nil)
        connection.use_ssl = true
        connection.verify_mode = OpenSSL::SSL::VERIFY_NONE
        connection.min_version = OpenSSL::SSL::TLS1_2_VERSION
        connection.open_timeout = @connect_timeout
        connection.read_timeout = @read_timeout
        connection.write_timeout = @write_timeout
        connection.max_retries = 0
        connection
      end
    end
  end

  def self.mutate_http_timeouts_long
    ExternalHttp.class_eval do
      private

      def build_connection(uri)
        connection = Net::HTTP.new(uri.host, uri.port, nil)
        connection.use_ssl = true
        connection.verify_mode = OpenSSL::SSL::VERIFY_PEER
        connection.min_version = OpenSSL::SSL::TLS1_2_VERSION
        connection.open_timeout = 60
        connection.read_timeout = 60
        connection.write_timeout = 60
        connection.max_retries = 0
        connection
      end
    end
  end

  def self.mutate_http_follows_redirects
    ExternalHttp.class_eval do
      alias_method :original_request, :request

      def request(method, url, headers: {}, body: nil)
        response = original_request(method, url, headers: headers, body: body)
        location = response.headers["location"]
        response.status.between?(300, 399) && location ? original_request(method, location, headers: headers, body: body) : response
      end
    end
  end
end

RSpec.configure do |config|
  config.before(:suite) { MutationCatalog.apply(ENV.fetch("MUTATION")) }
end
