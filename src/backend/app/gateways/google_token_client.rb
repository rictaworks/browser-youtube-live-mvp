require "zlib"

# Google のトークンエンドポイントとの通信（issue #10。requirements.md 7.3・10.6）。TokenVault が使う。
#
#   refresh  更新トークンから、アクセストークンを得る（grant_type=refresh_token。クライアントの資格情報を送る）
#   revoke   トークンを失効させる（接続の解除）。Google は、そのプロジェクトに付与した全スコープを取り消す
#
# 失敗の分類（呼び出し側 = TokenVault が、これで動く）
#   恒久   400 などの invalid_grant（取り消し・期限切れ・アカウントの削除）   YouTubeErrors::TokenRevoked
#   一時   通信の失敗（タイムアウト・接続・TLS）・429・5xx                    YouTubeErrors::TokenTemporarilyUnavailable（状態を変えない）
#   想定外 invalid_client（クライアントの設定の誤り）・形の違う応答・リダイレクト・404 など   YouTubeErrors::UnexpectedResponse（状態を変えない）
# 5xx の本文が invalid_grant を含んでいても、一時的な失敗として扱う（恒久と取り違えて、接続を失効させない）。
# NotFound など、清算の呼び出しが「清算済み」と取り違える例外は、ここからは出さない。
#
# 通信は ExternalHttp（接続 3 秒・読み取り 5 秒・リダイレクトを追わない・再送しない）。
# 更新トークン・アクセストークン・クライアントの秘密値・応答の本文を、ログ・例外・inspect に出さない（ログは符号だけ）。
class GoogleTokenClient
  LOG_TAG = "[google_token]".freeze

  # トークンの形（印字できる ASCII。空白・改行・制御文字を含まない。Authorization ヘッダにそのまま使える）
  TOKEN_PATTERN = /\A[\x21-\x7E]{1,4096}\z/
  # アクセストークンの有効秒数として受け付ける範囲（Google は 3599 前後）
  EXPIRES_IN_RANGE = (1..86_400)
  # 通信の失敗のうち、一時的なもの（ExternalHttp::Failure の符号）
  TEMPORARY_CAUSES = %i[ timeout connection tls ].freeze
  # 恒久の失敗を表す、OAuth のエラー符号（更新）・すでに失効している印（失効）
  REVOKED_CODE = "invalid_grant".freeze
  ALREADY_INVALID_CODE = "invalid_token".freeze
  TOO_MANY_REQUESTS = 429
  SERVER_ERROR_FROM = 500
  # 応答の gzip が壊れていた（Zlib::Error）ときの detail の符号
  INVALID_ENCODING = :invalid_encoding

  # 更新の結果。アクセストークン（秘密）と有効秒数。inspect・to_s・pretty_inspect にトークンを出さない
  class Tokens
    attr_reader :access_token, :expires_in

    def initialize(access_token:, expires_in:)
      raise ArgumentError, "access_token must be a printable token without whitespace" unless access_token.is_a?(String) && TOKEN_PATTERN.match?(access_token)
      raise ArgumentError, "expires_in must be an Integer in #{EXPIRES_IN_RANGE}" unless expires_in.is_a?(Integer) && EXPIRES_IN_RANGE.cover?(expires_in)

      @access_token = access_token.dup.freeze
      @expires_in = expires_in
      freeze
    end

    def inspect
      "#<#{self.class.name} access_token=[FILTERED] expires_in=#{expires_in}>"
    end

    def to_s
      inspect
    end
  end

  def initialize(client_id:, client_secret:, http:, endpoints:, logger: Rails.logger)
    @client_id = non_blank!(client_id, "client_id")
    @client_secret = non_blank!(client_secret, "client_secret")
    @token_endpoint = https_endpoint!(endpoints, :token_endpoint)
    @revoke_endpoint = https_endpoint!(endpoints, :revoke_endpoint)
    @http = http
    @logger = logger
  end

  # 更新トークンから、アクセストークンを得る。失敗は YouTubeErrors::TokenRevoked・TokenTemporarilyUnavailable・UnexpectedResponse
  def refresh(refresh_token:)
    token = token!(refresh_token, "refresh_token")
    form = { client_id: @client_id, client_secret: @client_secret, refresh_token: token, grant_type: "refresh_token" }

    response = post(@token_endpoint, :token_refresh, form)
    return tokens_from(response) if response.status == 200

    raise failure_for(response, :token_refresh, revoked_code: REVOKED_CODE)
  end

  # トークンを失効させる。成功は :revoked、すでに失効している（invalid_token）は :already_invalid。
  # 失敗は YouTubeErrors::TokenTemporarilyUnavailable・UnexpectedResponse
  def revoke(token:)
    value = token!(token, "token")

    response = post(@revoke_endpoint, :token_revoke, { token: value })
    return :revoked if response.status == 200
    return :already_invalid if response.status == 400 && error_code(response) == ALREADY_INVALID_CODE

    raise failure_for(response, :token_revoke)
  end

  # クライアント ID・秘密値を出さない
  def inspect
    "#<#{self.class.name}>"
  end

  private

  # フォームで送る。通信の失敗は、型付きの例外にして投げる（ログは、符号だけ）。
  # ExternalHttp は Zlib::Error を受け止めない（壊れた gzip は、生の例外になり得る）ので、ここで型付きの例外にする
  def post(url, call_kind, form)
    @http.post_form(url, form: form)
  rescue ExternalHttp::Failure => failure
    raise logged(communication_error(failure, call_kind))
  rescue Zlib::Error
    raise logged(YouTubeErrors::UnexpectedResponse.new(call_kind: call_kind, detail: INVALID_ENCODING))
  end

  def communication_error(failure, call_kind)
    error_class = TEMPORARY_CAUSES.include?(failure.reason) ? YouTubeErrors::TokenTemporarilyUnavailable : YouTubeErrors::UnexpectedResponse
    error_class.new(call_kind: call_kind, detail: failure.reason)
  end

  # 200 以外の応答を、型付きの例外にする（投げずに返す。ログは、符号だけ）
  def failure_for(response, call_kind, revoked_code: nil)
    status = response.status
    code = error_code(response)
    error = if revoked_code && code == revoked_code && status < SERVER_ERROR_FROM
      YouTubeErrors::TokenRevoked.new(call_kind: call_kind, status: status, reason: code)
    elsif status == TOO_MANY_REQUESTS || status >= SERVER_ERROR_FROM
      YouTubeErrors::TokenTemporarilyUnavailable.new(call_kind: call_kind, status: status, reason: code)
    else
      YouTubeErrors::UnexpectedResponse.new(call_kind: call_kind, status: status, reason: code)
    end
    logged(error)
  end

  def tokens_from(response)
    body = response.json
    raise unexpected(:token_response_invalid) unless body.is_a?(Hash)

    Tokens.new(access_token: body["access_token"], expires_in: body["expires_in"])
  rescue ExternalHttp::Failure => failure
    raise unexpected(failure.reason)
  rescue ArgumentError
    raise unexpected(:token_response_invalid)
  end

  def unexpected(detail)
    logged(YouTubeErrors::UnexpectedResponse.new(call_kind: :token_refresh, status: 200, detail: detail))
  end

  # 応答の本文の error（OAuth のエラー符号）。符号の形でなければ nil（本文は、ログにも例外にも出さない）
  def error_code(response)
    payload = response.json
    code = payload["error"] if payload.is_a?(Hash)
    code if code.is_a?(String) && YouTubeErrors::SAFE_CODE.match?(code)
  rescue ExternalHttp::Failure
    nil
  end

  def logged(error)
    @logger.warn("#{LOG_TAG} failed #{error.message}")
    error
  end

  def token!(value, name)
    raise ArgumentError, "#{name} must be a non-empty token String" unless value.is_a?(String) && !value.strip.empty?

    value
  end

  def non_blank!(value, name)
    raise ArgumentError, "#{name} must be a non-empty String" unless value.is_a?(String) && !value.strip.empty?

    value
  end

  def https_endpoint!(endpoints, key)
    value = endpoints[key]
    raise ArgumentError, "endpoints must have an https URL for #{key}" unless value.is_a?(String) && value.start_with?("https://")

    value
  end
end
