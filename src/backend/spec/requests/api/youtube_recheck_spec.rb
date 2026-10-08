require "rails_helper"
require "support/api_helpers"
require "support/auth_flow_helpers"
require "support/youtube_connect_support"

# POST /api/youtube/recheck（src/contracts/http-api.md 3 章。issue #11。requirements.md 7.2・7.3・8.4・25.4・28.1）。
# ライブ配信が有効かの再確認。ログイン必須・CSRF。アカウント単位で 1 分に 1 回・1 日（直近 24 時間）20 回（超過は 429 rate_limited・retry_at）。
# 接続が無ければ 409 not_connected。認可失効（revoked）は、再確認せず 200 で revoked（再接続を促す）。接続済み・ライブ未有効のとき、
# チャンネルとライブの有効を再確認し（各 1 ユニットの一覧取得。共通枠から支出）、connected と live_not_enabled を更新して 200
# {"youtube":{"state","channel_title":null,"can_recheck_at"}}。確認不能（共通枠の枯渇・一時的な失敗・チャンネルが見つからない）は、状態を変えず 503 unverifiable。
# トークンの更新が恒久的に失敗した・権限が不足している場合は、認可失効にして 200。
RSpec.describe "POST /api/youtube/recheck", type: :request do
  include ApiHelpers
  include AuthFlowHelpers
  include LedgerSupport
  include YouTubeConnectSupport
  include ActiveSupport::Testing::TimeHelpers
  include_context "API の環境"
  include_context "YouTube 接続の環境"

  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) } # JST 2026-10-08 12:00:00
  let(:clock) { { now: now } }
  let!(:limiter) { fresh_rate_limiter(clock) }
  let(:user) { create(:user, google_sub: "dev-user-1") }
  let(:login) { sign_in(user, now: now) }

  before { travel_to(now) }
  after { travel_back }

  def recheck(session: login, headers: {}, body: nil)
    api_post "/api/youtube/recheck", body, signed_in: session, headers: headers
  end

  # 時刻を進める。頻度制限の計数の時計（clock）と、Rails の時刻（travel_to）の両方
  def move_to(time)
    clock[:now] = time
    travel_to(time)
  end

  # 実際に保存した接続（暗号化した更新トークン。アクセストークンを取得できる）
  def store_connection(account = user, state: "connected", at: now - 2.days)
    connection = YouTubeServices.current.token_vault.store(user_id: account.id, refresh_token: "1//dummy-refresh-token-#{SecureRandom.hex(4)}", now: at)
    connection.update!(state: state) unless state == "connected"
    connection.reload
  end

  def fake_youtube
    YouTubeServices.current.youtube_gateway
  end

  def youtube_body(state, can_recheck_at: "2026-10-08T12:01:00+09:00")
    { "youtube" => { "state" => state, "channel_title" => nil, "can_recheck_at" => can_recheck_at } }
  end

  def state_of(account = user)
    YoutubeConnection.owned_by(account).take&.state
  end

  describe "成功（200 {\"youtube\":{…}}）" do
    it "接続済み: 200。state・channel_title（常に null）・can_recheck_at（次に再確認できる時刻 = 1 分後。JST）だけを返す" do
      store_connection(state: "connected")

      recheck

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to start_with("application/json")
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(json_body).to eq(youtube_body("connected"))
      expect(json_body.fetch("youtube").keys).to eq(%w[ state channel_title can_recheck_at ])
    end

    it "channel_title は常に null（チャンネル名を取得しても、応答に含めない。GET /api/state?with_channel=1 だけが返す）" do
      store_connection(state: "connected")

      recheck

      expect(json_body.dig("youtube", "channel_title")).to be_nil
      expect(response.body).not_to include("Fake Channel")
    end

    it "ライブ未有効 -> 接続済み（再確認でライブ有効）。接続の状態と確認の時刻を更新する" do
      connection = store_connection(state: "live_not_enabled")

      recheck

      expect(json_body).to eq(youtube_body("connected"))
      expect(connection.reload).to have_attributes(state: "connected", last_verified_at: now)
    end

    it "接続済み -> ライブ未有効（再確認でライブ未有効・制限中）" do
      connection = store_connection(state: "connected")
      fake_youtube.fail_next(:live_not_enabled, on: :probe_live_enabled)

      recheck

      expect(json_body).to eq(youtube_body("live_not_enabled"))
      expect(connection.reload).to have_attributes(state: "live_not_enabled", last_verified_at: now)
    end

    it "ライブ未有効のまま" do
      store_connection(state: "live_not_enabled")
      fake_youtube.fail_next(:live_not_enabled, on: :probe_live_enabled)

      recheck

      expect(json_body).to eq(youtube_body("live_not_enabled"))
    end

    it "共通枠から 2 ユニット（チャンネルの一覧取得 1 + 配信の一覧取得 1）。配信の予約は取り崩さない" do
      store_connection(state: "connected")

      recheck

      expect(QuotaEntry.where(bucket: "common").map { |entry| [ entry.method, entry.units ] }).to contain_exactly([ "channels.list", 1 ], [ "liveBroadcasts.list", 1 ])
      expect(QuotaEntry.where(bucket: %w[ prep settle ])).to be_empty
    end

    it "本文は無視する（本文なしの API。未知のキーが付いても通る）" do
      store_connection(state: "connected")

      recheck(body: { junk: 1 })

      expect(response).to have_http_status(:ok)
    end

    it "bot 判定（reCAPTCHA）は要らない" do
      verifier = instance_double(FakeRecaptchaVerifier)
      allow(verifier).to receive(:verify)
      use_gateways(google_oidc: FakeGoogleOidc.new(secret: Rails.application.secret_key_base), recaptcha_verifier: verifier)
      store_connection(state: "connected")

      recheck

      expect(response).to have_http_status(:ok)
      expect(verifier).not_to have_received(:verify)
    end

    it "測定イベントは記録しない（契約に、再確認の測定イベントは無い）" do
      store_connection(state: "connected")

      expect { recheck }.not_to change(UsageEvent, :count)
    end

    it "他のアカウントの接続を変えない（2 アカウント）" do
      store_connection(state: "live_not_enabled")
      other = create(:user)
      other_connection = store_connection(other, state: "live_not_enabled")

      recheck

      expect(state_of).to eq("connected")
      expect(other_connection.reload).to have_attributes(state: "live_not_enabled", last_verified_at: now - 2.days)
    end
  end

  describe "接続が無い・認可失効" do
    it "接続が無い: 409 not_connected（details は空）。YouTube を呼ばない・台帳に記帳しない" do
      recheck

      expect(response).to have_http_status(409)
      expect(json_body).to eq({ "error" => { "code" => "not_connected", "details" => {} } })
      expect(QuotaEntry.count).to eq(0)
    end

    it "他のアカウントの接続だけがある: 409 not_connected" do
      store_connection(create(:user), state: "connected")

      recheck

      expect(response).to have_http_status(409)
      expect(error_code).to eq("not_connected")
    end

    it "認可失効（revoked）: 再確認せず、200 で state が revoked（再接続を促す）。YouTube を呼ばない・状態を変えない" do
      connection = store_connection(state: "revoked")

      recheck

      expect(response).to have_http_status(:ok)
      expect(json_body).to eq(youtube_body("revoked"))
      expect(QuotaEntry.count).to eq(0)
      expect(connection.reload).to have_attributes(state: "revoked", last_verified_at: now - 2.days)
    end
  end

  describe "認可失効にする（接続済み・ライブ未有効 -> 認可失効）" do
    %w[ connected live_not_enabled ].each do |from|
      it "#{from}: トークンの更新が恒久的に失敗（取り消し）: 200 で state が revoked。接続の状態を認可失効にする" do
        store_connection(state: from)
        fake_youtube.fail_next(:token_revoked)

        recheck

        expect(response).to have_http_status(:ok)
        expect(json_body).to eq(youtube_body("revoked"))
        expect(state_of).to eq("revoked")
      end

      it "#{from}: 権限が不足している（insufficientPermissions）: 200 で state が revoked" do
        store_connection(state: from)
        fake_youtube.fail_next(:insufficient_permissions, on: :probe_channel_lookup)

        recheck

        expect(json_body).to eq(youtube_body("revoked"))
        expect(state_of).to eq("revoked")
      end
    end
  end

  describe "確認不能: 503 unverifiable（接続状態は変更しない）" do
    {
      "一時的な失敗" => ->(youtube) { youtube.fail_next(:transient) },
      "タイムアウト" => ->(youtube) { youtube.fail_next(:timeout) },
      "ライブ配信の確認の一時的な失敗" => ->(youtube) { youtube.fail_next(:transient, on: :probe_live_enabled) },
      "割り当て超過（YouTube）" => ->(youtube) { youtube.fail_next(:quota_exceeded) },
      "チャンネルが見つからない" => ->(youtube) { youtube.fail_next(:no_channel) },
      "アクセストークンの更新の一時的な失敗" => ->(youtube) { youtube.fail_next(:token_temporarily_unavailable) }
    }.each do |label, arrange|
      %w[ connected live_not_enabled ].each do |from|
        it "#{label}（#{from}）: 503 unverifiable。状態も確認の時刻も、変えない" do
          connection = store_connection(state: from)
          arrange.call(fake_youtube)

          recheck

          expect(response).to have_http_status(503)
          expect(json_body).to eq({ "error" => { "code" => "unverifiable", "details" => {} } })
          expect(connection.reload).to have_attributes(state: from, last_verified_at: now - 2.days)
        end
      end
    end

    it "共通枠の枯渇: 503 unverifiable（窓口が YouTube を呼ばない）。状態を変えない" do
      connection = store_connection(state: "connected")
      seed_day(UsageCalendar.quota_date(now), common: QuotaPolicy::COMMON_UNITS)

      recheck

      expect(response).to have_http_status(503)
      expect(error_code).to eq("unverifiable")
      expect(connection.reload.state).to eq("connected")
    end

    it "503 の応答に、YouTube の応答・トークン・チャンネル名を含めない" do
      store_connection(state: "connected")
      fake_youtube.fail_next(:transient)

      recheck

      expect(response.body).not_to include("fake error")
      expect(response.body).not_to include("Fake Channel")
    end
  end

  describe "頻度制限（アカウント単位で 1 分に 1 回・1 日 20 回）" do
    it "1 分に 2 回目: 429 rate_limited（details の retry_at は、枠が空く時刻 = 最初の再確認の 1 分後。JST）。YouTube を呼ばない" do
      store_connection(state: "connected")
      recheck
      expect(response).to have_http_status(:ok)
      entries = QuotaEntry.count

      move_to(now + 30)
      recheck

      expect(response).to have_http_status(429)
      expect(json_body).to eq({ "error" => { "code" => "rate_limited", "details" => { "retry_at" => "2026-10-08T12:01:00+09:00" } } })
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(QuotaEntry.count).to eq(entries)
    end

    it "1 分後（60 秒ちょうど）には、また通る。59 秒後はまだ" do
      store_connection(state: "connected")
      recheck

      move_to(now + 59)
      recheck
      expect(response).to have_http_status(429)

      move_to(now + 60)
      recheck
      expect(response).to have_http_status(:ok)
    end

    it "1 日（直近 24 時間）に 20 回まで: 21 回目は 429（retry_at は、最初の再確認の 24 時間後）" do
      store_connection(state: "connected")
      20.times do |index|
        move_to(now + (61 * index))
        recheck
        expect(response).to have_http_status(:ok), "#{index + 1} 回目が通らない: #{response.status}"
      end

      move_to(now + (61 * 20))
      recheck

      expect(response).to have_http_status(429)
      expect(json_body.dig("error", "details", "retry_at")).to eq("2026-10-09T12:00:00+09:00")
    end

    it "24 時間がたてば、また通る" do
      store_connection(state: "connected")
      20.times do |index|
        move_to(now + (61 * index))
        recheck
      end

      move_to(now + 86_400)
      recheck

      expect(response).to have_http_status(:ok)
    end

    it "アカウントごとの計数（別のアカウントの再確認は、数えない。同じ IP でも別）" do
      store_connection(state: "connected")
      other = create(:user)
      store_connection(other, state: "connected")
      recheck

      recheck(session: sign_in(other, now: now))

      expect(response).to have_http_status(:ok)
    end

    it "IP ごとではなく、アカウントごと: 別の IP から同じアカウントで送っても、数える" do
      store_connection(state: "connected")
      recheck

      recheck(headers: { "X-Forwarded-For" => "203.0.113.99" })

      expect(response).to have_http_status(429)
    end

    it "接続が無くて 409 になった要求も数える（頻度制限が先。再確認の連打を、接続の有無によらず抑える）" do
      recheck
      expect(response).to have_http_status(409)

      recheck
      expect(response).to have_http_status(429)
    end

    it "認可失効の 200 も数える" do
      store_connection(state: "revoked")
      recheck
      expect(response).to have_http_status(:ok)

      recheck
      expect(response).to have_http_status(429)
    end

    it "確認不能（503）も数える（失敗しても YouTube を呼んだ。連打で共通枠を使い切らない）" do
      store_connection(state: "connected")
      fake_youtube.fail_next(:transient)
      recheck
      expect(response).to have_http_status(503)

      recheck
      expect(response).to have_http_status(429)
    end

    it "429 の応答は、IP アドレスを含まない" do
      store_connection(state: "connected")
      recheck
      recheck

      expect(response.body).not_to include(ApiHelpers::CLIENT_IP)
    end
  end

  describe "can_recheck_at（次に再確認できる時刻）" do
    it "成功の直後は、1 分後（JST の ISO 8601）" do
      store_connection(state: "connected")

      recheck

      expect(json_body.dig("youtube", "can_recheck_at")).to eq("2026-10-08T12:01:00+09:00")
    end

    it "秒の端数は、切り上げて返す（クライアントが、早く再有効にしない）" do
      store_connection(state: "connected")
      move_to(now + 0.4)

      recheck

      expect(json_body.dig("youtube", "can_recheck_at")).to eq("2026-10-08T12:01:01+09:00")
    end

    it "再確認で共通枠を使い切ったときは、割り当て日の終わり（次の太平洋時間の 0 時 = JST 16:00）。1 分後より遅い" do
      store_connection(state: "connected")
      seed_day(UsageCalendar.quota_date(now), common: QuotaPolicy::COMMON_UNITS - 2)

      recheck

      expect(response).to have_http_status(:ok)
      expect(json_body.dig("youtube", "can_recheck_at")).to eq("2026-10-08T16:00:00+09:00")
    end

    it "共通枠が尽きた日は、割り当て日の終わりまで、再確認は 503（尽きた日の中。頻度制限の 1 分が過ぎても）" do
      connection = store_connection(state: "connected")
      seed_day(UsageCalendar.quota_date(now), common: QuotaPolicy::COMMON_UNITS - 2)
      recheck

      move_to(now + 120)
      recheck

      expect(response).to have_http_status(503)
      expect(connection.reload.state).to eq("connected")
    end

    it "割り当て日をまたげば（太平洋時間の 0 時）、新しい共通枠で、また再確認できる" do
      store_connection(state: "connected")
      seed_day(UsageCalendar.quota_date(now), common: QuotaPolicy::COMMON_UNITS - 2)
      recheck

      move_to(UsageCalendar.next_quota_date_start(now))
      recheck

      expect(response).to have_http_status(:ok)
      expect(json_body.dig("youtube", "can_recheck_at")).to eq("2026-10-08T16:01:00+09:00")
    end

    it "認可失効の応答にも、can_recheck_at を持つ（今の要求の分を数えた、次の時刻）" do
      store_connection(state: "revoked")

      recheck

      expect(json_body).to eq(youtube_body("revoked"))
    end
  end

  describe "認可と CSRF（共通の規約）" do
    it "ログインしていない: 401 not_logged_in。YouTube を呼ばない" do
      recheck(session: nil)

      expect(response).to have_http_status(401)
      expect(json_body).to eq({ "error" => { "code" => "not_logged_in", "details" => {} } })
      expect(QuotaEntry.count).to eq(0)
    end

    it "X-BL-Client が無い・X-CSRF-Token が違う: 403 csrf_invalid" do
      store_connection(state: "connected")

      recheck(headers: { "X-BL-Client" => nil })
      expect(response).to have_http_status(403)
      expect(error_code).to eq("csrf_invalid")

      recheck(headers: { "X-CSRF-Token" => "dummy-wrong-token" })
      expect(response).to have_http_status(403)
    end

    it "X-BFF-Secret が無い: 403 forbidden" do
      recheck(headers: { "X-BFF-Secret" => nil })

      expect(response).to have_http_status(403)
      expect(error_code).to eq("forbidden")
    end

    it "拒否された要求（401・403）は、頻度制限に数えない" do
      store_connection(state: "connected")
      recheck(session: nil)
      recheck(headers: { "X-CSRF-Token" => "dummy-wrong-token" })

      recheck

      expect(response).to have_http_status(:ok)
    end

    it "GET では呼べない（経路は POST だけ）" do
      api_get "/api/youtube/recheck", signed_in: login

      expect(response).to have_http_status(404)
    end

    it "ログインの方針は、ログインが要る（Api::YoutubeController#recheck）" do
      expect(Api::YoutubeController.login_policy_for("recheck")).to eq(:login)
    end
  end

  describe "機密（ログ・DB・応答）" do
    it "ログに、トークン・チャンネル名・YouTube の応答の本文を出さない。結果と内部のアカウント識別子だけ" do
      store_connection(state: "live_not_enabled")
      access = YouTubeServices.current.token_vault.access_token(user_id: user.id, now: now)

      output = capture_logs { recheck }

      expect(output).to include("[youtube_connect] rechecked user_id=#{user.id} state=connected")
      expect(output).not_to include(access)
      expect(output).not_to include("Fake Channel")
      expect(output).not_to include(ApiHelpers::CLIENT_IP)
    end

    it "DB のどの表にも、アクセストークン・チャンネル名が無い" do
      store_connection(state: "connected")

      recheck

      expect(database_dump).not_to include("Fake Channel")
      expect(database_dump).not_to include("fake-access-token-")
    end

    it "想定外の例外（実装の誤り）は、500 internal_error。応答に詳細を出さない" do
      store_connection(state: "connected")
      allow_any_instance_of(FakeYouTubeGateway).to receive(:probe_channel).and_raise(RuntimeError, "boom dummy-secret-detail")

      output = capture_logs { recheck }

      expect(response).to have_http_status(500)
      expect(json_body).to eq({ "error" => { "code" => "internal_error", "details" => {} } })
      expect(output).not_to include("dummy-secret-detail")
    end
  end
end
