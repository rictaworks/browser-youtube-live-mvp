require "rails_helper"
require "support/api_helpers"
require "support/log_capture"

# エラーの形（src/contracts/http-api.md 1.6）。Api::BaseController が、契約の形（{"error":{"code","details"}}）で返す。
# 未ログイン 401・CSRF 403・存在しない 404・不正な入力 422・頻度 429・想定外の例外 500。HTML のエラーページを返さない。
RSpec.describe "API のエラーの形", type: :request do
  include ApiHelpers
  include_context "API の環境"

  let(:user) { create(:user) }
  let(:signed_in) { sign_in(user) }

  # 契約: Content-Type は application/json; charset=utf-8、Cache-Control は no-store
  def expect_contract_headers
    expect(response.headers["Content-Type"]).to eq("application/json; charset=utf-8")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.body).not_to include("<")
  end

  describe "各ステータス" do
    it "401 not_logged_in" do
      api_post "/api/usage-events", { event_type: "watch_url_copied" }

      expect(response).to have_http_status(401)
      expect(json_body).to eq({ "error" => { "code" => "not_logged_in", "details" => {} } })
      expect_contract_headers
    end

    it "403 forbidden（X-BFF-Secret の不一致）" do
      get "/api/usage-events", env: public_listener_env

      expect(response).to have_http_status(403)
      expect(json_body).to eq({ "error" => { "code" => "forbidden", "details" => {} } })
      expect_contract_headers
    end

    it "403 csrf_invalid" do
      api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in, headers: { "X-BL-Client" => nil }

      expect(response).to have_http_status(403)
      expect(json_body).to eq({ "error" => { "code" => "csrf_invalid", "details" => {} } })
      expect_contract_headers
    end

    it "404 not_found（存在しない /api の経路。HTML の 404 ページにならない）" do
      api_get "/api/no-such-endpoint"

      expect(response).to have_http_status(404)
      expect(json_body).to eq({ "error" => { "code" => "not_found", "details" => {} } })
      expect_contract_headers
    end

    it "404 not_found（深い経路・拡張子つきの経路でも、JSON）" do
      [ "/api/a/b/c/d", "/api/state.json", "/api/%E3%81%82", "/api/broadcasts/00000000-0000-0000-0000-000000000000/unknown" ].each do |path|
        api_get path

        expect(response).to have_http_status(404), "#{path} が 404 ではない: #{response.status}"
        expect(error_code).to eq("not_found")
        expect_contract_headers
      end
    end

    it "422 invalid_input（details の fields に、不備のある項目名）" do
      api_post "/api/usage-events", { event_type: "line_measured", value: "x" }, signed_in: signed_in

      expect(response).to have_http_status(422)
      expect(json_body).to eq({ "error" => { "code" => "invalid_input", "details" => { "fields" => [ "value" ] } } })
      expect_contract_headers
    end

    it "422 unsupported_event" do
      api_post "/api/usage-events", { event_type: "login_started" }, signed_in: signed_in

      expect(response).to have_http_status(422)
      expect(json_body).to eq({ "error" => { "code" => "unsupported_event", "details" => {} } })
      expect_contract_headers
    end

    it "204 の応答にも、Cache-Control: no-store（すべての応答に付ける）" do
      api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in

      expect(response).to have_http_status(204)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  describe "コントローラの中で起きた例外の対応づけ" do
    let(:body) { { event_type: "watch_url_copied" } }

    it "存在しないレコード（ActiveRecord::RecordNotFound）は 404 not_found（他のアカウントのレコードも、存在しないものとして扱う）" do
      allow(UsageRecorder).to receive(:record).and_raise(ActiveRecord::RecordNotFound, "Couldn't find Broadcast with 'id'=dummy-secret-id")

      api_post "/api/usage-events", body, signed_in: signed_in

      expect(response).to have_http_status(404)
      expect(json_body).to eq({ "error" => { "code" => "not_found", "details" => {} } })
      expect(response.body).not_to include("dummy-secret-id")
      expect_contract_headers
    end

    it "必須の項目が無い（ActionController::ParameterMissing）は 422 invalid_input（fields に項目名）" do
      allow(UsageRecorder).to receive(:record).and_raise(ActionController::ParameterMissing.new(:event_type))

      api_post "/api/usage-events", body, signed_in: signed_in

      expect(response).to have_http_status(422)
      expect(json_body).to eq({ "error" => { "code" => "invalid_input", "details" => { "fields" => [ "event_type" ] } } })
    end

    it "頻度の上限（Api::Error::RateLimited）は 429 rate_limited（details の retry_at は、JST の ISO 8601）" do
      retry_at = Time.utc(2026, 10, 7, 4, 31, 0) # JST 13:31:00
      allow(UsageRecorder).to receive(:record).and_raise(Api::Error::RateLimited.new(retry_at: retry_at))

      api_post "/api/usage-events", body, signed_in: signed_in

      expect(response).to have_http_status(429)
      expect(json_body).to eq({ "error" => { "code" => "rate_limited", "details" => { "retry_at" => "2026-10-07T13:31:00+09:00" } } })
      expect_contract_headers
    end

    it "RateLimited の retry_at が、UTC の Time でも、ActiveSupport::TimeWithZone でも、JST（+09:00）で返す" do
      [ Time.utc(2026, 10, 7, 4, 31, 0), Time.utc(2026, 10, 7, 4, 31, 0).in_time_zone("UTC"), Time.new(2026, 10, 7, 13, 31, 0, "+09:00") ].each do |time|
        allow(UsageRecorder).to receive(:record).and_raise(Api::Error::RateLimited.new(retry_at: time))

        api_post "/api/usage-events", body, signed_in: signed_in

        expect(json_body.dig("error", "details", "retry_at")).to eq("2026-10-07T13:31:00+09:00")
      end
    end

    it "想定外の例外は 500 internal_error。詳細（例外の文面）を応答に出さない" do
      allow(UsageRecorder).to receive(:record).and_raise(RuntimeError, "dummy-internal-detail-must-not-appear (host=db.internal password=dummy-pass)")

      api_post "/api/usage-events", body, signed_in: signed_in

      expect(response).to have_http_status(500)
      expect(json_body).to eq({ "error" => { "code" => "internal_error", "details" => {} } })
      expect(response.body).not_to include("dummy-internal-detail")
      expect(response.body).not_to include("dummy-pass")
      expect_contract_headers
    end

    it "500 のログには、識別子（リクエスト ID）と原因（例外のクラスと発生の位置）を出し、例外の文面は出さない" do
      allow(UsageRecorder).to receive(:record).and_raise(ArgumentError, "dummy-internal-detail-must-not-appear")

      output = capture_logs { api_post "/api/usage-events", body, signed_in: signed_in }

      request_id = response.headers["X-Request-Id"]
      expect(request_id).to be_present
      line = output.lines.find { |entry| entry.include?("internal_error") }
      expect(line).to include(request_id)
      expect(line).to include("ArgumentError")
      expect(line).to match(%r{usage_events_controller\.rb:\d+})
      expect(output).not_to include("dummy-internal-detail-must-not-appear")
    end

    it "例外の原因（cause）がある場合も、原因のクラスだけをログへ出し、文面は出さない" do
      allow(UsageRecorder).to receive(:record) do
        begin
          raise IOError, "dummy-cause-detail-must-not-appear"
        rescue IOError
          raise "dummy-outer-detail-must-not-appear"
        end
      end

      output = capture_logs { api_post "/api/usage-events", body, signed_in: signed_in }

      expect(output).to include("IOError")
      expect(output).not_to include("dummy-cause-detail")
      expect(output).not_to include("dummy-outer-detail")
    end

    it "PostgreSQL の一意違反の例外の文面（キーの値を含む）を、応答にもログにも出さない" do
      allow(UsageRecorder).to receive(:record).and_raise(
        ActiveRecord::RecordNotUnique,
        'PG::UniqueViolation: ERROR: duplicate key value violates unique constraint "idx_users_google_sub" DETAIL: Key (google_sub)=(dummy-google-sub-secret) already exists.'
      )

      output = capture_logs { api_post "/api/usage-events", body, signed_in: signed_in }

      expect(response).to have_http_status(500)
      expect(response.body).not_to include("dummy-google-sub-secret")
      expect(output).not_to include("dummy-google-sub-secret")
      expect(output).to include("ActiveRecord::RecordNotUnique")
    end

    it "例外のあとも、次の要求は正常に処理される（状態が残らない）" do
      allow(UsageRecorder).to receive(:record).and_raise(RuntimeError, "boom")
      api_post "/api/usage-events", body, signed_in: signed_in
      expect(response).to have_http_status(500)

      allow(UsageRecorder).to receive(:record).and_call_original
      api_post "/api/usage-events", body, signed_in: signed_in

      expect(response).to have_http_status(204)
    end
  end

  describe "ログの完了の行（Completed）" do
    it "動作の中のエラーも、実際の状態で記録する（404 は Completed 404。500 と誤記録しない）" do
      output = capture_logs { api_get "/api/no-such-endpoint" }

      expect(output).to include("Completed 404 Not Found")
      expect(output).not_to include("Completed 500")
    end

    it "想定外の例外は、Completed 500" do
      allow(UsageRecorder).to receive(:record).and_raise(RuntimeError, "boom")

      output = capture_logs { api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in }

      expect(output).to include("Completed 500 Internal Server Error")
    end

    it "正常な応答は、Completed 204" do
      output = capture_logs { api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: signed_in }

      expect(output).to include("Completed 204 No Content")
    end

    it "動作に入る前に拒否した要求は、拒否の符号と理由（確認の種類）・リクエスト ID を、ログに残す（値は残さない）" do
      output = capture_logs { get "/api/no-such-endpoint", headers: { "X-BFF-Secret" => "dummy-wrong-secret-must-not-appear" }, env: public_listener_env }

      expect(output).to match(/\[api\] rejected code=forbidden status=403 reason=bff_secret_rejected request_id=\S+/)
      expect(output).not_to include("dummy-wrong-secret-must-not-appear")
    end
  end

  describe "HTML のエラーページを返さない" do
    it "どのエラーの応答も、JSON として読め、HTML のタグを含まない" do
      responses = []
      api_get "/api/no-such-endpoint"
      responses << response.body
      api_post "/api/usage-events", { event_type: "login_started" }, signed_in: signed_in
      responses << response.body
      get "/api/usage-events", env: public_listener_env
      responses << response.body
      api_post "/api/usage-events", raw_body: "{", signed_in: signed_in
      responses << response.body

      responses.each do |text|
        expect { JSON.parse(text) }.not_to raise_error
        expect(text).not_to match(/<(html|body|h1|!doctype)/i)
      end
    end

    it "Accept が text/html でも、JSON を返す" do
      api_get "/api/no-such-endpoint", headers: { "Accept" => "text/html" }

      expect(response).to have_http_status(404)
      expect(response.media_type).to eq("application/json")
    end

    it "不正な Accept ヘッダでも、JSON のエラーを返す（例外にならない）" do
      api_get "/api/no-such-endpoint", headers: { "Accept" => "application/json;q=" }

      expect(response).to have_http_status(404)
      expect(error_code).to eq("not_found")
    end

    # テストのクライアントは、URL を解釈するときに、壊れたパーセントエンコーディングを拒否する。実際の要求（Puma が受けるもの）を再現するため、
    # 経路・クエリ文字列を、Rack の env で直接指定する。
    it "パーセントエンコーディングが壊れた経路でも、JSON の 404（HTML の例外ページにならない）" do
      api_get "/api/x", env: public_listener_env.merge("PATH_INFO" => "/api/%ZZ")

      expect(response).to have_http_status(404)
      expect(error_code).to eq("not_found")
      expect_contract_headers
    end

    it "壊れたクエリ文字列（BFF の確認を通った要求）は、422 invalid_input の JSON（HTML の例外ページにならない）" do
      api_get "/api/no-such-endpoint", env: public_listener_env.merge("QUERY_STRING" => "a=%ZZ")

      expect(response).to have_http_status(422)
      expect(json_body).to eq({ "error" => { "code" => "invalid_input", "details" => {} } })
      expect_contract_headers
    end

    it "壊れたクエリ文字列でも、BFF の確認が先（確認を通らない要求は、403 forbidden）" do
      get "/api/no-such-endpoint", env: public_listener_env.merge("QUERY_STRING" => "a=%ZZ")

      expect(response).to have_http_status(403)
      expect(error_code).to eq("forbidden")
    end

    it "壊れた JSON の本文でも、確認・CSRF・ログインの確認が先（ログインしていなければ 401、X-BL-Client が無ければ 403）" do
      api_post "/api/usage-events", raw_body: "{broken"
      expect(response).to have_http_status(401)

      api_post "/api/usage-events", raw_body: "{broken", headers: { "X-BL-Client" => nil }
      expect(response).to have_http_status(403)
      expect(error_code).to eq("csrf_invalid")

      post "/api/usage-events", params: "{broken", headers: { "Content-Type" => "application/json" }, env: public_listener_env
      expect(response).to have_http_status(403)
      expect(error_code).to eq("forbidden")
    end
  end

  describe "ログインしていることの確認" do
    it "ログインが要る API は、セッションが無ければ 401（current_user が無い）" do
      api_post "/api/usage-events", { event_type: "watch_url_copied" }

      expect(response).to have_http_status(401)
    end

    it "セッションの Cookie が、でたらめでも 401（例外にならない）" do
      api_post "/api/usage-events", { event_type: "watch_url_copied" }, headers: { "Cookie" => "#{SessionCookie::NAME}=%00%ff;;==" }

      expect(response).to have_http_status(401)
    end

    it "セッションの Cookie が、とても長くても 401（DB を引かない）" do
      statements = capture_sql { api_post "/api/usage-events", { event_type: "watch_url_copied" }, headers: { "Cookie" => "#{SessionCookie::NAME}=#{'a' * 100_000}" } }

      expect(response).to have_http_status(401)
      expect(statements.grep(/FROM "sessions"/)).to be_empty
    end
  end
end
