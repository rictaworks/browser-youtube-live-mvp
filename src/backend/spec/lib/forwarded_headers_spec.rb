require "rails_helper"

# 転送ヘッダ（X-Forwarded-*）の隔離（issue #7。requirements.md 6.1・28.1）。
# 利用者の IP と公開オリジンは、BFF の確認（X-BFF-Secret）を通った要求の転送ヘッダからだけ読む。
# そのため、ミドルウェアの先頭で、転送ヘッダを、Rack の env から取り除いて、別の場所へ置く。Rails・Rack が、確認の前に読めない。
RSpec.describe ForwardedHeaders do
  let(:seen) { [] }
  let(:app) { ->(env) { seen << env; [ 200, {}, [ "ok" ] ] } }
  let(:middleware) { described_class.new(app) }

  def call(headers = {})
    env = Rack::MockRequest.env_for("/api/x", { "REMOTE_ADDR" => "198.51.100.7" }.merge(headers))
    middleware.call(env)
    env
  end

  # Rack・Rails が転送ヘッダとして読む env のキー（Rack::Request・ActionDispatch::Request・ActionDispatch::SSL）
  read_by_rack = %w[
    HTTP_X_FORWARDED_FOR HTTP_X_FORWARDED_HOST HTTP_X_FORWARDED_PROTO HTTP_X_FORWARDED_SCHEME
    HTTP_X_FORWARDED_SSL HTTP_X_FORWARDED_PORT HTTP_FORWARDED HTTP_CLIENT_IP
  ]

  describe "env からの除去" do
    read_by_rack.each do |key|
      it "#{key} を、env から取り除く" do
        env = call(key => "dummy-value")

        expect(env).not_to have_key(key)
      end
    end

    it "転送ヘッダ以外の env は、そのまま残す" do
      env = call(
        "HTTP_X_BFF_SECRET" => "dummy-bff", "HTTP_ORIGIN" => "https://app.example.test",
        "HTTP_COOKIE" => "bl_session=dummy", "HTTP_X_BL_CLIENT" => "web", "HTTP_HOST" => "backend.up.railway.app"
      )

      expect(env).to include(
        "HTTP_X_BFF_SECRET" => "dummy-bff", "HTTP_ORIGIN" => "https://app.example.test",
        "HTTP_COOKIE" => "bl_session=dummy", "HTTP_X_BL_CLIENT" => "web", "HTTP_HOST" => "backend.up.railway.app",
        "REMOTE_ADDR" => "198.51.100.7"
      )
    end

    it "内側のアプリケーションへ渡す env にも、転送ヘッダが無い" do
      call("HTTP_X_FORWARDED_FOR" => "203.0.113.5", "HTTP_FORWARDED" => "for=203.0.113.5")

      expect(seen.size).to eq(1)
      expect(seen.first.keys & read_by_rack).to be_empty
    end

    it "内側のアプリケーションの応答を、そのまま返す" do
      expect(middleware.call(Rack::MockRequest.env_for("/"))).to eq([ 200, {}, [ "ok" ] ])
    end
  end

  describe "別の場所への保管（BFF の確認を通った要求だけが、読む）" do
    it "X-Forwarded-For・X-Forwarded-Host・X-Forwarded-Proto の値を、env の bl.forwarded_headers に置く" do
      env = call("HTTP_X_FORWARDED_FOR" => "203.0.113.5", "HTTP_X_FORWARDED_HOST" => "app.example.test", "HTTP_X_FORWARDED_PROTO" => "https")

      stored = described_class.fetch(env)
      expect(stored.forwarded_for).to eq("203.0.113.5")
      expect(stored.forwarded_host).to eq("app.example.test")
      expect(stored.forwarded_proto).to eq("https")
    end

    it "ヘッダが無ければ、nil" do
      stored = described_class.fetch(call)

      expect([ stored.forwarded_for, stored.forwarded_host, stored.forwarded_proto ]).to all(be_nil)
    end

    it "値は、加工せずに渡す（検証は、読む側の ClientIp・PublicOrigin）" do
      env = call("HTTP_X_FORWARDED_FOR" => " 203.0.113.5 , 10.0.0.1", "HTTP_X_FORWARDED_HOST" => "A.example, b.example")

      stored = described_class.fetch(env)
      expect(stored.forwarded_for).to eq(" 203.0.113.5 , 10.0.0.1")
      expect(stored.forwarded_host).to eq("A.example, b.example")
    end

    it "保管した値は、凍結されている" do
      expect(described_class.fetch(call("HTTP_X_FORWARDED_FOR" => "203.0.113.5"))).to be_frozen
    end

    it "inspect に、値（IP）を出さない（env をログ・例外の報告へ出しても、IP が漏れない）" do
      stored = described_class.fetch(call("HTTP_X_FORWARDED_FOR" => "203.0.113.5"))

      expect(stored.inspect).not_to include("203.0.113.5")
      expect(stored.to_s).not_to include("203.0.113.5")
    end

    it "ミドルウェアが通っていない env からは、読めない（黙って生のヘッダを読まない）" do
      env = Rack::MockRequest.env_for("/", "HTTP_X_FORWARDED_FOR" => "203.0.113.5")

      expect { described_class.fetch(env) }.to raise_error(ForwardedHeaders::NotInstalledError)
    end
  end

  describe "Rails・Rack への影響（転送ヘッダを信用しない）" do
    def request_for(headers)
      env = call({ "HTTP_HOST" => "backend.up.railway.app" }.merge(headers))
      ActionDispatch::Request.new(env)
    end

    it "request.host は、Host ヘッダ（バックエンド自身）で、X-Forwarded-Host に引きずられない" do
      expect(request_for("HTTP_X_FORWARDED_HOST" => "evil.example").host).to eq("backend.up.railway.app")
    end

    it "request.ip・remote_ip は、接続元（REMOTE_ADDR）で、X-Forwarded-For・Client-IP に引きずられない" do
      request = request_for("HTTP_X_FORWARDED_FOR" => "203.0.113.5", "HTTP_CLIENT_IP" => "203.0.113.6")

      expect(request.ip).to eq("198.51.100.7")
      expect(request.remote_ip.to_s).to eq("198.51.100.7")
    end

    it "request.ssl? は、X-Forwarded-Proto・X-Forwarded-Ssl に引きずられない" do
      expect(request_for("HTTP_X_FORWARDED_PROTO" => "https", "HTTP_X_FORWARDED_SSL" => "on").ssl?).to be(false)
    end
  end

  it "アプリケーションのミドルウェアの先頭にある（HostAuthorization・AssumeSSL・SSL・RemoteIp・Logger より前）" do
    names = Rails.application.middleware.map { |middleware| middleware.klass.name }

    expect(names.first).to eq("ForwardedHeaders")
    %w[ ActionDispatch::HostAuthorization ActionDispatch::AssumeSSL ActionDispatch::SSL ActionDispatch::RemoteIp RequestLogger ].each do |name|
      index = names.index(name)
      expect(index).to be > 0 if index
    end
  end
end
