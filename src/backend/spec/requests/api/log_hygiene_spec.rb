require "rails_helper"
require "support/api_helpers"
require "support/log_capture"

# ログへ機密・IP を出さない（issue #7。requirements.md 6.1・7.3・10.1・28.1・28.2。CLAUDE.md の不変条件）。
# 実際に要求を送り、ログ（Rails.logger へ出た、すべてのレベルの出力）に、値が現れないことを確かめる。
# 値は、明らかなダミー。出力が空のために、現れていないのではないことも確かめる（開始の行・伏せ字が出ている）。
RSpec.describe "ログの機密の除外", type: :request do
  include ApiHelpers
  include_context "API の環境"

  let(:user) { create(:user, google_sub: "dummy-google-sub-must-not-appear-0001") }
  let(:signed_in) { sign_in(user) }

  # 名前 => ダミーの値（値は、すべて異なる文字列。ログに現れたら、どの名前の値かが、分かる）
  secret_values = %w[
    ticket stream_key recaptcha_token code state refresh_token access_token id_token token secret password title nonce code_verifier
  ].to_h { |name| [ name, "dummy-#{name.tr('_', '-')}-value-must-not-appear" ] }

  header_values = {
    "Authorization" => "Bearer dummy-authorization-value-must-not-appear",
    "X-Relay-Secret" => "dummy-relay-secret-value-must-not-appear",
    "X-Custom-Cookie-Like" => "dummy-custom-header-value"
  }

  def expect_none_of(output, values)
    values.each { |value| expect(output).not_to include(value), "ログに値が現れた: #{value}" }
  end

  describe "クエリのパラメータ（認可コード・state・チケット・配信キー など）" do
    it "GET の経路のクエリ・Parameters の行に、値が現れない。伏せ字が出る" do
      query = secret_values.map { |name, value| "#{name}=#{value}" }.join("&")

      output = capture_logs { api_get "/api/no-such-endpoint?#{query}&page=2" }

      expect(response).to have_http_status(404)
      expect(output).to include("Started GET")
      expect(output).to include("[FILTERED]")
      expect(output).to include("page=2")
      expect_none_of(output, secret_values.values)
    end

    it "OAuth のコールバックの形（認可コードと state）のクエリも、値が現れない" do
      output = capture_logs { api_get "/api/auth/callback?code=dummy-auth-code-0123&state=dummy-oauth-state-4567" }

      expect(output).to include("Started GET")
      expect_none_of(output, [ "dummy-auth-code-0123", "dummy-oauth-state-4567" ])
    end
  end

  describe "本文のパラメータ（JSON）" do
    it "ログイン済みの POST の本文の Parameters の行に、値が現れない。処理の行は出ている" do
      body = { event_type: "watch_url_copied" }.merge(secret_values)

      output = capture_logs { api_post "/api/usage-events", body, signed_in: signed_in }

      expect(response).to have_http_status(204)
      expect(output).to include("Processing by Api::UsageEventsController#create")
      expect(output).to include("Parameters:")
      expect(output).to include("[FILTERED]")
      expect_none_of(output, secret_values.values)
    end

    it "入れ子の本文でも、値が現れない" do
      body = { event_type: "watch_url_copied", nested: { deep: secret_values } }

      output = capture_logs { api_post "/api/usage-events", body, signed_in: signed_in }

      expect(output).to include("Parameters:")
      expect_none_of(output, secret_values.values)
    end

    it "配信のタイトルは、本文に含まれても、ログへ出ない（#12 の POST /api/broadcasts の title）" do
      output = capture_logs { api_post "/api/usage-events", { event_type: "watch_url_copied", title: "dummy-broadcast-title-must-not-appear" }, signed_in: signed_in }

      expect(output).not_to include("dummy-broadcast-title-must-not-appear")
    end
  end

  describe "ヘッダ・Cookie" do
    it "Authorization・X-Relay-Secret・Cookie（セッションの識別子）・X-BFF-Secret・X-CSRF-Token の値が、ログに現れない" do
      output = capture_logs do
        api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in, headers: header_values.merge("Cookie" => "#{SessionCookie::NAME}=#{signed_in.token}; other=dummy-other-cookie-value")
      end

      expect(response).to have_http_status(204)
      expect(output).to include("Started POST")
      expect_none_of(
        output,
        header_values.values + [ signed_in.token, signed_in.csrf_token, ApiHelpers::BFF_SECRET, "dummy-other-cookie-value" ]
      )
    end

    it "BFF の確認を通らない要求でも、送られた秘密値・Cookie の値が、ログに現れない" do
      output = capture_logs do
        get "/api/no-such-endpoint",
            headers: header_values.merge("X-BFF-Secret" => "dummy-wrong-bff-secret-must-not-appear", "Cookie" => "#{SessionCookie::NAME}=dummy-cookie-token-must-not-appear"),
            env: public_listener_env
      end

      expect(response).to have_http_status(403)
      expect_none_of(output, header_values.values + [ "dummy-wrong-bff-secret-must-not-appear", "dummy-cookie-token-must-not-appear" ])
    end

    it "セッションの識別子・要約値（SHA-256）が、SQL のログに現れない" do
      output = capture_logs { api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in }

      expect(output).to include("sessions")
      expect_none_of(output, [ signed_in.token, Digest::SHA256.hexdigest(signed_in.token) ])
    end

    it "Google の利用者識別子（sub）が、ログに現れない" do
      output = capture_logs { api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in }

      expect(output).not_to include("dummy-google-sub-must-not-appear-0001")
    end
  end

  describe "IP アドレス（頻度制限の計数にだけ使う）" do
    let(:remote_ip) { "198.51.100.77" }
    let(:forwarded_ip) { "203.0.113.77" }

    it "BFF の確認を通った要求: X-Forwarded-For の IP も、接続元の IP（REMOTE_ADDR）も、ログに現れない" do
      output = capture_logs do
        api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in,
                 headers: { "X-Forwarded-For" => "#{forwarded_ip}, 10.0.0.9" }, env: public_listener_env.merge("REMOTE_ADDR" => remote_ip)
      end

      expect(response).to have_http_status(204)
      expect(output).to include("Started POST")
      expect_none_of(output, [ forwarded_ip, remote_ip ])
    end

    it "BFF の確認を通らない要求: X-Forwarded-For・Client-IP の IP も、ログに現れない" do
      output = capture_logs do
        get "/api/no-such-endpoint", headers: { "X-Forwarded-For" => forwarded_ip, "Client-IP" => "203.0.113.78" },
                                     env: public_listener_env.merge("REMOTE_ADDR" => remote_ip)
      end

      expect(response).to have_http_status(403)
      expect_none_of(output, [ forwarded_ip, "203.0.113.78", remote_ip ])
    end

    it "X-Forwarded-For と Client-IP が食い違っても、500 にならず、IP がログに現れない" do
      output = capture_logs do
        get "/api/no-such-endpoint", headers: bff_headers("X-Forwarded-For" => forwarded_ip, "Client-IP" => "203.0.113.99"), env: public_listener_env
      end

      expect(response).to have_http_status(404)
      expect_none_of(output, [ forwarded_ip, "203.0.113.99" ])
    end

    it "ヘルスチェック（/up）の要求でも、IP がログに現れない" do
      output = capture_logs { get "/up", headers: { "X-Forwarded-For" => forwarded_ip }, env: public_listener_env.merge("REMOTE_ADDR" => remote_ip) }

      expect_none_of(output, [ forwarded_ip, remote_ip ])
    end

    it "IP は、DB の測定イベントにも記録されない" do
      api_post "/api/usage-events", { event_type: "watch_url_copied", ip: forwarded_ip }, signed_in: signed_in,
               headers: { "X-Forwarded-For" => forwarded_ip }

      dump = UsageEvent.connection.select_values("SELECT row_to_json(u)::text FROM usage_events u").join
      expect(dump).not_to include(forwarded_ip)
    end
  end

  describe "例外" do
    it "500 のログに、例外の文面（機密を含み得る）が現れない。例外のクラスは出る" do
      allow(UsageRecorder).to receive(:record).and_raise(
        ArgumentError, "invalid value dummy-session=#{signed_in.token} dummy-secret-in-exception-message-must-not-appear"
      )

      output = capture_logs { api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in }

      expect(response).to have_http_status(500)
      expect(output).to include("ArgumentError")
      expect_none_of(output, [ "dummy-secret-in-exception-message-must-not-appear", signed_in.token ])
    end

    it "データベースの一意違反の例外（キーの値を含む）が、ログに現れない" do
      allow(UsageRecorder).to receive(:record).and_raise(
        ActiveRecord::RecordNotUnique, "PG::UniqueViolation: Key (google_sub)=(dummy-google-sub-in-detail-must-not-appear) already exists."
      )

      output = capture_logs { api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in }

      expect(output).to include("ActiveRecord::RecordNotUnique")
      expect(output).not_to include("dummy-google-sub-in-detail-must-not-appear")
    end

    it "ログに出る行は、改行で壊れない（例外のクラス名・位置だけ。攻撃者が選べる値を出さない）" do
      allow(UsageRecorder).to receive(:record).and_raise(RuntimeError, "line1\nFAKE LOG LINE injected")

      output = capture_logs { api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in }

      expect(output).not_to include("FAKE LOG LINE")
    end
  end

  describe "ログの検査の仕組み（空の出力で、通っていない）" do
    it "捕捉したログには、要求の開始の行と、伏せ字が出る（ダミーの値が現れる状態で、検査していることの確認）" do
      output = capture_logs { api_get "/api/no-such-endpoint?token=dummy-visible-check-value" }

      expect(output).to match(/Started GET "\/api\/no-such-endpoint\?token=\[FILTERED\]"/)
    end

    it "ログへ書いた値は、捕捉される（検査が、値を見つけられる）" do
      output = capture_logs { Rails.logger.info("marker dummy-marker-value") }

      expect(output).to include("dummy-marker-value")
    end
  end
end
