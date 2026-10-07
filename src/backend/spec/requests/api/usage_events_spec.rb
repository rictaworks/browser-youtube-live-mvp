require "rails_helper"
require "support/api_helpers"
require "support/log_capture"

# POST /api/usage-events（src/contracts/http-api.md 3 章。requirements.md 18.2・28.2）。
# ログイン済みのブラウザが、測定イベントを送る。ベストエフォート。204 を返す。
RSpec.describe "POST /api/usage-events", type: :request do
  include ApiHelpers
  include_context "API の環境"

  let(:user) { create(:user) }
  let(:signed_in) { sign_in(user) }
  let(:path) { "/api/usage-events" }
  let(:sendable) { %w[ capability_detected source_granted source_denied line_measured watch_url_copied ] }

  describe "受理（204）" do
    it "契約の例（回線計測）: 204 を返し、測定イベントを 1 件記録する" do
      expect do
        api_post path, { event_type: "line_measured", value: 5200, browser_class: { family: "chromium", supported: true } }, signed_in: signed_in
      end.to change(UsageEvent, :count).by(1)

      expect(response).to have_http_status(:no_content)
      expect(response.body).to be_empty
      expect(UsageEvent.last).to have_attributes(
        user_id: user.id, event_type: "line_measured", bucket: "throughput_kbps:5000-5999",
        browser_class: "chromium:supported", reason_code: nil
      )
    end

    it "数値（value）は、区分に変換して記録する。数値のまま保存しない" do
      api_post path, { event_type: "line_measured", value: 5234 }, signed_in: signed_in

      row = UsageEvent.last
      expect(row.attributes.values.map(&:to_s)).not_to include("5234")
      expect(row.bucket).to eq("throughput_kbps:5000-5999")
    end

    it "符号（reason_code）を記録する" do
      api_post path, { event_type: "source_denied", reason_code: "not_allowed" }, signed_in: signed_in

      expect(response).to have_http_status(:no_content)
      expect(UsageEvent.last).to have_attributes(event_type: "source_denied", reason_code: "not_allowed")
    end

    %w[ capability_detected source_granted source_denied line_measured watch_url_copied ].each do |type|
      it "#{type} は受理される（種別だけ）" do
        api_post path, { event_type: type }, signed_in: signed_in

        expect(response).to have_http_status(:no_content)
        expect(UsageEvent.last.event_type).to eq(type)
      end
    end

    it "ブラウザの分類は、系統と対応可否だけを記録する（対応していない環境も）" do
      api_post path, { event_type: "capability_detected", browser_class: { family: "firefox", supported: false } }, signed_in: signed_in

      expect(UsageEvent.last.browser_class).to eq("firefox:unsupported")
    end

    it "記録するアカウントは、セッションのアカウントだけ（本文で、別のアカウントを指定できない）" do
      other = create(:user)

      api_post path, { event_type: "watch_url_copied", user_id: other.id, account_id: other.id }, signed_in: signed_in

      expect(UsageEvent.last.user_id).to eq(user.id)
      expect(UsageEvent.where(user_id: other.id)).to be_empty
    end

    it "発生の時刻を記録する（サーバーの時計）" do
      api_post path, { event_type: "watch_url_copied" }, signed_in: signed_in

      expect(UsageEvent.last.occurred_at).to be_within(10.seconds).of(Time.current)
    end

    it "応答は、本文なし・Cache-Control: no-store・Set-Cookie なし（Rails 標準のセッションの Cookie を出さない）" do
      api_post path, { event_type: "watch_url_copied" }, signed_in: signed_in

      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["Set-Cookie"]).to be_nil
    end

    it "ログの Parameters の行に、本文の複製（コントローラ名のキー usage_event）が無い（wrap_parameters を使わない）" do
      output = capture_logs { api_post path, { event_type: "watch_url_copied" }, signed_in: signed_in }

      expect(output).to include("Parameters:")
      expect(output).not_to include('"usage_event" =>')
    end

    it "冪等ではない（1 回の要求が 1 件のイベント）" do
      2.times { api_post path, { event_type: "watch_url_copied" }, signed_in: signed_in }

      expect(UsageEvent.where(user_id: user.id).count).to eq(2)
    end
  end

  describe "ブラウザから送れない種別（422 unsupported_event）" do
    (Contract::UsageEventType::ALL - %w[ capability_detected source_granted source_denied line_measured watch_url_copied ]).each do |type|
      it "#{type} は 422 unsupported_event（サーバーが記録する種別）。記録しない" do
        expect { api_post path, { event_type: type }, signed_in: signed_in }.not_to change(UsageEvent, :count)

        expect(response).to have_http_status(422)
        expect(json_body).to eq({ "error" => { "code" => "unsupported_event", "details" => {} } })
      end
    end

    it "未知の種別も 422 unsupported_event" do
      api_post path, { event_type: "dummy_unknown_type" }, signed_in: signed_in

      expect(response).to have_http_status(422)
      expect(error_code).to eq("unsupported_event")
      expect(response.body).not_to include("dummy_unknown_type")
    end
  end

  describe "不正な入力（422 invalid_input）" do
    {
      "種別が無い" => [ {}, [ "event_type" ] ],
      "種別が数値" => [ { event_type: 1 }, [ "event_type" ] ],
      "符号が不正（大文字・空白）" => [ { event_type: "source_denied", reason_code: "Not Allowed" }, [ "reason_code" ] ],
      "符号が長すぎる" => [ { event_type: "source_denied", reason_code: "a" * 33 }, [ "reason_code" ] ],
      "値が文字列" => [ { event_type: "line_measured", value: "5200" }, [ "value" ] ],
      "値が負" => [ { event_type: "line_measured", value: -1 }, [ "value" ] ],
      "値が小数" => [ { event_type: "line_measured", value: 1.5 }, [ "value" ] ],
      "値を持たない種別に値" => [ { event_type: "watch_url_copied", value: 1 }, [ "value" ] ],
      "ブラウザの分類が文字列（ユーザーエージェントの文字列）" => [ { event_type: "capability_detected", browser_class: "Mozilla/5.0 (X11; Linux x86_64)" }, [ "browser_class" ] ],
      "ブラウザの分類の系統が未知" => [ { event_type: "capability_detected", browser_class: { family: "chrome", supported: true } }, [ "browser_class" ] ],
      "ブラウザの分類の対応可否が真偽値でない" => [ { event_type: "capability_detected", browser_class: { family: "chromium", supported: "yes" } }, [ "browser_class" ] ],
      "複数の不備" => [ { event_type: "line_measured", reason_code: "A B", value: "x" }, [ "reason_code", "value" ] ]
    }.each do |label, (body, fields)|
      it "#{label}: 422 invalid_input（fields: #{fields.join('・')}）。記録しない" do
        expect { api_post path, body, signed_in: signed_in }.not_to change(UsageEvent, :count)

        expect(response).to have_http_status(422)
        expect(json_body).to eq({ "error" => { "code" => "invalid_input", "details" => { "fields" => fields } } })
      end
    end

    it "本文が JSON として壊れている: 422 invalid_input（HTML のエラーページにならない）" do
      api_post path, raw_body: "{broken json", signed_in: signed_in

      expect(response).to have_http_status(422)
      expect(error_code).to eq("invalid_input")
      expect(response.media_type).to eq("application/json")
      expect(response.body).not_to include("<html")
    end

    it "本文が空: 422 invalid_input（種別が無い）" do
      api_post path, signed_in: signed_in

      expect(response).to have_http_status(422)
      expect(json_body.dig("error", "details", "fields")).to eq([ "event_type" ])
    end

    it "本文が JSON の配列: 422 invalid_input" do
      api_post path, raw_body: "[1,2,3]", signed_in: signed_in

      expect(response).to have_http_status(422)
      expect(error_code).to eq("invalid_input")
    end

    it "エラーの応答に、送った値を含めない" do
      api_post path, { event_type: "source_denied", reason_code: "Dummy Value Must Not Appear" }, signed_in: signed_in

      expect(response.body).not_to include("Dummy Value Must Not Appear")
    end
  end

  describe "個人情報を含めない（18.2・28.2）" do
    it "余分な属性（氏名・メールアドレス・IP・ユーザーエージェント・タイトル）は、無視し、保存しない" do
      api_post path, {
        event_type: "capability_detected", email: "dummy@example.test", name: "Dummy Name", ip: "203.0.113.99",
        user_agent: "Mozilla/5.0 (X11; Linux x86_64)", title: "Dummy Title", channel_title: "Dummy Channel",
        browser_class: { family: "chromium", supported: true, user_agent: "Mozilla/5.0", device: "Dummy Device" }
      }, signed_in: signed_in

      expect(response).to have_http_status(:no_content)
      values = UsageEvent.last.attributes.values.map(&:to_s).join(" ")
      expect(values).not_to match(/dummy@example|Dummy|203\.0\.113|Mozilla/)
      expect(UsageEvent.last.browser_class).to eq("chromium:supported")
    end

    it "BFF が付けた利用者の IP（X-Forwarded-For）は、測定イベントへ記録しない" do
      api_post path, { event_type: "watch_url_copied" }, signed_in: signed_in

      expect(UsageEvent.last.attributes.values.map(&:to_s).join(" ")).not_to include(ApiHelpers::CLIENT_IP)
      expect(UsageEvent.connection.select_values("SELECT row_to_json(u)::text FROM usage_events u").join).not_to include(ApiHelpers::CLIENT_IP)
    end
  end

  describe "認可（評価の順: BFF → X-BL-Client → CSRF・Origin → ログイン）" do
    let(:body) { { event_type: "watch_url_copied" } }

    it "ログインしていない: 401 not_logged_in。記録しない" do
      expect { api_post path, body }.not_to change(UsageEvent, :count)

      expect(response).to have_http_status(:unauthorized)
      expect(json_body).to eq({ "error" => { "code" => "not_logged_in", "details" => {} } })
    end

    it "期限切れのセッションは、ログインしていないのと同じ: 401" do
      expired = sign_in(user, now: 31.days.ago)

      expect { api_post path, body, signed_in: expired }.not_to change(UsageEvent, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "破棄されたセッションは、401" do
      SessionStore.new.revoke(signed_in.session)

      api_post path, body, signed_in: signed_in

      expect(response).to have_http_status(:unauthorized)
    end

    it "X-CSRF-Token が無い: 403 csrf_invalid。記録しない" do
      expect { api_post path, body, signed_in: signed_in, headers: { "X-CSRF-Token" => nil } }.not_to change(UsageEvent, :count)

      expect(response).to have_http_status(:forbidden)
      expect(error_code).to eq("csrf_invalid")
    end

    it "X-CSRF-Token が違う: 403 csrf_invalid" do
      api_post path, body, signed_in: signed_in, headers: { "X-CSRF-Token" => "0" * 64 }

      expect(response).to have_http_status(:forbidden)
      expect(error_code).to eq("csrf_invalid")
    end

    it "別のセッションの X-CSRF-Token: 403 csrf_invalid" do
      other = sign_in(create(:user))

      api_post path, body, signed_in: signed_in, headers: { "X-CSRF-Token" => other.csrf_token }

      expect(response).to have_http_status(:forbidden)
    end

    it "X-BL-Client が無い: 403 csrf_invalid" do
      api_post path, body, signed_in: signed_in, headers: { "X-BL-Client" => nil }

      expect(response).to have_http_status(:forbidden)
      expect(error_code).to eq("csrf_invalid")
    end

    it "Origin が公開オリジンと違う: 403 csrf_invalid" do
      api_post path, body, signed_in: signed_in, headers: { "Origin" => "https://evil.example" }

      expect(response).to have_http_status(:forbidden)
      expect(error_code).to eq("csrf_invalid")
    end

    it "X-BFF-Secret が無い: 403 forbidden（ほかの検査より先）" do
      api_post path, body, signed_in: signed_in, headers: { "X-BFF-Secret" => nil }

      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq({ "error" => { "code" => "forbidden", "details" => {} } })
    end
  end

  describe "GET は受け付けない" do
    it "GET /api/usage-events（BFF の確認を通る）: 404 not_found（経路は POST だけ）" do
      api_get path, signed_in: signed_in

      expect(response).to have_http_status(:not_found)
      expect(error_code).to eq("not_found")
    end

    it "GET /api/usage-events（認証なし）: 403 forbidden（ブラウザで開くと、JSON のエラー）" do
      get path, env: public_listener_env

      expect(response).to have_http_status(:forbidden)
      expect(error_code).to eq("forbidden")
    end
  end

  describe "障害" do
    it "記録に失敗しても（DB の例外）、500 internal_error。例外の文面を応答・ログへ出さない" do
      allow(UsageRecorder).to receive(:record).and_raise(ActiveRecord::StatementInvalid, "PG::Error dummy-secret-detail-must-not-appear")

      output = capture_logs { api_post path, { event_type: "watch_url_copied" }, signed_in: signed_in }

      expect(response).to have_http_status(:internal_server_error)
      expect(json_body).to eq({ "error" => { "code" => "internal_error", "details" => {} } })
      expect(response.body).not_to include("dummy-secret-detail")
      expect(output).not_to include("dummy-secret-detail")
      expect(output).to include("ActiveRecord::StatementInvalid")
    end
  end
end
