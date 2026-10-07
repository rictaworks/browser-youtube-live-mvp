require "rails_helper"
require_relative "../../config/allowed_hosts"

# config.hosts（DNS rebinding の防止）。開発は localhost・backend、本番は *.up.railway.app・*.railway.internal に限る（issue #7）。
# テストの環境は制限しない（Rack::Test の Host は www.example.com）ので、環境ごとの一覧を直接検査し、
# 本番の一覧を、本番と同じ順のミドルウェア（ForwardedHeaders → HostAuthorization）へ入れて、動作を確かめる。
RSpec.describe AllowedHosts do
  describe ".for" do
    it "開発は localhost と backend（ブラウザは localhost、docker compose の他のコンテナはサービス名 backend で呼ぶ）" do
      expect(described_class.for(:development)).to eq(%w[ localhost backend ])
    end

    it "本番は *.up.railway.app と *.railway.internal（先頭の . は、そのドメインと、その下のすべてのサブドメイン）" do
      expect(described_class.for(:production)).to eq(%w[ .up.railway.app .railway.internal ])
    end

    it "テストは制限しない" do
      expect(described_class.for(:test)).to eq([])
    end

    it "文字列の名前も受け付ける" do
      expect(described_class.for("production")).to eq(described_class.for(:production))
    end

    [ :staging, "prod", nil, "" ].each do |name|
      it "未知の名前 #{name.inspect} は、既定の環境へ倒さず、例外にする" do
        expect { described_class.for(name) }.to raise_error(ArgumentError, /unknown environment/)
      end
    end

    it "返す一覧は凍結されている（呼び出し側が書き換えられない）" do
      %i[ development production test ].each { |name| expect(described_class.for(name)).to be_frozen }
    end
  end

  describe ".health_check?" do
    it "ヘルスチェックの経路（/up）だけが、ホストの検査の対象外" do
      expect(described_class.health_check?(Rack::Request.new(Rack::MockRequest.env_for("/up")))).to be(true)
      expect(described_class.health_check?(Rack::Request.new(Rack::MockRequest.env_for("/up/x")))).to be(false)
      expect(described_class.health_check?(Rack::Request.new(Rack::MockRequest.env_for("/api/state")))).to be(false)
      expect(described_class.health_check?(Rack::Request.new(Rack::MockRequest.env_for("/internal/v1/verify")))).to be(false)
    end
  end

  describe "アプリケーションの設定" do
    it "config.hosts は、環境の一覧そのもの（development.rb が、さらに足さない）" do
      expect(Rails.application.config.hosts).to eq(described_class.for(AppEnvironment.current.name))
    end

    it "host_authorization は、/up を除外し、JSON で拒否する応答のアプリを持つ" do
      options = Rails.application.config.host_authorization

      expect(options.fetch(:exclude).call(Rack::Request.new(Rack::MockRequest.env_for("/up")))).to be(true)
      expect(options.fetch(:exclude).call(Rack::Request.new(Rack::MockRequest.env_for("/api/state")))).to be(false)
      expect(options.fetch(:response_app)).to respond_to(:call)
    end
  end

  # 本番の構成: ForwardedHeaders が先頭にあり、その次が HostAuthorization
  describe "本番の一覧での動作（本番と同じ順のミドルウェア）" do
    let(:inner) { ->(_env) { [ 200, { "Content-Type" => "text/plain" }, [ "ok" ] ] } }
    let(:options) { Rails.application.config.host_authorization }
    let(:host_authorization) do
      ActionDispatch::HostAuthorization.new(inner, described_class.for(:production), **options)
    end
    let(:stack) { ForwardedHeaders.new(host_authorization) }

    def get(app, path, headers = {})
      Rack::MockRequest.new(app).get(path, headers)
    end

    {
      "Railway の公開ドメイン" => "backend-production-1234.up.railway.app",
      "Railway の公開ドメイン（ポート付き）" => "backend-production-1234.up.railway.app:443",
      "Railway のプライベートネットワーク（中継の内部通信）" => "backend.railway.internal:3101",
      "大文字" => "Backend-Production.UP.RAILWAY.APP"
    }.each do |label, host|
      it "#{label}（#{host}）の Host は通す" do
        expect(get(stack, "/api/state", "HTTP_HOST" => host).status).to eq(200)
      end
    end

    {
      "任意のドメイン" => "evil.example",
      "公開ドメインに似せたドメイン" => "up.railway.app.evil.example",
      "前に文字を足したドメイン" => "evilup.railway.app",
      "IP アドレス" => "203.0.113.5:3001",
      "localhost（本番では許可しない）" => "localhost:3001",
      "backend（開発のサービス名。本番では許可しない）" => "backend:3101",
      "空" => ""
    }.each do |label, host|
      it "#{label}（#{host.inspect}）の Host は、403 で拒否する" do
        response = get(stack, "/api/state", "HTTP_HOST" => host)

        expect(response.status).to eq(403)
        expect(JSON.parse(response.body).dig("error", "code")).to eq("forbidden")
      end
    end

    it "ヘルスチェック（/up）は、どの Host でも通す（Railway のヘルスチェックの Host・コンテナ内の 127.0.0.1）" do
      [ "127.0.0.1:3001", "healthcheck.railway.app", "evil.example" ].each do |host|
        expect(get(stack, "/up", "HTTP_HOST" => host).status).to eq(200)
      end
    end

    it "BFF が付ける X-Forwarded-Host（フロントエンドの公開ドメイン）が、許可の一覧に無くても、通す" do
      response = get(stack, "/api/state",
                     "HTTP_HOST" => "backend-production-1234.up.railway.app",
                     "HTTP_X_FORWARDED_HOST" => "app.example.test",
                     "HTTP_X_FORWARDED_PROTO" => "https")

      expect(response.status).to eq(200)
    end

    it "回帰: ForwardedHeaders が無いと、Rails が X-Forwarded-Host も検査し、BFF の要求が、本番ですべて 403 になる" do
      response = get(host_authorization, "/api/state",
                     "HTTP_HOST" => "backend-production-1234.up.railway.app",
                     "HTTP_X_FORWARDED_HOST" => "app.example.test")

      expect(response.status).to eq(403)
    end

    it "拒否の応答は JSON で、拒否した Host を本文に含めない" do
      response = get(stack, "/api/state", "HTTP_HOST" => "evil.example")

      expect(response.content_type).to eq("application/json; charset=utf-8")
      expect(response.body).not_to include("evil.example")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  describe "開発の一覧での動作" do
    let(:inner) { ->(_env) { [ 200, {}, [ "ok" ] ] } }
    let(:stack) do
      ForwardedHeaders.new(ActionDispatch::HostAuthorization.new(inner, described_class.for(:development), **Rails.application.config.host_authorization))
    end

    {
      "localhost" => [ "localhost:3001", 200 ],
      "backend（frontend・relay のコンテナから）" => [ "backend:3101", 200 ],
      "127.0.0.1（ブラウザの別名）" => [ "127.0.0.1:3001", 403 ],
      "任意のドメイン" => [ "evil.example", 403 ]
    }.each do |label, (host, status)|
      it "#{label}（#{host}）は #{status}" do
        expect(Rack::MockRequest.new(stack).get("/api/state", "HTTP_HOST" => host).status).to eq(status)
      end
    end

    it "127.0.0.1 でも、/up は通す（コンテナのヘルスチェック）" do
      expect(Rack::MockRequest.new(stack).get("/up", "HTTP_HOST" => "127.0.0.1:3001").status).to eq(200)
    end
  end
end
