# 公開オリジン（フロントエンドのオリジン。issue #7。src/contracts/http-api.md 1.2・6。requirements.md 6.1）。
#
# リダイレクト先（Location）の組み立てと、CSRF の Origin ヘッダの照合に使う。BFF の確認を通った要求の X-Forwarded-Host・
# X-Forwarded-Proto から作る（VerifiedBffRequest）。バックエンドのホスト（*.up.railway.app）を、ブラウザへ出さない。
# Rails の redirect_to は、相対パスを、要求のホスト（バックエンド）の絶対 URL にしてしまうため、ここから組み立てる。
#
# 値が無い・正しくない場合は、バックエンドのホストなどで補わず、例外にする。例外のメッセージに、渡された値を含めない
# （攻撃者が選べる値を、ログへ出さない）。複数の値（途中の経路が足したもの）は、先頭（BFF が付けた値）を使う。
class PublicOrigin
  class InvalidError < StandardError; end

  PROTOCOLS = %w[ http https ].freeze
  # ホスト名（DNS のラベルを、ドットでつなぐ）と、任意のポート。ユーザー情報・経路・IPv6 のリテラルを持つ値は、一致しない
  LABEL = /[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?/i
  HOST_PATTERN = /\A(?<name>#{LABEL}(?:\.#{LABEL})*)(?::(?<port>\d{1,5}))?\z/
  MAX_HOST_NAME_LENGTH = 253
  # リダイレクト先の経路: ASCII の表示できる文字（バックスラッシュを除く）だけ。スラッシュで始まり、2 つ目はスラッシュでない
  PATH_PATTERN = %r{\A/(?!/)[\x21-\x5b\x5d-\x7e]*\z}
  # HTTP のヘッダの値の前後の空白（OWS。空白とタブだけ）
  OWS = /\A[ \t]+|[ \t]+\z/

  def self.from_forwarded(host:, proto:)
    new(proto: normalize_proto(first_value(proto)), host: normalize_host(first_value(host)))
  end

  def self.first_value(raw)
    raise InvalidError, "forwarded header is missing or not a String" unless raw.is_a?(String) && raw.valid_encoding?

    raw.split(",", 2).first.to_s.gsub(OWS, "")
  end
  private_class_method :first_value

  def self.normalize_proto(value)
    normalized = value.downcase
    raise InvalidError, "forwarded protocol is not http or https" unless PROTOCOLS.include?(normalized)

    normalized
  end
  private_class_method :normalize_proto

  def self.normalize_host(value)
    match = HOST_PATTERN.match(value)
    raise InvalidError, "forwarded host is not a valid host name" if match.nil? || match[:name].length > MAX_HOST_NAME_LENGTH

    port = match[:port]
    raise InvalidError, "forwarded host has an invalid port" if port && !(1..65_535).cover?(port.to_i)

    value.downcase
  end
  private_class_method :normalize_host

  private_class_method :new

  def initialize(proto:, host:)
    @origin = "#{proto}://#{host}".freeze
    freeze
  end

  # "https://app.example.test"
  def to_s
    @origin
  end

  # 公開オリジンの絶対 URL（リダイレクト先）。path は、/ で始まる経路（クエリを含んでよい）。不正な経路は ArgumentError
  def url_for(path)
    raise ArgumentError, "path must be an absolute path starting with a single slash" unless path.is_a?(String) && PATH_PATTERN.match?(path)

    "#{@origin}#{path}"
  end

  # CSRF の Origin ヘッダが、この公開オリジンと一致するか（大文字・小文字は区別しない。経路・末尾のスラッシュ・空白は許さない）
  def matches_origin?(header)
    header.is_a?(String) && header.valid_encoding? && header.downcase == @origin
  end
end
