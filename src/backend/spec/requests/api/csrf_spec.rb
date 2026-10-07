require "rails_helper"
require "support/api_helpers"

# CSRF 対策（src/contracts/http-api.md 1.2・1.4。requirements.md 28.1。issue #7）。
# 状態を変える要求（POST・PUT・PATCH・DELETE）は、X-BL-Client: web を必須とし、ログイン済みなら、X-CSRF-Token（セッションに紐づく値）を必須とする。
# 欠落・不一致は 403 csrf_invalid。Origin ヘッダがあれば、公開オリジンと一致しなければ 403。GET は対象外。
RSpec.describe "CSRF 対策", type: :request do
  include ApiHelpers
  include_context "API の環境"

  let(:user) { create(:user) }
  let(:signed_in) { sign_in(user) }
  let(:csrf_invalid) { { "error" => { "code" => "csrf_invalid", "details" => {} } } }

  # 存在しない /api の経路（CSRF の検査は、経路の存在より先。評価の順: BFF → X-BL-Client → CSRF・Origin → ログイン → 経路）
  let(:unknown_path) { "/api/no-such-endpoint" }

  describe "状態を変える要求は、X-BL-Client: web を必須とする（クロスサイトのフォームの送信を成立させない）" do
    %i[ post put patch delete ].each do |verb|
      it "#{verb.upcase}: X-BL-Client が無ければ 403 csrf_invalid" do
        public_send(verb, unknown_path, headers: bff_headers, env: public_listener_env)

        expect(response).to have_http_status(:forbidden)
        expect(json_body).to eq(csrf_invalid)
      end

      it "#{verb.upcase}: X-BL-Client: web があれば、次の検査へ進む（存在しない経路は 404）" do
        public_send(verb, unknown_path, headers: bff_headers("X-BL-Client" => "web"), env: public_listener_env)

        expect(response).to have_http_status(:not_found)
      end
    end

    [ "", "Web", "WEB", "true", "1", "web ", " web", "web,web", "browser" ].each do |value|
      it "X-BL-Client が #{value.inspect} なら 403 csrf_invalid（値は web だけ）" do
        post unknown_path, headers: bff_headers("X-BL-Client" => value), env: public_listener_env

        expect(response).to have_http_status(:forbidden)
        expect(error_code).to eq("csrf_invalid")
      end
    end

    it "フォームの送信（application/x-www-form-urlencoded）で、X-BL-Client が無ければ 403" do
      post unknown_path, params: "a=1", headers: bff_headers("Content-Type" => "application/x-www-form-urlencoded"), env: public_listener_env

      expect(response).to have_http_status(:forbidden)
      expect(error_code).to eq("csrf_invalid")
    end
  end

  describe "GET・HEAD は、CSRF の対象外（副作用を持たせない）" do
    it "GET: X-BL-Client も X-CSRF-Token も要らない（BFF の確認だけ）" do
      get unknown_path, headers: bff_headers, env: public_listener_env

      expect(response).to have_http_status(:not_found)
    end

    it "GET: ログイン済みでも、X-CSRF-Token は要らない" do
      get unknown_path, headers: bff_headers("Cookie" => "#{SessionCookie::NAME}=#{signed_in.token}"), env: public_listener_env

      expect(response).to have_http_status(:not_found)
    end

    it "GET: Origin が違っても、検査しない（認可コードのコールバックの GET は、state で守る）" do
      get unknown_path, headers: bff_headers("Origin" => "https://evil.example"), env: public_listener_env

      expect(response).to have_http_status(:not_found)
    end

    it "HEAD も対象外" do
      head unknown_path, headers: bff_headers, env: public_listener_env

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "ログイン済み: X-CSRF-Token（セッションに紐づく値）を必須とする" do
    let(:headers) { api_headers(signed_in: signed_in, state_changing: true) }

    it "正しい X-CSRF-Token なら、次の検査へ進む" do
      post unknown_path, headers: headers, env: public_listener_env

      expect(response).to have_http_status(:not_found)
    end

    it "X-CSRF-Token が無ければ 403 csrf_invalid" do
      post unknown_path, headers: headers.except("X-CSRF-Token"), env: public_listener_env

      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq(csrf_invalid)
    end

    {
      "空" => "",
      "でたらめ" => "0" * 64,
      "1 文字違い" => :one_off,
      "短い" => :short,
      "長い" => :long,
      "セッションの識別子そのもの" => :session_token
    }.each do |label, kind|
      it "X-CSRF-Token が #{label} なら 403 csrf_invalid" do
        value =
          case kind
          when :one_off then "#{signed_in.csrf_token[0..-2]}#{signed_in.csrf_token[-1] == '0' ? '1' : '0'}"
          when :short then signed_in.csrf_token[0, 63]
          when :long then "#{signed_in.csrf_token}0"
          when :session_token then signed_in.token
          else kind
          end

        post unknown_path, headers: headers.merge("X-CSRF-Token" => value), env: public_listener_env

        expect(response).to have_http_status(:forbidden)
        expect(error_code).to eq("csrf_invalid")
      end
    end

    it "別のセッションの X-CSRF-Token は、403（セッションごとに違う値）" do
      other = sign_in(create(:user))

      post unknown_path, headers: headers.merge("X-CSRF-Token" => other.csrf_token), env: public_listener_env

      expect(response).to have_http_status(:forbidden)
    end

    it "同じアカウントの別のセッションの X-CSRF-Token も、403（アカウントではなく、セッションに紐づく）" do
      second = sign_in(user)

      post unknown_path, headers: headers.merge("X-CSRF-Token" => second.csrf_token), env: public_listener_env

      expect(response).to have_http_status(:forbidden)
    end

    it "X-CSRF-Token は、セッションの識別子と SESSION_SECRET から HMAC で導出した値（GET /api/state が返す値と同じ導出）" do
      expect(signed_in.csrf_token).to eq(CsrfToken.new(secret: Rails.application.secret_key_base).derive(signed_in.token))
    end

    it "X-CSRF-Token は、保存しない（DB のどの行にも、値が無い）" do
      signed_in

      dump = Session.connection.select_values("SELECT row_to_json(s)::text FROM sessions s").join
      expect(dump).not_to include(signed_in.csrf_token)
      expect(Session.column_names).not_to include("csrf_token")
    end

    it "セッションを破棄すれば、その X-CSRF-Token があっても、ログインしていない扱い（ログインが要る API は 401）" do
      SessionStore.new.revoke(signed_in.session)

      post "/api/usage-events", headers: headers, env: public_listener_env

      expect(response).to have_http_status(:unauthorized)
      expect(error_code).to eq("not_logged_in")
    end
  end

  describe "ログインしていない: X-CSRF-Token の検査は無く、X-BL-Client だけ" do
    it "X-BL-Client があれば、次の検査へ進む（ログインが要る API は 401 not_logged_in）" do
      post "/api/usage-events", headers: bff_headers("X-BL-Client" => "web"), env: public_listener_env

      expect(response).to have_http_status(:unauthorized)
      expect(error_code).to eq("not_logged_in")
    end

    it "X-BL-Client が無ければ、401 ではなく 403 csrf_invalid（評価の順）" do
      post "/api/usage-events", headers: bff_headers, env: public_listener_env

      expect(response).to have_http_status(:forbidden)
      expect(error_code).to eq("csrf_invalid")
    end

    it "存在しない・破棄済みのセッションの Cookie があっても、X-CSRF-Token は要らない（ログインしていない扱い）" do
      post "/api/usage-events",
           headers: bff_headers("X-BL-Client" => "web", "Cookie" => "#{SessionCookie::NAME}=#{SecureRandom.urlsafe_base64(32)}"),
           env: public_listener_env

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "Origin ヘッダ（あれば、公開オリジンと一致すること）" do
    let(:base) { api_headers(signed_in: signed_in, state_changing: true) }

    it "公開オリジンと一致すれば通る" do
      post unknown_path, headers: base.merge("Origin" => "https://app.example.test"), env: public_listener_env

      expect(response).to have_http_status(:not_found)
    end

    it "Origin が無ければ、検査しない（同一オリジンの GET 以外の要求で、ブラウザが付けない場合がある）" do
      post unknown_path, headers: base.except("Origin"), env: public_listener_env

      expect(response).to have_http_status(:not_found)
    end

    it "大文字・小文字の違いは許す" do
      post unknown_path, headers: base.merge("Origin" => "HTTPS://App.Example.Test"), env: public_listener_env

      expect(response).to have_http_status(:not_found)
    end

    {
      "別のオリジン" => "https://evil.example",
      "サブドメインを足した" => "https://evil.app.example.test",
      "スキームが違う" => "http://app.example.test",
      "ポートが違う" => "https://app.example.test:8443",
      "null" => "null",
      "空" => "",
      "バックエンド自身のオリジン" => "https://backend.up.railway.app"
    }.each do |label, origin|
      it "Origin が #{label}（#{origin.inspect}）なら 403 csrf_invalid" do
        post unknown_path, headers: base.merge("Origin" => origin), env: public_listener_env

        expect(response).to have_http_status(:forbidden)
        expect(json_body).to eq(csrf_invalid)
      end
    end

    it "ログインしていない要求でも、Origin が違えば 403（ログイン開始のクロスサイトの送信を止める）" do
      post "/api/usage-events", headers: bff_headers("X-BL-Client" => "web", "Origin" => "https://evil.example"), env: public_listener_env

      expect(response).to have_http_status(:forbidden)
      expect(error_code).to eq("csrf_invalid")
    end

    it "Origin があり、公開オリジン（X-Forwarded-Host）が分からなければ、確認できないので 403（拒否側へ倒す）" do
      post unknown_path, headers: base.merge("X-Forwarded-Host" => nil).compact, env: public_listener_env

      expect(response).to have_http_status(:forbidden)
      expect(error_code).to eq("csrf_invalid")
    end

    it "Origin があり、X-Forwarded-Host が不正なら、403" do
      post unknown_path, headers: base.merge("X-Forwarded-Host" => "evil.example/path"), env: public_listener_env

      expect(response).to have_http_status(:forbidden)
    end

    it "Origin が無ければ、公開オリジンが分からなくても通る（照合する相手が無い）" do
      post unknown_path, headers: base.except("Origin").merge("X-Forwarded-Host" => nil).compact, env: public_listener_env

      expect(response).to have_http_status(:not_found)
    end

    it "公開オリジンは、BFF が付けた X-Forwarded-Host・X-Forwarded-Proto（ブラウザの値ではない）から作る" do
      post unknown_path, headers: base.merge("X-Forwarded-Host" => "other.example.test", "Origin" => "https://other.example.test"), env: public_listener_env

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "Rails 標準の CSRF 対策（セッションの authenticity_token）は、API に効かない（自前の方式で守る）" do
    around do |example|
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    it "標準の対策を有効にしても、正しいヘッダの POST は、そのまま通る（authenticity_token を要求しない）" do
      api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in

      expect(response).to have_http_status(:no_content)
    end

    it "標準のセッションの Cookie（_session_id など）を、出さない" do
      api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in

      expect(response.headers["Set-Cookie"]).to be_nil
    end
  end
end
