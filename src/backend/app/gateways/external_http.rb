require "net/http"
require "openssl"
require "uri"

# 外部サービスへの HTTPS 呼び出しの共通の窓口（issue #8。requirements.md 6.1・28.1）。
# Google の認可・トークン・公開鍵・reCAPTCHA の検証（#8）、YouTube API（#10）、YouTube 接続（#11）が使う。汎用で小さく作る。
#
#   接続 3 秒・読み取り 5 秒（書き込みも 5 秒）。リダイレクトを追わない（3xx は、そのまま応答として返す）。
#   TLS の証明書を検証する（VERIFY_PEER。TLS 1.2 以上）。https 以外の URL は使えない。環境変数のプロキシを使わない。
#   要求の再送をしない（Net::HTTP の既定は、失敗した冪等な要求を 1 回再送する。呼び出しの回数を、呼び出し側が数えられるように）。
#   応答の本文は 1 MiB まで（超えたら Failure。メモリを使い切らない）。
#
# 2xx 以外の応答も、例外にせず、Response として返す（状態で判断するのは、呼び出し側）。
# 通信の失敗（タイムアウト・接続・TLS・大きすぎる応答・解釈できない JSON）は、ExternalHttp::Failure（原因の符号とホストだけを持つ）。
# URL・ヘッダ・本文の誤りは、呼び出しの誤りなので ArgumentError（URL は設定から来る。利用者の入力を、URL にしない）。
#
# 機密を出さない。ログにも、例外のメッセージにも、URL（クエリを含む）・ヘッダの値・要求の本文・応答の本文を含めない。
# 出すのは、メソッド・ホスト・原因の符号だけ。Response#inspect も、本文とヘッダを伏せる（トークンを含みうる）。
class ExternalHttp
  CONNECT_TIMEOUT_SECONDS = 3
  READ_TIMEOUT_SECONDS = 5
  WRITE_TIMEOUT_SECONDS = 5
  MAX_BODY_BYTES = 1_048_576 # 1 MiB
  LOG_TAG = "[external_http]".freeze

  FORM_CONTENT_TYPE = "application/x-www-form-urlencoded".freeze
  JSON_CONTENT_TYPE = "application/json".freeze
  ACCEPT_JSON = "application/json".freeze

  REQUEST_CLASSES = {
    get: Net::HTTP::Get,
    post: Net::HTTP::Post,
    put: Net::HTTP::Put,
    patch: Net::HTTP::Patch,
    delete: Net::HTTP::Delete
  }.freeze

  HEADER_NAME = /\A[A-Za-z0-9!#$%&'*+.^_`|~-]+\z/
  # 改行・NUL を含む値は、別のヘッダを注入できる
  FORBIDDEN_IN_HEADER_VALUE = /[\r\n\0]/

  # 通信の失敗。reason は符号（:timeout・:connection・:tls・:response_too_large・:invalid_json）。host は相手のホスト。
  # メッセージは、符号とホストだけ（URL・クエリ・本文を含めない）。
  class Failure < StandardError
    attr_reader :reason, :host

    def initialize(reason, host: nil)
      @reason = reason
      @host = host
      super([ "external_http_failure", "reason=#{reason}", ("host=#{host}" if host) ].compact.join(" "))
    end
  end

  # 応答。headers の名前は小文字。body は UTF-8 の文字列（トークンを含みうるので、inspect に出さない）。
  Response = Data.define(:status, :headers, :body, :host) do
    def success?
      (200..299).cover?(status)
    end

    # 本文を JSON として解釈する。解釈できなければ Failure（invalid_json）
    def json
      JSON.parse(body)
    rescue JSON::ParserError, EncodingError
      raise Failure.new(:invalid_json, host: host)
    end

    def inspect
      "#<#{self.class.name} status=#{status} host=#{host} [FILTERED]>"
    end

    def to_s
      inspect
    end
  end

  def initialize(connect_timeout: CONNECT_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS, max_body_bytes: MAX_BODY_BYTES,
                 logger: Rails.logger)
    @connect_timeout = positive_number!(connect_timeout, "connect_timeout")
    @read_timeout = positive_number!(read_timeout, "read_timeout")
    @write_timeout = WRITE_TIMEOUT_SECONDS
    unless max_body_bytes.is_a?(Integer) && max_body_bytes.positive?
      raise ArgumentError, "max_body_bytes must be a positive Integer"
    end

    @max_body_bytes = max_body_bytes
    @logger = logger
  end

  def get(url, headers: {})
    request(:get, url, headers: headers)
  end

  # form は、名前と値の Hash（値は文字列に変換して符号化する）
  def post_form(url, form:, headers: {})
    request(:post, url, headers: headers.merge("Content-Type" => FORM_CONTENT_TYPE), body: URI.encode_www_form(form))
  end

  def post_json(url, json:, headers: {})
    request(:post, url, headers: headers.merge("Content-Type" => JSON_CONTENT_TYPE), body: JSON.generate(json))
  end

  # method は :get・:post・:put・:patch・:delete。body は文字列（無ければ nil）
  def request(method, url, headers: {}, body: nil)
    request_class = REQUEST_CLASSES.fetch(method) do
      raise ArgumentError, "method must be one of: #{REQUEST_CLASSES.keys.join(', ')}"
    end
    uri = parse_url(url)
    validate_headers!(headers)
    raise ArgumentError, "body must be a String or nil" unless body.nil? || body.is_a?(String)

    http_request = request_class.new(uri.request_uri)
    http_request["Accept"] = ACCEPT_JSON
    headers.each { |name, value| http_request[name] = value }
    http_request.body = body unless body.nil?

    perform(method, uri, http_request)
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private

  def perform(method, uri, http_request)
    connection = build_connection(uri)
    response = nil
    connection.start do |started|
      started.request(http_request) { |raw| response = read_response(raw, uri.host) }
    end
    response
  rescue Failure => error
    log_failure(method, error)
    raise
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error
    fail_with(method, :timeout, uri.host)
  rescue OpenSSL::OpenSSLError
    fail_with(method, :tls, uri.host)
  rescue SystemCallError, SocketError, IOError, Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
    fail_with(method, :connection, uri.host)
  end

  def fail_with(method, reason, host)
    error = Failure.new(reason, host: host)
    log_failure(method, error)
    raise error
  end

  def log_failure(method, error)
    @logger.warn("#{LOG_TAG} failed method=#{method} host=#{error.host} reason=#{error.reason}")
  end

  # 接続の設定。環境変数のプロキシを使わない（p_addr に nil）。証明書を検証する。再送しない
  def build_connection(uri)
    connection = Net::HTTP.new(uri.host, uri.port, nil)
    connection.use_ssl = true
    connection.verify_mode = OpenSSL::SSL::VERIFY_PEER
    connection.min_version = OpenSSL::SSL::TLS1_2_VERSION
    connection.open_timeout = @connect_timeout
    connection.read_timeout = @read_timeout
    connection.write_timeout = @write_timeout
    connection.max_retries = 0
    connection
  end

  # 本文を、上限まで読む（Content-Length が上限を超えていれば、読む前に失敗）
  def read_response(raw, host)
    declared = raw["content-length"]
    raise Failure.new(:response_too_large, host: host) if declared&.match?(/\A\d+\z/) && declared.to_i > @max_body_bytes

    body = +""
    raw.read_body do |chunk|
      body << chunk
      raise Failure.new(:response_too_large, host: host) if body.bytesize > @max_body_bytes
    end

    Response.new(status: raw.code.to_i, headers: lowercase_headers(raw), body: body.force_encoding(Encoding::UTF_8).freeze, host: host)
  end

  def lowercase_headers(raw)
    headers = {}
    raw.each_header { |name, value| headers[name.downcase] = value }
    headers.freeze
  end

  def parse_url(url)
    raise ArgumentError, "url must be a String" unless url.is_a?(String)

    uri = URI.parse(url)
    raise ArgumentError, "url must be an https URL" unless uri.is_a?(URI::HTTPS)
    raise ArgumentError, "url must have a host" if uri.host.nil? || uri.host.empty?
    raise ArgumentError, "url must not include user information" unless uri.userinfo.nil?
    raise ArgumentError, "url has an invalid port" unless (1..65_535).cover?(uri.port)

    uri
  rescue URI::InvalidURIError
    raise ArgumentError, "url is not a valid URL"
  end

  def validate_headers!(headers)
    valid = headers.is_a?(Hash) && headers.all? do |name, value|
      name.is_a?(String) && HEADER_NAME.match?(name) && value.is_a?(String) && !FORBIDDEN_IN_HEADER_VALUE.match?(value)
    end
    raise ArgumentError, "headers must be a Hash of String names to String values (no line breaks)" unless valid
  end

  def positive_number!(value, name)
    raise ArgumentError, "#{name} must be a positive number of seconds" unless value.is_a?(Numeric) && value.positive? && value.finite?

    value
  end
end
