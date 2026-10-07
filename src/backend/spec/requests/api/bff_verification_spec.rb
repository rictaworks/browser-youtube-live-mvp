require "rails_helper"
require "support/api_helpers"

# フロントエンド（BFF）からの要求の確認（src/contracts/http-api.md 1.2・1.4。requirements.md 6.1・28.1。issue #7）。
# /api/* は、X-BFF-Secret（環境変数 BFF_SHARED_SECRET）が一致する要求だけを受け付ける。欠落・不一致は 403 forbidden（手がかりを書かない）。
# /up（ヘルスチェック）は対象外。
RSpec.describe "BFF の確認（X-BFF-Secret）", type: :request do
  include ApiHelpers
  include_context "API の環境"

  forbidden_body = { "error" => { "code" => "forbidden", "details" => {} } }

  # 確認の対象になる、/api の経路（存在しない経路も含む。確認は、経路の存在より先）
  targets = {
    "GET /api/usage-events" => [ :get, "/api/usage-events" ],
    "POST /api/usage-events" => [ :post, "/api/usage-events" ],
    "GET 存在しない /api の経路" => [ :get, "/api/no-such-endpoint" ],
    "POST 存在しない /api の経路" => [ :post, "/api/no-such/endpoint" ],
    "DELETE 存在しない /api の経路" => [ :delete, "/api/account" ],
    "GET /api/state（#12 の経路。まだ無い）" => [ :get, "/api/state" ]
  }

  def request_with(verb, path, headers)
    public_send(verb, path, headers: headers, env: public_listener_env)
  end

  describe "欠落・不一致は 403 forbidden（本文に手がかりを書かない）" do
    targets.each do |label, (verb, path)|
      it "#{label}: X-BFF-Secret が無ければ 403" do
        request_with(verb, path, { "X-BL-Client" => "web" })

        expect(response).to have_http_status(:forbidden)
        expect(json_body).to eq(forbidden_body)
      end
    end

    {
      "空" => "",
      "空白" => " ",
      "1 文字違い" => "#{ApiHelpers::BFF_SECRET[0..-2]}x",
      "短い（前方一致）" => ApiHelpers::BFF_SECRET[0..-2],
      "長い（後ろに足した）" => "#{ApiHelpers::BFF_SECRET}x",
      "大文字" => ApiHelpers::BFF_SECRET.upcase,
      "前後の空白" => " #{ApiHelpers::BFF_SECRET} ",
      "別の秘密値（中継の秘密値など）" => "dummy-relay-shared-secret-0001"
    }.each do |label, value|
      it "X-BFF-Secret が #{label} なら 403（欠落と同じ応答）" do
        get "/api/no-such-endpoint", headers: { "X-BFF-Secret" => value }, env: public_listener_env

        expect(response).to have_http_status(:forbidden)
        expect(json_body).to eq(forbidden_body)
      end
    end

    it "欠落・不一致・空の応答は、本文もヘッダも同じ（秘密値の有無・長さの手がかりを返さない）" do
      get "/api/no-such-endpoint", env: public_listener_env
      missing = [ response.status, response.body, response.headers.to_h.except("x-request-id", "x-runtime", "server-timing") ]
      get "/api/no-such-endpoint", headers: { "X-BFF-Secret" => "wrong" }, env: public_listener_env
      wrong = [ response.status, response.body, response.headers.to_h.except("x-request-id", "x-runtime", "server-timing") ]
      get "/api/no-such-endpoint", headers: { "X-BFF-Secret" => "" }, env: public_listener_env
      blank = [ response.status, response.body, response.headers.to_h.except("x-request-id", "x-runtime", "server-timing") ]

      expect(wrong.first(2)).to eq(missing.first(2))
      expect(blank.first(2)).to eq(missing.first(2))
      expect(wrong.last).to eq(missing.last)
      expect(blank.last).to eq(missing.last)
    end

    it "秘密値を、応答のヘッダ・本文へ出さない" do
      get "/api/no-such-endpoint", headers: { "X-BFF-Secret" => "dummy-wrong-secret-must-not-appear" }, env: public_listener_env

      expect(response.body).not_to include("dummy-wrong-secret-must-not-appear")
      expect(response.body).not_to include(ApiHelpers::BFF_SECRET)
      expect(response.headers.to_h.values.join).not_to include(ApiHelpers::BFF_SECRET)
    end

    it "確認の失敗は、状態を変える要求の検査（X-BL-Client・CSRF）より先。X-BL-Client が無くても 403 forbidden" do
      post "/api/usage-events", headers: {}, env: public_listener_env

      expect(response).to have_http_status(:forbidden)
      expect(error_code).to eq("forbidden")
    end

    it "確認を通らない要求は、副作用を持たない（データを作らない）" do
      user = create(:user)
      signed_in = sign_in(user)

      expect do
        api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in, headers: { "X-BFF-Secret" => "wrong" }
      end.not_to change(UsageEvent, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "確認を通る" do
    it "秘密値が一致すれば、次の検査へ進む（存在しない経路は 404）" do
      api_get "/api/no-such-endpoint"

      expect(response).to have_http_status(:not_found)
    end

    it "秘密値は、要求のたびに、環境変数 BFF_SHARED_SECRET から読む（ローテーションに、再起動が要らない）" do
      ENV["BFF_SHARED_SECRET"] = "dummy-rotated-secret-0002"

      api_get "/api/no-such-endpoint"
      expect(response).to have_http_status(:forbidden)

      api_get "/api/no-such-endpoint", headers: { "X-BFF-Secret" => "dummy-rotated-secret-0002" }
      expect(response).to have_http_status(:not_found)
    end

    it "定数時間の比較を使う" do
      expect(ActiveSupport::SecurityUtils).to receive(:fixed_length_secure_compare).at_least(:once).and_call_original

      api_get "/api/no-such-endpoint"
    end
  end

  describe "サーバー側の秘密値が無い（設定の不備）" do
    it "BFF_SHARED_SECRET が未設定なら、すべての要求を拒否する（500 internal_error。空の秘密値で通さない）" do
      ENV["BFF_SHARED_SECRET"] = nil

      get "/api/no-such-endpoint", env: public_listener_env
      expect(response).to have_http_status(:internal_server_error)
      expect(error_code).to eq("internal_error")

      get "/api/no-such-endpoint", headers: { "X-BFF-Secret" => "" }, env: public_listener_env
      expect(response).to have_http_status(:internal_server_error)

      get "/api/no-such-endpoint", headers: bff_headers, env: public_listener_env
      expect(response).to have_http_status(:internal_server_error)
    end

    it "BFF_SHARED_SECRET が空でも、同じ（空の秘密値と、空のヘッダが一致して通る事故を防ぐ）" do
      ENV["BFF_SHARED_SECRET"] = ""

      get "/api/no-such-endpoint", headers: { "X-BFF-Secret" => "" }, env: public_listener_env

      expect(response).to have_http_status(:internal_server_error)
    end

    it "応答・ログに、設定の不備の詳細（環境変数の値）を出さない" do
      ENV["BFF_SHARED_SECRET"] = nil

      get "/api/no-such-endpoint", env: public_listener_env

      expect(json_body).to eq({ "error" => { "code" => "internal_error", "details" => {} } })
    end
  end

  describe "ヘルスチェック（/up）は対象外" do
    it "X-BFF-Secret が無くても 200" do
      get "/up", env: public_listener_env

      expect(response).to have_http_status(:ok)
    end

    it "不一致の X-BFF-Secret があっても 200" do
      get "/up", headers: { "X-BFF-Secret" => "wrong" }, env: public_listener_env

      expect(response).to have_http_status(:ok)
    end
  end

  describe "転送ヘッダは、確認を通った要求からだけ読む" do
    it "確認を通らない要求では、X-Forwarded-For（IP）・X-Forwarded-Host・X-Forwarded-Proto を、解釈しない" do
      expect(ClientIp).not_to receive(:parse)
      expect(PublicOrigin).not_to receive(:from_forwarded)

      get "/api/no-such-endpoint",
          headers: { "X-Forwarded-For" => "203.0.113.5", "X-Forwarded-Host" => "evil.example", "X-Forwarded-Proto" => "https", "X-BFF-Secret" => "wrong" },
          env: public_listener_env

      expect(response).to have_http_status(:forbidden)
    end

    it "確認を通らない要求の転送ヘッダは、応答に影響しない（IP を理由とする分岐が無い）" do
      get "/api/no-such-endpoint", headers: { "X-Forwarded-For" => "not-an-ip" }, env: public_listener_env
      without = [ response.status, response.body ]
      get "/api/no-such-endpoint", headers: { "X-Forwarded-For" => "203.0.113.5" }, env: public_listener_env

      expect([ response.status, response.body ]).to eq(without)
    end
  end
end
