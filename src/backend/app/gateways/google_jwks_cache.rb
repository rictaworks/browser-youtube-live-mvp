# Google の公開鍵（JWKS）のキャッシュ（issue #8。requirements.md 28.1）。ID トークンの署名を検証する鍵を、kid で選ぶために使う。
#
#   取得      jwks_uri を ExternalHttp で取得する（200 の JSON で、keys が空でない配列）
#   有効期間  取得から ttl_seconds のあいだ、使い回す。過ぎたら（ちょうどの時刻から）再取得する
#   鍵の入れ替え  kid が見つからないとき（invalidate: true）は、前回の取得から min_refetch_seconds 以上たっていれば再取得する。
#                 未知の kid が続いても、取得先を叩き続けない
#   失敗      取得できない・解釈できないときは、古い鍵で続行せず、GoogleOidc::AuthenticationFailed（jwks_unavailable）。
#             失敗した取得は、有効期間内のキャッシュを壊さない
#
# 時刻は引数 now で受け取る（実時計を読まない）。複数のスレッドが同時に呼んでも、取得は 1 回（Mutex）。
# 返す JWKS は深く凍結してある（呼び出し側が書き換えられない）。ログには、符号だけを出す（応答の本文を出さない）。
class GoogleJwksCache
  LOG_TAG = "[google_jwks]".freeze

  def initialize(http:, jwks_uri:, ttl_seconds:, min_refetch_seconds:, logger: Rails.logger)
    raise ArgumentError, "jwks_uri must be an https URL" unless jwks_uri.is_a?(String) && jwks_uri.start_with?("https://")
    raise ArgumentError, "ttl_seconds must be a positive Integer" unless positive_integer?(ttl_seconds)
    raise ArgumentError, "min_refetch_seconds must be a positive Integer" unless positive_integer?(min_refetch_seconds)

    @http = http
    @jwks_uri = jwks_uri
    @ttl_seconds = ttl_seconds
    @min_refetch_seconds = min_refetch_seconds
    @logger = logger
    @mutex = Mutex.new
    @document = nil
    @fetched_at = nil
  end

  # now で有効な JWKS（{"keys" => [...]}）。invalidate: true は、kid が見つからなかったときの再取得の要求
  def keys(now:, invalidate: false)
    raise ArgumentError, "now must be a Time" unless now.is_a?(Time)

    @mutex.synchronize do
      refresh(now) if refresh_needed?(now, invalidate)
      @document
    end
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private

  def positive_integer?(value)
    value.is_a?(Integer) && value.positive?
  end

  def refresh_needed?(now, invalidate)
    return true if @document.nil?
    return true if now >= @fetched_at + @ttl_seconds

    invalidate && now >= @fetched_at + @min_refetch_seconds
  end

  def refresh(now)
    document = fetch_document
    @document = deep_freeze(document)
    @fetched_at = now
  end

  def fetch_document
    response = @http.get(@jwks_uri)
    unavailable!(:http_status) unless response.status == 200

    document = response.json
    unavailable!(:invalid_response) unless usable?(document)

    document
  rescue ExternalHttp::Failure => failure
    unavailable!(%i[ response_too_large invalid_json ].include?(failure.reason) ? :invalid_response : :unreachable)
  end

  # keys が、オブジェクトの空でない配列
  def usable?(document)
    document.is_a?(Hash) && document["keys"].is_a?(Array) && !document["keys"].empty? && document["keys"].all?(Hash)
  end

  def unavailable!(cause)
    @logger.warn("#{LOG_TAG} refresh failed reason=jwks_unavailable cause=#{cause}")
    raise GoogleOidc::AuthenticationFailed.new(:jwks_unavailable)
  end

  def deep_freeze(value)
    case value
    when Hash
      value.each do |key, item|
        deep_freeze(key)
        deep_freeze(item)
      end
    when Array then value.each { |item| deep_freeze(item) }
    end
    value.freeze
  end
end
