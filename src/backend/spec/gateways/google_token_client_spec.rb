require "rails_helper"
require "pp"
require "support/external_http_support"
require "support/log_capture"

# Google のトークンエンドポイントとの通信（issue #10。requirements.md 7.3）。TokenVault が使う。
#   refresh  更新トークンから、アクセストークンを得る（grant_type=refresh_token）
#   revoke   トークンを失効させる（接続の解除）
# 通信は ExternalHttp（接続 3 秒・読み取り 5 秒・リダイレクトを追わない）。実際の Google は呼ばない（WebMock）。
# 失敗の分類: 恒久（invalid_grant -> TokenRevoked）・一時的（ネットワーク・429・5xx -> TokenTemporarilyUnavailable。状態を変えない）・
# それ以外（設定の誤り・形の違う応答 -> UnexpectedResponse）。トークン・秘密値を、例外・ログ・inspect に出さない。
RSpec.describe GoogleTokenClient do
  include LogCapture

  let(:client_id) { "dummy-client-id-0001.apps.googleusercontent.com" }
  let(:client_secret) { "dummy-google-client-secret-0001" }
  let(:refresh_token) { "1//dummy-refresh-token-must-not-appear" }
  let(:access_token) { "ya29.dummy-access-token-must-not-appear" }
  let(:endpoints) { ExternalServices.config.fetch(:google_oidc) }
  let(:client) do
    described_class.new(client_id: client_id, client_secret: client_secret, http: ExternalHttp.new, endpoints: endpoints)
  end
  let(:token_url) { "https://oauth2.googleapis.com/token" }
  let(:revoke_url) { "https://oauth2.googleapis.com/revoke" }

  def token_body(token: access_token, expires_in: 3599)
    { "access_token" => token, "expires_in" => expires_in, "scope" => "https://www.googleapis.com/auth/youtube", "token_type" => "Bearer" }.to_json
  end

  def refresh_failure
    client.refresh(refresh_token: refresh_token)
    nil
  rescue YouTubeErrors::Base => e
    e
  end

  describe "#refresh（アクセストークンの更新）" do
    it "トークンエンドポイントへ、更新トークンとクライアントの資格情報を、フォームで送る。アクセストークンと有効秒数を返す" do
      stub = stub_request(:post, token_url)
             .with(body: { "client_id" => client_id, "client_secret" => client_secret,
                           "refresh_token" => refresh_token, "grant_type" => "refresh_token" },
                   headers: { "Content-Type" => "application/x-www-form-urlencoded" })
             .to_return(status: 200, body: token_body)

      tokens = client.refresh(refresh_token: refresh_token)

      expect(stub).to have_been_requested.once
      expect(tokens.access_token).to eq(access_token)
      expect(tokens.expires_in).to eq(3599)
    end

    it "Tokens は、inspect・to_s・pretty_inspect にアクセストークンを出さない" do
      stub_request(:post, token_url).to_return(status: 200, body: token_body)

      tokens = client.refresh(refresh_token: refresh_token)

      [ tokens.inspect, tokens.to_s, tokens.pretty_inspect ].each do |text|
        expect(text).not_to include(access_token)
        expect(text).to include("FILTERED")
      end
    end

    it "リダイレクトは追わない（3xx は、想定外の応答。UnexpectedResponse）" do
      stub_request(:post, token_url).to_return(status: 302, headers: { "Location" => "https://evil.example/token" })

      expect(refresh_failure).to be_instance_of(YouTubeErrors::UnexpectedResponse)
    end

    describe "恒久的な失敗" do
      it "400 invalid_grant（取り消し・期限切れ）は TokenRevoked。reason は invalid_grant" do
        stub_request(:post, token_url).to_return(status: 400, body: { "error" => "invalid_grant", "error_description" => "Token has been expired or revoked." }.to_json)

        error = refresh_failure

        expect(error).to be_instance_of(YouTubeErrors::TokenRevoked)
        expect(error).to have_attributes(call_kind: :token_refresh, status: 400, reason: "invalid_grant")
      end
    end

    describe "一時的な失敗（状態を変えない）" do
      [ 429, 500, 502, 503, 504 ].each do |status|
        it "HTTP #{status} は TokenTemporarilyUnavailable" do
          stub_request(:post, token_url).to_return(status: status, body: "<html>temporary</html>")

          expect(refresh_failure).to be_instance_of(YouTubeErrors::TokenTemporarilyUnavailable)
        end
      end

      it "5xx で、本文が invalid_grant を含んでいても、一時的な失敗として扱う（恒久と取り違えない）" do
        stub_request(:post, token_url).to_return(status: 503, body: { "error" => "invalid_grant" }.to_json)

        expect(refresh_failure).to be_instance_of(YouTubeErrors::TokenTemporarilyUnavailable)
      end

      it "タイムアウト・接続の失敗・TLS の失敗は TokenTemporarilyUnavailable（detail に原因の符号）" do
        { timeout: Net::OpenTimeout, connection: Errno::ECONNREFUSED, tls: OpenSSL::SSL::SSLError }.each do |cause, exception|
          stub_request(:post, token_url).to_raise(exception)

          error = refresh_failure

          expect(error).to be_instance_of(YouTubeErrors::TokenTemporarilyUnavailable)
          expect(error.detail).to eq(cause)
        end
      end
    end

    describe "想定外の応答（UnexpectedResponse。状態を変えない）" do
      it "400 invalid_client（クライアントの設定の誤り）は、恒久の失効にしない" do
        stub_request(:post, token_url).to_return(status: 401, body: { "error" => "invalid_client" }.to_json)

        error = refresh_failure

        expect(error).to be_instance_of(YouTubeErrors::UnexpectedResponse)
        expect(error.reason).to eq("invalid_client")
      end

      it "404 などは、NotFound にしない（清算の呼び出しが、清算済みと取り違える）。UnexpectedResponse" do
        stub_request(:post, token_url).to_return(status: 404, body: "")

        expect(refresh_failure).to be_instance_of(YouTubeErrors::UnexpectedResponse)
      end

      {
        "JSON でない 200" => [ 200, "not json", :invalid_json ],
        "JSON の配列" => [ 200, "[]", :token_response_invalid ],
        "access_token が無い" => [ 200, { "expires_in" => 3599 }.to_json, :token_response_invalid ],
        "access_token が空" => [ 200, { "access_token" => "", "expires_in" => 3599 }.to_json, :token_response_invalid ],
        "access_token に空白・改行（ヘッダを壊す）" => [ 200, { "access_token" => "abc\r\nX-Evil: 1", "expires_in" => 3599 }.to_json, :token_response_invalid ],
        "expires_in が無い" => [ 200, { "access_token" => "ya29.x" }.to_json, :token_response_invalid ],
        "expires_in が文字列" => [ 200, { "access_token" => "ya29.x", "expires_in" => "3599" }.to_json, :token_response_invalid ],
        "expires_in が 0" => [ 200, { "access_token" => "ya29.x", "expires_in" => 0 }.to_json, :token_response_invalid ],
        "expires_in が負" => [ 200, { "access_token" => "ya29.x", "expires_in" => -1 }.to_json, :token_response_invalid ],
        "expires_in が大きすぎる（1 日超）" => [ 200, { "access_token" => "ya29.x", "expires_in" => 86_401 }.to_json, :token_response_invalid ]
      }.each do |label, (status, body, detail)|
        it "#{label}: UnexpectedResponse（#{detail}）" do
          stub_request(:post, token_url).to_return(status: status, body: body)

          error = refresh_failure

          expect(error).to be_instance_of(YouTubeErrors::UnexpectedResponse)
          expect(error.detail).to eq(detail)
        end
      end

      it "応答が大きすぎる（1 MiB 超）は UnexpectedResponse" do
        stub_request(:post, token_url).to_return(status: 200, body: "x" * (ExternalHttp::MAX_BODY_BYTES + 1))

        error = refresh_failure

        expect(error).to be_instance_of(YouTubeErrors::UnexpectedResponse)
        expect(error.detail).to eq(:response_too_large)
      end

      # ExternalHttp は Zlib::Error を受け止めない（壊れた gzip は、生の例外になり得る）。窓口側で型付きの例外にする
      it "壊れた gzip（Zlib::Error）は、生の例外にせず UnexpectedResponse（detail: invalid_encoding）" do
        [ Zlib::DataError, Zlib::BufError, Zlib::GzipFile::Error ].each do |exception|
          stub_request(:post, token_url).to_raise(exception)

          error = refresh_failure

          expect(error).to be_instance_of(YouTubeErrors::UnexpectedResponse)
          expect(error.detail).to eq(:invalid_encoding)
        end
      end
    end

    it "失敗の例外・ログに、更新トークン・アクセストークン・秘密値・応答の本文を出さない" do
      stub_request(:post, token_url).to_return(status: 400, body: { "error" => "invalid_grant", "error_description" => "dummy-description-must-not-appear" }.to_json)
      error = nil

      output = capture_logs { error = refresh_failure }

      forbidden = [ refresh_token, access_token, client_secret, client_id, "dummy-description-must-not-appear" ]
      [ output, error.message, error.inspect, error.full_message ].each do |text|
        forbidden.each { |secret| expect(text).not_to include(secret) }
      end
    end

    it "refresh_token が文字列でない・空は ArgumentError（通信しない）" do
      [ nil, "", "  ", 1, :token ].each do |value|
        expect { client.refresh(refresh_token: value) }.to raise_error(ArgumentError, /refresh_token/)
      end
      expect(a_request(:any, /.*/)).not_to have_been_made
    end
  end

  describe "#revoke（トークンの失効）" do
    it "失効エンドポイントへ、トークンをフォームで送る（クライアントの資格情報は送らない）。200 は :revoked" do
      stub = stub_request(:post, revoke_url)
             .with(body: { "token" => refresh_token }, headers: { "Content-Type" => "application/x-www-form-urlencoded" })
             .to_return(status: 200, body: "")

      expect(client.revoke(token: refresh_token)).to eq(:revoked)
      expect(stub).to have_been_requested.once
    end

    it "400 invalid_token（すでに失効・期限切れ）は :already_invalid" do
      stub_request(:post, revoke_url).to_return(status: 400, body: { "error" => "invalid_token", "error_description" => "Token expired or revoked" }.to_json)

      expect(client.revoke(token: refresh_token)).to eq(:already_invalid)
    end

    it "429・5xx・通信の失敗は TokenTemporarilyUnavailable" do
      [ 429, 500, 503 ].each do |status|
        stub_request(:post, revoke_url).to_return(status: status, body: "")
        expect { client.revoke(token: refresh_token) }.to raise_error(YouTubeErrors::TokenTemporarilyUnavailable)
      end
      stub_request(:post, revoke_url).to_timeout
      expect { client.revoke(token: refresh_token) }.to raise_error(YouTubeErrors::TokenTemporarilyUnavailable)
    end

    it "それ以外の 4xx・invalid_token でない 400 は UnexpectedResponse" do
      stub_request(:post, revoke_url).to_return(status: 400, body: { "error" => "invalid_request" }.to_json)
      expect { client.revoke(token: refresh_token) }.to raise_error(YouTubeErrors::UnexpectedResponse)

      stub_request(:post, revoke_url).to_return(status: 403, body: "")
      expect { client.revoke(token: refresh_token) }.to raise_error(YouTubeErrors::UnexpectedResponse)
    end

    it "壊れた gzip（Zlib::Error）は、生の例外にせず UnexpectedResponse（detail: invalid_encoding）" do
      stub_request(:post, revoke_url).to_raise(Zlib::DataError)

      expect { client.revoke(token: refresh_token) }.to raise_error(YouTubeErrors::UnexpectedResponse) { |error|
        expect(error.detail).to eq(:invalid_encoding)
      }
    end

    it "失敗の例外・ログに、トークンを出さない" do
      stub_request(:post, revoke_url).to_return(status: 500, body: "dummy-body-must-not-appear")
      error = nil

      output = capture_logs do
        error = begin
          client.revoke(token: refresh_token)
        rescue YouTubeErrors::Base => e
          e
        end
      end

      [ output, error.message, error.inspect ].each do |text|
        expect(text).not_to include(refresh_token)
        expect(text).not_to include("dummy-body-must-not-appear")
      end
    end
  end

  describe "構築" do
    it "クライアント ID・秘密値は、空でない文字列。エンドポイントは https の URL（呼び出し側の誤りは ArgumentError）" do
      expect { described_class.new(client_id: "", client_secret: "x", http: ExternalHttp.new, endpoints: endpoints) }.to raise_error(ArgumentError, /client_id/)
      expect { described_class.new(client_id: "x", client_secret: nil, http: ExternalHttp.new, endpoints: endpoints) }.to raise_error(ArgumentError, /client_secret/)
      expect { described_class.new(client_id: "x", client_secret: "y", http: ExternalHttp.new, endpoints: endpoints.merge(token_endpoint: "http://insecure.example/token")) }
        .to raise_error(ArgumentError, /token_endpoint/)
      expect { described_class.new(client_id: "x", client_secret: "y", http: ExternalHttp.new, endpoints: endpoints.except(:revoke_endpoint)) }
        .to raise_error(ArgumentError, /revoke_endpoint/)
    end

    it "inspect に、クライアント ID・秘密値を出さない" do
      expect(client.inspect).to eq("#<GoogleTokenClient>")
      expect(client.to_s).not_to include(client_secret)
    end

    it "エンドポイントは、設定ファイルの値（Google のトークン・失効の URL）" do
      expect(endpoints.fetch(:token_endpoint)).to eq(token_url)
      expect(endpoints.fetch(:revoke_endpoint)).to eq(revoke_url)
    end
  end
end
