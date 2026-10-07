require "rails_helper"
require "socket"
require_relative "../../config/server_ports"

# 口の分離（issue #7。requirements.md 6.1・11.9）。公開側の口（PORT。既定 3001）と内部側の口（3101）を、ルーティングで分ける。
#   ListenerPort    要求を受けた口の番号を、puma.socket のローカルポートから得て、env["bl.listener_port"] に置く
#   PublicListener  /api・/admin・/up は、公開側の口だけで応答する
#   InternalListener  /internal は、内部側の口だけで応答する
RSpec.describe ListenerPort do
  let(:seen) { [] }
  let(:app) { ->(env) { seen << env[described_class::ENV_KEY]; [ 200, {}, [ "ok" ] ] } }
  let(:middleware) { described_class.new(app) }

  # 実際の TCP の接続を作り、サーバー側で受け付けたソケット（Puma が puma.socket に入れるものと同じ種類）を渡す
  def with_accepted_socket
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    client = TCPSocket.new("127.0.0.1", port)
    accepted = server.accept
    yield accepted, port
  ensure
    [ accepted, client, server ].compact.each(&:close)
  end

  describe "#call（口の番号の取得）" do
    it "puma.socket のローカルポート（受け付けた口）を、env['bl.listener_port'] に置く" do
      with_accepted_socket do |socket, port|
        env = Rack::MockRequest.env_for("/up", described_class::PUMA_SOCKET_KEY => socket)

        middleware.call(env)

        expect(env[described_class::ENV_KEY]).to eq(port)
        expect(seen).to eq([ port ])
      end
    end

    it "接続元のポートではなく、受け付けた口（ローカル）のポートを使う" do
      with_accepted_socket do |socket, port|
        expect(socket.remote_address.ip_port).not_to eq(port)

        env = Rack::MockRequest.env_for("/up", described_class::PUMA_SOCKET_KEY => socket)
        middleware.call(env)

        expect(env[described_class::ENV_KEY]).to eq(port)
      end
    end

    it "puma.socket があれば、env にあらかじめ置かれた値より、ソケットを優先する（要求の側から口を偽れない）" do
      with_accepted_socket do |socket, port|
        env = Rack::MockRequest.env_for("/up", described_class::PUMA_SOCKET_KEY => socket, described_class::ENV_KEY => ServerPorts::INTERNAL)

        middleware.call(env)

        expect(env[described_class::ENV_KEY]).to eq(port)
      end
    end

    it "HTTP ヘッダでは、口の番号を指定できない（ヘッダは HTTP_ で始まる別のキーになる）" do
      env = Rack::MockRequest.env_for("/up", "HTTP_BL_LISTENER_PORT" => "3101", "HTTP_X_BL_LISTENER_PORT" => "3101")

      expect { middleware.call(env) }.to raise_error(ListenerPort::UnknownPortError)
    end

    it "puma.socket が無く、env にあらかじめ置かれた口の番号があれば、それを使う（テスト用。ヘルパーで明示する）" do
      env = Rack::MockRequest.env_for("/up", described_class::ENV_KEY => 3001)

      middleware.call(env)

      expect(env[described_class::ENV_KEY]).to eq(3001)
    end

    it "puma.socket も、あらかじめ置かれた口の番号も無ければ、例外にする（黙って公開側と見なさない）" do
      env = Rack::MockRequest.env_for("/up")

      expect { middleware.call(env) }.to raise_error(ListenerPort::UnknownPortError, /listener port/)
      expect(seen).to be_empty
    end

    [ "3001", 0, -1, 65_536, 3001.0, nil, true, [ 3001 ] ].each do |value|
      it "あらかじめ置かれた値 #{value.inspect} が、口の番号（1〜65535 の整数）でなければ、例外にする" do
        env = Rack::MockRequest.env_for("/up", described_class::ENV_KEY => value)

        expect { middleware.call(env) }.to raise_error(ListenerPort::UnknownPortError)
        expect(seen).to be_empty
      end
    end

    it "puma.socket が、口の番号を答えられなければ（TCP でないソケット）、あらかじめ置かれた値に頼らず、例外にする" do
      left, right = UNIXSocket.pair
      env = Rack::MockRequest.env_for("/up", described_class::PUMA_SOCKET_KEY => left, described_class::ENV_KEY => 3001)

      expect { middleware.call(env) }.to raise_error(ListenerPort::UnknownPortError)
    ensure
      [ left, right ].compact.each(&:close)
    end

    it "puma.socket が、口の番号を答えられないオブジェクトなら、例外にする" do
      env = Rack::MockRequest.env_for("/up", described_class::PUMA_SOCKET_KEY => Object.new)

      expect { middleware.call(env) }.to raise_error(ListenerPort::UnknownPortError)
    end

    it "TLS のソケット（to_io を持つラッパー）でも、内側の TCP ソケットの口を得る" do
      with_accepted_socket do |socket, port|
        wrapper = Struct.new(:to_io).new(socket)
        env = Rack::MockRequest.env_for("/up", described_class::PUMA_SOCKET_KEY => wrapper)

        middleware.call(env)

        expect(env[described_class::ENV_KEY]).to eq(port)
      end
    end

    it "内側のアプリケーションの応答を、そのまま返す" do
      env = Rack::MockRequest.env_for("/up", described_class::ENV_KEY => 3001)

      expect(middleware.call(env)).to eq([ 200, {}, [ "ok" ] ])
    end
  end

  describe ".public_port" do
    it "環境変数 PORT が無ければ、設定の定数 ServerPorts::PUBLIC_DEFAULT（3001）" do
      expect(described_class.public_port({})).to eq(3001)
      expect(described_class.public_port({})).to eq(ServerPorts::PUBLIC_DEFAULT)
    end

    it "環境変数 PORT があれば、その口（Railway が与える）" do
      expect(described_class.public_port({ "PORT" => "8080" })).to eq(8080)
    end

    [ "", " ", "abc", "80a", "0", "-1", "65536", "3001.5", "0x1F" ].each do |value|
      it "PORT=#{value.inspect} は、口の番号として読めないので、例外にする（既定の口へ倒さない）" do
        expect { described_class.public_port({ "PORT" => value }) }.to raise_error(ListenerPort::ConfigurationError, /PORT/)
      end
    end

    it "PORT が内部側の口（3101）と同じなら、例外にする（内部側の口が、公開側から到達できてしまう）" do
      expect { described_class.public_port({ "PORT" => "3101" }) }
        .to raise_error(ListenerPort::ConfigurationError, /internal/)
    end

    it "例外のメッセージに、PORT の値を含めない" do
      expect { described_class.public_port({ "PORT" => "dummy-not-a-port" }) }
        .to raise_error(ListenerPort::ConfigurationError) { |error| expect(error.message).not_to include("dummy-not-a-port") }
    end
  end

  describe ".internal_port" do
    it "設定の定数 ServerPorts::INTERNAL（3101）。環境変数では変えられない" do
      expect(described_class.internal_port).to eq(3101)
      expect(described_class.internal_port).to eq(ServerPorts::INTERNAL)
    end
  end

  describe ".of" do
    it "env の口の番号を返す" do
      expect(described_class.of({ described_class::ENV_KEY => 3001 })).to eq(3001)
    end

    it "ミドルウェアが通っていない env（口の番号が無い）は、例外にする" do
      expect { described_class.of({}) }.to raise_error(ListenerPort::UnknownPortError)
    end
  end

  describe ".public? / .internal?（口の番号と、PORT の組）" do
    # [ 口の番号, PORT, 公開側か, 内部側か ]
    [
      [ 3001, {}, true, false ],
      [ 3101, {}, false, true ],
      [ 3999, {}, false, false ],
      [ 8080, { "PORT" => "8080" }, true, false ],
      [ 3101, { "PORT" => "8080" }, false, true ],
      [ 3001, { "PORT" => "8080" }, false, false ]
    ].each do |port, environ, public_expected, internal_expected|
      it "口 #{port}・環境 #{environ.inspect} → 公開側 #{public_expected}・内部側 #{internal_expected}" do
        env = { described_class::ENV_KEY => port }

        expect(described_class.public?(env, environ)).to be(public_expected)
        expect(described_class.internal?(env)).to be(internal_expected)
      end
    end

    it "口の番号が無い env は、どちらも例外にする" do
      expect { described_class.public?({}, {}) }.to raise_error(ListenerPort::UnknownPortError)
      expect { described_class.internal?({}) }.to raise_error(ListenerPort::UnknownPortError)
    end
  end

  describe ".verify_configuration!" do
    it "正しい設定なら、何も起こさない" do
      expect { described_class.verify_configuration!({}) }.not_to raise_error
      expect { described_class.verify_configuration!({ "PORT" => "8080" }) }.not_to raise_error
    end

    it "PORT が内部側の口と同じなら、起動の時点で例外にする" do
      expect { described_class.verify_configuration!({ "PORT" => "3101" }) }.to raise_error(ListenerPort::ConfigurationError)
    end
  end
end

RSpec.describe PublicListener do
  def request(port: nil)
    env = Rack::MockRequest.env_for("/api/usage-events")
    env[ListenerPort::ENV_KEY] = port unless port.nil?
    ActionDispatch::Request.new(env)
  end

  it "公開側の口の要求にだけ、一致する" do
    expect(described_class.new.matches?(request(port: ListenerPort.public_port))).to be(true)
    expect(described_class.new.matches?(request(port: ListenerPort.internal_port))).to be(false)
    expect(described_class.new.matches?(request(port: 3999))).to be(false)
  end

  it "口の番号が分からない要求は、一致させず、例外にする（公開側と見なさない）" do
    expect { described_class.new.matches?(request) }.to raise_error(ListenerPort::UnknownPortError)
  end
end

RSpec.describe InternalListener do
  def request(port: nil)
    env = Rack::MockRequest.env_for("/internal/v1/verify")
    env[ListenerPort::ENV_KEY] = port unless port.nil?
    ActionDispatch::Request.new(env)
  end

  it "内部側の口の要求にだけ、一致する" do
    expect(described_class.new.matches?(request(port: ListenerPort.internal_port))).to be(true)
    expect(described_class.new.matches?(request(port: ListenerPort.public_port))).to be(false)
    expect(described_class.new.matches?(request(port: 3999))).to be(false)
  end

  it "口の番号が分からない要求は、一致させず、例外にする（内部側と見なさない）" do
    expect { described_class.new.matches?(request) }.to raise_error(ListenerPort::UnknownPortError)
  end
end
