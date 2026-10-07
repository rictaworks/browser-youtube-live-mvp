require "rails_helper"
require "support/log_capture"

# 契約のエラーの形（{"error":{"code":…,"details":…}}。src/contracts/http-api.md 1.6）を、Rack の層で返す部品（issue #7）。
# コントローラの外（ホストの拒否・存在しない経路）でも、HTML のエラーページを返さない。
RSpec.describe ApiErrorBody do
  describe ".build" do
    it "details を省略すると、空のオブジェクト（契約: 省略は空と同じ）" do
      expect(described_class.build("not_found")).to eq({ "error" => { "code" => "not_found", "details" => {} } })
    end

    it "details を持てる" do
      body = described_class.build("rate_limited", { "retry_at" => "2026-10-07T13:30:00+09:00" })

      expect(body).to eq({ "error" => { "code" => "rate_limited", "details" => { "retry_at" => "2026-10-07T13:30:00+09:00" } } })
    end

    it "符号が、文字列でない・空なら、例外にする" do
      [ nil, "", :forbidden, 403 ].each do |code|
        expect { described_class.build(code) }.to raise_error(ArgumentError)
      end
    end
  end

  describe ".rack_response" do
    it "状態・ヘッダ・本文の 3 つ組を返す。Content-Type は JSON（UTF-8）、Cache-Control は no-store" do
      status, headers, body = described_class.rack_response(403, "forbidden")

      expect(status).to eq(403)
      expect(headers["content-type"]).to eq("application/json; charset=utf-8")
      expect(headers["cache-control"]).to eq("no-store")
      expect(headers["content-length"]).to eq(body.join.bytesize.to_s)
      expect(JSON.parse(body.join)).to eq({ "error" => { "code" => "forbidden", "details" => {} } })
    end

    it "本文は、HTML ではない" do
      _, _, body = described_class.rack_response(404, "not_found")

      expect(body.join).not_to include("<")
    end
  end
end

RSpec.describe HostRejectedApp do
  def call(host)
    described_class.call(Rack::MockRequest.env_for("/api/state", "HTTP_HOST" => host))
  end

  it "403 forbidden（JSON）を返す" do
    status, headers, body = call("evil.example")

    expect(status).to eq(403)
    expect(headers["content-type"]).to eq("application/json; charset=utf-8")
    expect(JSON.parse(body.join).dig("error", "code")).to eq("forbidden")
  end

  it "拒否した Host を、本文に含めない（手がかりを書かない）" do
    _, _, body = call("evil.example")

    expect(body.join).not_to include("evil.example")
  end

  it "拒否した Host を、ログに残す（原因をたどれるように。制御文字は、エスケープして 1 行にする）" do
    output = capture_logs { call("evil.example\nINJECTED") }

    expect(output).to include("evil.example")
    expect(output.lines.grep(/INJECTED/).size).to eq(1)
    expect(output).not_to match(/^INJECTED/)
  end

  it "長すぎる Host は、ログへ切り詰めて出す" do
    output = capture_logs { call("a" * 5000) }

    expect(output.length).to be < 1000
  end
end

RSpec.describe NotFoundApp do
  it "404 not_found（JSON）を返す。どの経路・どの口でも、同じ応答（経路の存在を明かさない）" do
    %w[ /internal/v1/verify /api/state /admin /up /x ].each do |path|
      status, headers, body = described_class.call(Rack::MockRequest.env_for(path))

      expect(status).to eq(404)
      expect(headers["content-type"]).to eq("application/json; charset=utf-8")
      expect(headers["cache-control"]).to eq("no-store")
      expect(JSON.parse(body.join)).to eq({ "error" => { "code" => "not_found", "details" => {} } })
    end
  end

  it "本文に、要求の経路を含めない" do
    _, _, body = described_class.call(Rack::MockRequest.env_for("/internal/v1/verify"))

    expect(body.join).not_to include("internal")
  end
end
