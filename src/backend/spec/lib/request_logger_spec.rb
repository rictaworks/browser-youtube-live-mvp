require "rails_helper"
require "support/log_capture"

# 要求のログ（"Started GET ..."）に、IP アドレスを出さない（issue #7。requirements.md 28.2）。
# Rails 標準の Rails::Rack::Logger は、"Started GET "/path" for 203.0.113.5 at ..." と、利用者の IP を、要求のたびにログへ出す。
RSpec.describe RequestLogger do
  let(:app) { ->(_env) { [ 200, {}, [ "ok" ] ] } }
  let(:middleware) { described_class.new(app) }

  def call(path, headers = {})
    env = Rack::MockRequest.env_for(path, { "REMOTE_ADDR" => "198.51.100.7", "action_dispatch.parameter_filter" => Rails.application.config.filter_parameters }.merge(headers))
    middleware.call(env)
  end

  it "Rails::Rack::Logger を継承し、開始のログを出す（メソッドと経路）" do
    output = capture_logs { call("/api/state") }

    expect(described_class.superclass).to eq(Rails::Rack::Logger)
    expect(output).to match(%r{Started GET "/api/state" at })
  end

  it "接続元の IP（REMOTE_ADDR）を、ログに出さない" do
    output = capture_logs { call("/api/state") }

    expect(output).not_to include("198.51.100.7")
    expect(output).not_to include(" for ")
  end

  it "転送ヘッダの IP（X-Forwarded-For・Client-IP）を、ログに出さない" do
    output = capture_logs { call("/api/state", "HTTP_X_FORWARDED_FOR" => "203.0.113.77", "HTTP_CLIENT_IP" => "203.0.113.78") }

    expect(output).not_to include("203.0.113.77")
    expect(output).not_to include("203.0.113.78")
  end

  it "X-Forwarded-For と Client-IP が食い違っても、例外にならない（Rails 標準は、なりすましの疑いとして IpSpoofAttackError）" do
    expect { call("/api/state", "HTTP_X_FORWARDED_FOR" => "203.0.113.77", "HTTP_CLIENT_IP" => "203.0.113.99") }.not_to raise_error
  end

  it "経路のクエリは、伏せ字にして出す（認可コード・state・チケットなど）" do
    output = capture_logs { call("/api/auth/callback?code=dummy-auth-code-123&state=dummy-state-456&ticket=dummy-ticket-789&page=2") }

    expect(output).not_to include("dummy-auth-code-123")
    expect(output).not_to include("dummy-state-456")
    expect(output).not_to include("dummy-ticket-789")
    expect(output).to include("code=[FILTERED]")
    expect(output).to include("page=2")
  end

  it "アプリケーションのミドルウェアで、Rails 標準の Logger の代わりに使われている" do
    names = Rails.application.middleware.map { |middleware| middleware.klass.name }

    expect(names).to include("RequestLogger")
    expect(names).not_to include("Rails::Rack::Logger")
  end
end
