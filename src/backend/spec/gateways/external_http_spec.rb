require "rails_helper"
require "support/external_http_support"
require "support/log_capture"

# 外部サービスへの HTTPS 呼び出しの窓口 ExternalHttp（issue #8。#10・#11 も使う）。
# 接続 3 秒・読み取り 5 秒・リダイレクトを追わない・TLS の検証あり。通信の失敗は、ExternalHttp::Failure（原因の符号だけ）。
# 実際の外部サービスは呼ばない（WebMock）。
RSpec.describe ExternalHttp do
  let(:url) { "https://api.example.test/v1/things" }
  let(:http) { described_class.new }

  describe "要求の形" do
    it "GET: ヘッダを付けて送り、応答（状態・ヘッダ（名前は小文字）・本文）を返す" do
      stub = stub_request(:get, url)
             .with(headers: { "Accept" => "application/json", "X-Custom" => "1" })
             .to_return(status: 200, body: '{"a":1}', headers: { "Content-Type" => "application/json", "X-Foo" => "bar" })

      response = http.get(url, headers: { "X-Custom" => "1" })

      expect(stub).to have_been_requested.once
      expect(response.status).to eq(200)
      expect(response.body).to eq('{"a":1}')
      expect(response.headers).to include("content-type" => "application/json", "x-foo" => "bar")
      expect(response.success?).to be(true)
      expect(response.json).to eq({ "a" => 1 })
      expect(response.host).to eq("api.example.test")
    end

    it "GET: クエリを付けられる（URL の中のクエリは、そのまま送る）" do
      stub = stub_request(:get, "#{url}?kind=a&limit=2").to_return(status: 200, body: "{}")

      http.get("#{url}?kind=a&limit=2")

      expect(stub).to have_been_requested.once
    end

    it "POST（フォーム）: application/x-www-form-urlencoded で、値を符号化して送る" do
      stub = stub_request(:post, url)
             .with(body: { "grant_type" => "authorization_code", "code" => "a b&c=d" },
                   headers: { "Content-Type" => "application/x-www-form-urlencoded" })
             .to_return(status: 200, body: "{}")

      http.post_form(url, form: { grant_type: "authorization_code", code: "a b&c=d" })

      expect(stub).to have_been_requested.once
    end

    it "POST（JSON）: application/json で、JSON を送る" do
      stub = stub_request(:post, url)
             .with(body: JSON.generate({ "snippet" => { "title" => "x" } }), headers: { "Content-Type" => "application/json" })
             .to_return(status: 200, body: "{}")

      http.post_json(url, json: { snippet: { title: "x" } })

      expect(stub).to have_been_requested.once
    end

    it "request: PUT・DELETE など、任意のメソッドと本文を送れる" do
      put = stub_request(:put, url).with(body: "payload", headers: { "Content-Type" => "text/plain" }).to_return(status: 204)
      delete = stub_request(:delete, url).to_return(status: 204)

      expect(http.request(:put, url, headers: { "Content-Type" => "text/plain" }, body: "payload").status).to eq(204)
      expect(http.request(:delete, url).status).to eq(204)
      expect(put).to have_been_requested.once
      expect(delete).to have_been_requested.once
    end

    it "request: 未知のメソッドは、ArgumentError" do
      expect { http.request(:trace, url) }.to raise_error(ArgumentError, /method/)
    end

    it "2xx 以外の応答も、例外にせず、そのまま返す（状態で判断するのは、呼び出し側）" do
      stub_request(:get, url).to_return(status: 400, body: '{"error":"invalid_grant"}')

      response = http.get(url)

      expect(response.status).to eq(400)
      expect(response.success?).to be(false)
    end

    it "success? は 2xx だけ" do
      {
        199 => false, 200 => true, 204 => true, 299 => true, 300 => false, 302 => false, 400 => false, 500 => false
      }.each do |status, expected|
        stub_request(:get, url).to_return(status: status)
        expect(http.get(url).success?).to eq(expected), "status=#{status}"
      end
    end
  end

  describe "接続の設定（実際の通信なしで確かめる）" do
    before { stub_request(:get, url).to_return(status: 200, body: "{}") }

    let(:connection) { capture_connections { http.get(url) }.fetch(0) }

    it "接続は 3 秒、読み取りは 5 秒（書き込みも 5 秒）" do
      expect(connection.open_timeout).to eq(3)
      expect(connection.read_timeout).to eq(5)
      expect(connection.write_timeout).to eq(5)
    end

    it "TLS: 使う。証明書を検証する（VERIFY_PEER）。TLS 1.2 以上" do
      expect(connection.use_ssl?).to be(true)
      expect(connection.verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
      expect(connection.min_version).to eq(OpenSSL::SSL::TLS1_2_VERSION)
    end

    it "要求の再送をしない（Net::HTTP の既定は 1 回の再送。呼び出しが 2 回に見えるのを防ぐ）" do
      expect(connection.max_retries).to eq(0)
    end

    it "環境変数のプロキシを使わない（http_proxy・https_proxy があっても、直接接続する）" do
      original = ENV.to_h.slice("http_proxy", "https_proxy", "HTTPS_PROXY")
      ENV["https_proxy"] = "http://proxy.example.test:3128"
      ENV["HTTPS_PROXY"] = "http://proxy.example.test:3128"
      begin
        expect(connection.proxy?).to be(false)
      ensure
        %w[ http_proxy https_proxy HTTPS_PROXY ].each { |name| original.key?(name) ? ENV[name] = original[name] : ENV.delete(name) }
      end
    end

    it "タイムアウトは、引数で変えられる（テストを速くするため）" do
      fast = described_class.new(connect_timeout: 0.5, read_timeout: 0.7)

      connection = capture_connections { fast.get(url) }.fetch(0)

      expect(connection.open_timeout).to eq(0.5)
      expect(connection.read_timeout).to eq(0.7)
    end

    it "タイムアウトの引数は、正の数だけ" do
      [ 0, -1, nil, "3", Float::NAN ].each do |value|
        expect { described_class.new(connect_timeout: value) }.to raise_error(ArgumentError, /connect_timeout/)
        expect { described_class.new(read_timeout: value) }.to raise_error(ArgumentError, /read_timeout/)
      end
    end
  end

  describe "リダイレクトを追わない" do
    it "302 とその Location は、そのまま応答として返す。Location へは、通信しない" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "https://evil.example.test/steal" })

      response = http.get(url)

      expect(response.status).to eq(302)
      expect(response.headers["location"]).to eq("https://evil.example.test/steal")
      expect(a_request(:get, "https://evil.example.test/steal")).not_to have_been_made
    end

    it "POST の 307 も、追わない" do
      stub_request(:post, url).to_return(status: 307, headers: { "Location" => "https://evil.example.test/steal" })

      expect(http.post_form(url, form: { a: "1" }).status).to eq(307)
      expect(a_request(:post, "https://evil.example.test/steal")).not_to have_been_made
    end
  end

  describe "通信の失敗は ExternalHttp::Failure（原因の符号と、ホストだけ）" do
    {
      "接続のタイムアウト" => [ :timeout, ->(stub) { stub.to_timeout } ],
      "読み取りのタイムアウト" => [ :timeout, ->(stub) { stub.to_raise(Net::ReadTimeout) } ],
      "接続のタイムアウト（Net::OpenTimeout）" => [ :timeout, ->(stub) { stub.to_raise(Net::OpenTimeout) } ],
      "接続の拒否" => [ :connection, ->(stub) { stub.to_raise(Errno::ECONNREFUSED) } ],
      "接続のリセット" => [ :connection, ->(stub) { stub.to_raise(Errno::ECONNRESET) } ],
      "名前が引けない" => [ :connection, ->(stub) { stub.to_raise(SocketError) } ],
      "途中で切れた" => [ :connection, ->(stub) { stub.to_raise(EOFError) } ],
      "TLS の失敗（証明書の検証など）" => [ :tls, ->(stub) { stub.to_raise(OpenSSL::SSL::SSLError) } ]
    }.each do |label, (reason, arrange)|
      it "#{label}: reason は #{reason}" do
        arrange.call(stub_request(:get, url))

        expect { http.get(url) }.to raise_error(ExternalHttp::Failure) { |error|
          expect(error.reason).to eq(reason)
          expect(error.host).to eq("api.example.test")
        }
      end
    end

    it "メッセージは、符号とホストだけ（URL・クエリ・本文を含めない）" do
      stub_request(:get, "#{url}?code=dummy-secret-code").to_raise(Errno::ECONNREFUSED)

      expect { http.get("#{url}?code=dummy-secret-code") }.to raise_error(ExternalHttp::Failure) { |error|
        expect(error.message).to include("connection")
        expect(error.message).to include("api.example.test")
        expect(error.message).not_to include("dummy-secret-code")
        expect(error.message).not_to include("/v1/things")
      }
    end

    it "失敗はログに、符号とホストだけを出す（クエリ・本文・ヘッダの値は出さない）" do
      stub_request(:post, "#{url}?code=dummy-secret-code").to_raise(Errno::ECONNREFUSED)

      output = capture_logs do
        expect { http.post_form("#{url}?code=dummy-secret-code", form: { client_secret: "dummy-client-secret" }, headers: { "Authorization" => "Bearer dummy-bearer" }) }
          .to raise_error(ExternalHttp::Failure)
      end

      expect(output).to include("[external_http]")
      expect(output).to include("reason=connection")
      expect(output).to include("host=api.example.test")
      %w[ dummy-secret-code dummy-client-secret dummy-bearer ].each { |value| expect(output).not_to include(value) }
    end
  end

  describe "応答の大きさの上限" do
    it "上限を超える本文は、Failure（response_too_large）。メモリを使い切らない" do
      stub_request(:get, url).to_return(status: 200, body: "x" * 11)

      expect { described_class.new(max_body_bytes: 10).get(url) }
        .to raise_error(ExternalHttp::Failure) { |error| expect(error.reason).to eq(:response_too_large) }
    end

    it "上限ちょうどは通る" do
      stub_request(:get, url).to_return(status: 200, body: "x" * 10)

      expect(described_class.new(max_body_bytes: 10).get(url).body.bytesize).to eq(10)
    end

    it "Content-Length が上限を超えていれば、本文を読む前に Failure" do
      stub_request(:get, url).to_return(status: 200, body: "x", headers: { "Content-Length" => "999999" })

      expect { described_class.new(max_body_bytes: 10).get(url) }
        .to raise_error(ExternalHttp::Failure) { |error| expect(error.reason).to eq(:response_too_large) }
    end

    it "既定の上限は 1 MiB" do
      expect(described_class::MAX_BODY_BYTES).to eq(1_048_576)
    end

    it "上限の引数は、正の整数だけ" do
      [ 0, -1, nil, 1.5, "10" ].each do |value|
        expect { described_class.new(max_body_bytes: value) }.to raise_error(ArgumentError, /max_body_bytes/)
      end
    end
  end

  describe "JSON の応答" do
    it "json: 本文を JSON として解釈する" do
      stub_request(:get, url).to_return(status: 200, body: '{"keys":[{"kid":"a"}]}')

      expect(http.get(url).json).to eq({ "keys" => [ { "kid" => "a" } ] })
    end

    it "json: 解釈できない本文は Failure（invalid_json）" do
      [ "", "not json", "<html>", "{", "\xFF\xFE".b ].each do |body|
        stub_request(:get, url).to_return(status: 200, body: body)

        expect { http.get(url).json }.to raise_error(ExternalHttp::Failure) { |error| expect(error.reason).to eq(:invalid_json) }
      end
    end

    it "json: 入れ子が深すぎる本文は Failure（invalid_json）" do
      stub_request(:get, url).to_return(status: 200, body: "[" * 200 + "]" * 200)

      expect { http.get(url).json }.to raise_error(ExternalHttp::Failure) { |error| expect(error.reason).to eq(:invalid_json) }
    end
  end

  describe "URL の検査（URL は設定から来る。誤りは、呼び出しの誤りとして ArgumentError）" do
    [
      "http://api.example.test/v1",
      "ftp://api.example.test/v1",
      "https://",
      "https:///path",
      "//api.example.test/v1",
      "/relative/path",
      "https://user:pass@api.example.test/v1",
      "https://api.example.test:99999/v1",
      "",
      "not a url"
    ].each do |bad|
      it "#{bad.inspect} は、通信せずに ArgumentError" do
        expect { http.get(bad) }.to raise_error(ArgumentError)
        expect(a_request(:any, /./)).not_to have_been_made
      end
    end

    it "URL が文字列でなければ ArgumentError" do
      [ nil, 1, :sym, URI("https://api.example.test/") ].each do |bad|
        expect { http.get(bad) }.to raise_error(ArgumentError, /url/)
      end
    end

    it "https のポート指定（8443）は通る" do
      stub = stub_request(:get, "https://api.example.test:8443/v1").to_return(status: 200, body: "{}")

      http.get("https://api.example.test:8443/v1")

      expect(stub).to have_been_requested.once
    end
  end

  describe "ヘッダの検査" do
    it "ヘッダの値に改行を含む要求は、送らない（ヘッダの注入）" do
      expect { http.get(url, headers: { "X-Custom" => "a\r\nX-Injected: 1" }) }.to raise_error(ArgumentError)
      expect(a_request(:any, /./)).not_to have_been_made
    end

    it "ヘッダは、名前と値が文字列の Hash だけ" do
      expect { http.get(url, headers: [ [ "A", "b" ] ]) }.to raise_error(ArgumentError, /headers/)
      expect { http.get(url, headers: { "A" => 1 }) }.to raise_error(ArgumentError, /headers/)
    end
  end

  describe "ソースの規律" do
    it "実際の外部サービスへ、通信していない（WebMock が通信を禁止している）" do
      expect { Net::HTTP.get(URI("https://not-stubbed.example.test/")) }.to raise_error(WebMock::NetConnectNotAllowedError)
    end
  end
end
