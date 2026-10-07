# 口の分離（Rack ミドルウェア。issue #7。requirements.md 6.1・11.9・28.1。src/contracts/internal-api.md 1）。
#
# アプリケーションは、2 つの口で待ち受ける（config/puma.rb）。公開側の口（環境変数 PORT。既定 3001）と、内部通信の口（3101。
# 外部から到達できない経路でのみ受ける）。経路の分離は、ルーティングの制約（PublicListener・InternalListener）が行う。
# その前提として、このミドルウェアが、要求を受けた口の番号を、env["bl.listener_port"] に置く。
#
#   1. puma.socket（Puma が、要求を受けた接続のソケットを、env に入れる）のローカルポート。これが優先される
#   2. puma.socket が無いときだけ、env にあらかじめ置かれた口の番号（テスト用。スペックのヘルパーで明示する。
#      HTTP のヘッダは HTTP_ で始まる別のキーになるので、要求の側から口を指定することはできない）
#   3. どちらも無ければ、例外にする（黙って公開側と見なさない）
#
# 口の番号は、設定の定数（config/server_ports.rb）。内部側の口の番号は、環境変数では変えられない。
class ListenerPort
  # 要求を受けた口が分からない（ミドルウェアが通っていない・ソケットから口を得られない）
  class UnknownPortError < StandardError; end

  # 口の設定の不備（PORT が口の番号として読めない・PORT が内部側の口と同じ）
  class ConfigurationError < StandardError; end

  ENV_KEY = "bl.listener_port".freeze
  PUMA_SOCKET_KEY = "puma.socket".freeze
  PORT_ENV_NAME = "PORT".freeze
  PORT_PATTERN = /\A[1-9]\d{0,4}\z/
  PORT_RANGE = (1..65_535)

  class << self
    # env の口の番号。ミドルウェアが通っていない env（番号が無い・不正）は、例外にする
    def of(env)
      port = env[ENV_KEY]
      return port if valid_port?(port)

      raise UnknownPortError, "listener port is not available for this request (ListenerPort middleware did not run)"
    end

    # 公開側の口。環境変数 PORT（Railway が与える）。無ければ、設定の定数 ServerPorts::PUBLIC_DEFAULT。
    # PORT が口の番号として読めない場合は、既定の口へ倒さず、例外にする。内部側の口と同じなら、例外にする。
    def public_port(environ = ENV)
      raw = environ.fetch(PORT_ENV_NAME, nil)
      port = raw.nil? ? ServerPorts::PUBLIC_DEFAULT : parse_port(raw)
      if port == internal_port
        raise ConfigurationError, "#{PORT_ENV_NAME} must not be the internal port (the internal port must not be reachable from the public side)"
      end

      port
    end

    # 内部側の口。設定の定数（環境変数ではない）
    def internal_port
      ServerPorts::INTERNAL
    end

    def public?(env, environ = ENV)
      of(env) == public_port(environ)
    end

    def internal?(env)
      of(env) == internal_port
    end

    # 起動の時点の検査（config/initializers/listener_ports.rb）。不備があれば ConfigurationError
    def verify_configuration!(environ = ENV)
      public_port(environ)
      nil
    end

    def valid_port?(value)
      value.is_a?(Integer) && PORT_RANGE.cover?(value)
    end

    private

    def parse_port(raw)
      unless raw.is_a?(String) && PORT_PATTERN.match?(raw) && PORT_RANGE.cover?(raw.to_i)
        raise ConfigurationError, "#{PORT_ENV_NAME} is not a valid port number"
      end

      raw.to_i
    end
  end

  def initialize(app)
    @app = app
  end

  def call(env)
    env[ENV_KEY] = resolve(env)
    @app.call(env)
  end

  private

  def resolve(env)
    socket = env[PUMA_SOCKET_KEY]
    return port_of_socket(socket) unless socket.nil?

    preset = env[ENV_KEY]
    return preset if self.class.valid_port?(preset)

    raise UnknownPortError, "listener port could not be determined (no #{PUMA_SOCKET_KEY} and no preset port)"
  end

  # 受け付けた接続のソケットの、ローカルポート（要求を受けた口）。TLS のラッパー（to_io を持つもの）も扱う
  def port_of_socket(socket)
    io = socket.respond_to?(:local_address) ? socket : socket_io(socket)
    raise UnknownPortError, "#{PUMA_SOCKET_KEY} does not provide a local address" if io.nil?

    port = io.local_address.ip_port
    raise UnknownPortError, "#{PUMA_SOCKET_KEY} reported an invalid local port" unless self.class.valid_port?(port)

    port
  rescue SocketError, IOError, SystemCallError
    # TCP でないソケット（UNIX ドメイン）・閉じたソケット。口の番号を得られないので、公開側と見なさず、例外にする
    raise UnknownPortError, "#{PUMA_SOCKET_KEY} could not report the local port"
  end

  def socket_io(socket)
    return nil unless socket.respond_to?(:to_io)

    io = socket.to_io
    io if io.respond_to?(:local_address)
  end
end
