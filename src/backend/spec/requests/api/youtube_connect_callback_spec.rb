require "rails_helper"
require "support/api_helpers"
require "support/auth_flow_helpers"
require "support/youtube_connect_support"

# GET /api/youtube/connect/callback（src/contracts/http-api.md 3 章。issue #11。requirements.md 7.2・7.3・10.5・23.1・25.4・28.1）。
# Google からの戻り先。bl_oauth（用途 connect）の state を照合し、ログイン中のセッションのアカウントと bl_oauth のアカウントが一致することを確認し、
# コードをトークンへ交換して、接続時の確認（チャンネルの有無・ライブ配信が有効か）をする。結果は 302 /account?connect=<connect_result>（公開オリジンの絶対 URL）。
#   成立（connected・live_not_enabled）: 更新トークンを暗号化して保存・接続の行を作成または更新・保存済みの配信用ストリームの識別子を破棄。測定イベント connect_completed
#   不成立（scope_denied・no_refresh_token・no_channel・unverifiable）: トークンを保存せず破棄（既存の接続が無いときに限り Google 側でも失効）。
#   既存の接続は変更しない。測定イベント connect_failed（理由の符号だけ）
# bl_oauth は、成功・失敗のどちらでも失効させる。流れは、本番と同じ経路（開始 -> 疑似の同意画面 -> 選択 -> コールバック）を通す。
RSpec.describe "GET /api/youtube/connect/callback", type: :request do
  include ApiHelpers
  include AuthFlowHelpers
  include YouTubeConnectSupport
  include ActiveSupport::Testing::TimeHelpers
  include_context "API の環境"
  include_context "YouTube 接続の環境"

  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:clock) { { now: now } }
  let!(:limiter) { fresh_rate_limiter(clock) }
  let(:origin) { ApiHelpers::PUBLIC_ORIGIN }
  let(:user) { create(:user, google_sub: "dev-user-1") }
  let(:login) { sign_in(user, now: now) }
  # 疑似の Google は 1 つのインスタンスにそろえる（失効の呼び出しを数える）
  let(:oidc) { FakeGoogleOidc.new(secret: Rails.application.secret_key_base) }

  before do
    travel_to(now)
    use_gateways(google_oidc: oidc, recaptcha_verifier: FakeRecaptchaVerifier.new)
    allow(oidc).to receive(:revoke).and_call_original
  end

  after { travel_back }

  # 開始 -> 疑似の同意画面 -> 選択。コールバックの要求に要る部品（bl_oauth の値・コード・state・error）を返す
  def begin_browser_flow(session = login, scenario: "allow")
    api_post "/api/youtube/connect/start", { recaptcha_token: "dev-pass" }, signed_in: session
    expect(response).to have_http_status(:ok)
    oauth_cookie = cookie_value(OAuthStateCookie::NAME)
    authorization_url = json_body.fetch("authorization_url")

    api_get authorize_path_of(authorization_url), headers: no_cookies
    expect(response).to have_http_status(:ok)
    api_get account_links.fetch(scenario), headers: no_cookies
    expect(response).to have_http_status(:found)

    query = Rack::Utils.parse_query(URI.parse(response.headers["Location"]).query)
    { code: query["code"], state: query.fetch("state"), error: query["error"], oauth_cookie: oauth_cookie, authorization_url: authorization_url }
  end

  # コールバックの要求。引数の既定は、流れの値。差し替えて、異常を作る
  def connect_callback(flow, session: login, code: flow[:code], state: flow[:state], error: flow[:error], oauth_cookie: flow[:oauth_cookie], headers: {})
    query = { code: code, state: state, error: error }.compact
    path = query.empty? ? "/api/youtube/connect/callback" : "/api/youtube/connect/callback?#{URI.encode_www_form(query)}"
    api_get path, headers: { "Cookie" => cookie_header_of(oauth_cookie, session&.token) }.merge(headers)
  end

  def expect_connect_redirect(result)
    expect(response).to have_http_status(:found)
    expect(response.headers["Location"]).to eq("#{origin}/account?connect=#{result}")
    expect(expired_cookie?(OAuthStateCookie::NAME)).to be(true)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.body).to be_empty
  end

  def connection_of(account = user)
    YoutubeConnection.owned_by(account).take
  end

  def snapshot(connection)
    connection.reload.slice(:state, :refresh_token_ciphertext, :youtube_stream_id, :stream_verified_at, :connected_at, :last_verified_at)
  end

  describe "成立（疑似の Google・疑似の YouTube の全体の流れ）" do
    it "allow: 302 /account?connect=connected（公開オリジンの絶対 URL）。bl_oauth を失効させる。セッションを作り直さない" do
      flow = begin_browser_flow

      connect_callback(flow)

      expect_connect_redirect("connected")
      expect(cookie_line(SessionCookie::NAME)).to be_nil
      expect(Session.count).to eq(1)
    end

    it "接続の行を作る: 状態 connected・接続の時刻・確認の時刻は現在。更新トークンは暗号化。配信用ストリームの識別子は無い" do
      connect_callback(begin_browser_flow)

      connection = connection_of
      expect(connection).to have_attributes(state: "connected", connected_at: now, last_verified_at: now, youtube_stream_id: nil, stream_verified_at: nil)
      expect(connection.refresh_token_ciphertext).to be_present
      expect(YoutubeConnection.count).to eq(1)
    end

    it "測定イベント connect_completed を、内部のアカウント識別子に紐づけて記録する（結果の符号だけ。IP・sub・チャンネル名を含めない）" do
      flow = begin_browser_flow

      expect { connect_callback(flow) }.to change { UsageEvent.where(event_type: "connect_completed").count }.by(1)

      event = UsageEvent.where(event_type: "connect_completed").sole
      expect(event.user_id).to eq(user.id)
      expect(event.occurred_at).to eq(now)
      expect(event.reason_code).to eq("connected")
      expect(event.attributes.slice("bucket", "browser_class").values.compact).to be_empty
      joined = event.attributes.values.map(&:to_s).join(" ")
      [ ApiHelpers::CLIENT_IP, "dev-user-1", "Fake Channel" ].each { |secret| expect(joined).not_to include(secret) }
      expect(UsageEvent.where(event_type: "connect_failed")).to be_empty
    end

    it "allow_live_not_enabled: 302 /account?connect=live_not_enabled。接続は成立（状態 live_not_enabled）。測定イベントの符号は live_not_enabled" do
      connect_callback(begin_browser_flow(scenario: "allow_live_not_enabled"))

      expect_connect_redirect("live_not_enabled")
      expect(connection_of).to have_attributes(state: "live_not_enabled", connected_at: now, last_verified_at: now)
      expect(UsageEvent.where(event_type: "connect_completed").sole.reason_code).to eq("live_not_enabled")
    end

    it "成立のとき、Google 側でトークンを失効させない" do
      connect_callback(begin_browser_flow)

      expect(oidc).not_to have_received(:revoke)
    end

    it "YouTube の応答のチャンネル名が空白だけでも、接続は成立する（302 connected。保存したあとに 500 にしない）。チャンネル名は置かない" do
      # YouTubeServices.current は、要求ごとに窓口を組み立てる（疑似の YouTube の状態だけが共有される）。どの窓口でも、チャンネル名が空白だけの応答にする
      allow_any_instance_of(FakeYouTubeGateway).to receive(:probe_channel)
        .and_return(ProbeResult.new(outcome: "connected", channel_title: "   "))

      connect_callback(begin_browser_flow)

      expect_connect_redirect("connected")
      expect(connection_of).to have_attributes(state: "connected")
      expect(UsageEvent.where(event_type: "connect_completed").sole.reason_code).to eq("connected")
      expect(ChannelNameCache.shared.cached(user.id)).to be_nil
    end

    it "確認は共通枠から 2 ユニット（配信の予約は取り崩さない）" do
      connect_callback(begin_browser_flow)

      expect(QuotaEntry.where(bucket: "common").map { |entry| [ entry.method, entry.units ] }).to contain_exactly([ "channels.list", 1 ], [ "liveBroadcasts.list", 1 ])
      expect(QuotaEntry.where(bucket: %w[ prep settle ])).to be_empty
    end

    it "再接続: 暗号文だけを置き換え、保存済みの配信用ストリームの識別子を破棄する（10.5）。状態・時刻を更新する" do
      existing = create(:youtube_connection, :with_stream, user: user, state: "live_not_enabled", connected_at: now - 30.days, last_verified_at: now - 1.day)
      before = existing.reload.refresh_token_ciphertext

      connect_callback(begin_browser_flow)

      expect_connect_redirect("connected")
      expect(YoutubeConnection.count).to eq(1)
      expect(existing.reload).to have_attributes(state: "connected", youtube_stream_id: nil, stream_verified_at: nil, connected_at: now, last_verified_at: now)
      expect(existing.refresh_token_ciphertext).not_to eq(before)
    end

    it "再接続（認可失効）: 接続済みになる。保存し直した更新トークンで、アクセストークンを取得できる" do
      create(:youtube_connection, user: user, state: "revoked")

      connect_callback(begin_browser_flow)

      expect(connection_of.state).to eq("connected")
      expect(YouTubeServices.current.token_vault.access_token(user_id: user.id, now: now)).to start_with("fake-access-token-")
    end

    it "再接続（認可失効 -> ライブ未有効）" do
      create(:youtube_connection, user: user, state: "revoked")

      connect_callback(begin_browser_flow(scenario: "allow_live_not_enabled"))

      expect_connect_redirect("live_not_enabled")
      expect(connection_of.state).to eq("live_not_enabled")
    end

    it "GET なので、X-BL-Client・X-CSRF-Token は要らない（CSRF の対象外。state と PKCE で守る）" do
      connect_callback(begin_browser_flow, headers: { "X-BL-Client" => nil, "X-CSRF-Token" => nil })

      expect_connect_redirect("connected")
    end
  end

  describe "不成立（理由ごと。トークンを保存せず破棄し、既存の接続を変更しない）" do
    # 選択肢 -> [結果, 既存の接続が無いときに Google 側で失効させるか]
    {
      "allow_without_youtube" => [ "scope_denied", true ],
      "allow_without_refresh_token" => [ "no_refresh_token", true ],
      "allow_no_channel" => [ "no_channel", true ],
      "allow_unverifiable" => [ "unverifiable", true ],
      "deny" => [ "scope_denied", false ]
    }.each do |scenario, (result, revokes)|
      context "#{scenario}（#{result}）" do
        it "302 /account?connect=#{result}。接続の行を作らない・bl_oauth を失効させる・測定イベント connect_failed（結果の符号だけ）" do
          flow = begin_browser_flow(scenario: scenario)

          expect { connect_callback(flow) }.to change { UsageEvent.where(event_type: "connect_failed").count }.by(1)

          expect_connect_redirect(result)
          expect(YoutubeConnection.count).to eq(0)
          event = UsageEvent.where(event_type: "connect_failed").sole
          expect(event).to have_attributes(user_id: user.id, reason_code: result, occurred_at: now)
          expect(UsageEvent.where(event_type: "connect_completed")).to be_empty
        end

        it "受け取ったトークンを保存しない。DB のどの表にも、トークン・チャンネル名が無い" do
          connect_callback(begin_browser_flow(scenario: scenario))

          expect(database_dump).not_to match(/fake-refresh-token-|fake-connect-access-token-|Fake Channel/)
        end

        if revokes
          it "既存の接続が無いので、Google 側でも失効させる（1 回）" do
            connect_callback(begin_browser_flow(scenario: scenario))

            expect(oidc).to have_received(:revoke).once
          end
        else
          it "コードを受け取っていないので、失効させない" do
            connect_callback(begin_browser_flow(scenario: scenario))

            expect(oidc).not_to have_received(:revoke)
          end
        end

        %w[ connected live_not_enabled revoked ].each do |existing_state|
          it "既存の接続（#{existing_state}）があれば、状態・暗号文・ストリームの識別子・時刻を変更しない。Google 側でも失効させない" do
            existing = create(:youtube_connection, :with_stream, user: user, state: existing_state, connected_at: now - 9.days, last_verified_at: now - 2.days)
            before = snapshot(existing)

            connect_callback(begin_browser_flow(scenario: scenario))

            expect_connect_redirect(result)
            expect(snapshot(existing)).to eq(before)
            expect(oidc).not_to have_received(:revoke)
          end
        end
      end
    end
  end

  describe "コールバックの検査（改ざん・取り違え・期限切れ。いずれも不成立 unverifiable。接続を作らない・変えない）" do
    let!(:flow) { begin_browser_flow }

    def expect_unverifiable
      expect_connect_redirect("unverifiable")
      expect(YoutubeConnection.count).to eq(0)
      expect(UsageEvent.where(event_type: "connect_completed")).to be_empty
      expect(oidc).not_to have_received(:revoke)
    end

    it "bl_oauth が無い" do
      connect_callback(flow, oauth_cookie: nil)

      expect_unverifiable
    end

    it "bl_oauth が改ざんされている" do
      connect_callback(flow, oauth_cookie: flow[:oauth_cookie].sub(/.\z/) { |char| char == "A" ? "B" : "A" })

      expect_unverifiable
    end

    it "bl_oauth がでたらめな値" do
      connect_callback(flow, oauth_cookie: "garbage")

      expect_unverifiable
    end

    it "bl_oauth が期限切れ（開始から 10 分以上）" do
      travel_to(now + 601)

      connect_callback(flow)

      expect_unverifiable
    end

    it "bl_oauth が、ほかの秘密値で暗号化されたもの" do
      forged = OAuthStateCookie.new(secret: "dummy-another-secret-key-base-0002").seal(
        state: flow[:state], nonce: "dummy-nonce", code_verifier: "dummy-verifier", purpose: "connect", user_id: user.id, now: now
      )

      connect_callback(flow, oauth_cookie: forged)

      expect_unverifiable
    end

    it "bl_oauth の用途が login（ログインの途中の状態を、YouTube 接続に使えない）" do
      login_cookie = OAuthStateCookie.new(secret: Rails.application.secret_key_base).seal(
        state: flow[:state], nonce: "dummy-nonce", code_verifier: "dummy-verifier", purpose: "login", now: now
      )

      connect_callback(flow, oauth_cookie: login_cookie)

      expect_unverifiable
    end

    it "state が違う（別のブラウザ・別の開始の state）" do
      other = begin_browser_flow

      connect_callback(flow, state: other[:state])

      expect_unverifiable
    end

    it "state が無い・配列・ハッシュ" do
      connect_callback(flow, state: nil)
      expect_unverifiable

      api_get "/api/youtube/connect/callback?code=#{CGI.escape(flow[:code])}&state[]=#{flow[:state]}", headers: { "Cookie" => cookie_header_of(flow[:oauth_cookie], login.token) }
      expect_unverifiable

      api_get "/api/youtube/connect/callback?code=#{CGI.escape(flow[:code])}&state[a]=#{flow[:state]}", headers: { "Cookie" => cookie_header_of(flow[:oauth_cookie], login.token) }
      expect_unverifiable
    end

    it "ログインしていない（セッションの Cookie が無い）: アカウント画面へ戻す（unverifiable）。接続を作らない。測定イベントは記録しない（匿名の要求は、DB へ書き込まない）" do
      expect { connect_callback(flow, session: nil) }.not_to change(UsageEvent, :count)

      expect_unverifiable
    end

    it "ログイン中のアカウントが、bl_oauth を作ったアカウントと違う: unverifiable。どちらのアカウントの接続も、作らず・変えない" do
      other = create(:user)
      other_connection = create(:youtube_connection, :with_stream, user: other)
      before = snapshot(other_connection)

      connect_callback(flow, session: sign_in(other, now: now))

      expect_connect_redirect("unverifiable")
      expect(connection_of).to be_nil
      expect(snapshot(other_connection)).to eq(before)
      expect(oidc).not_to have_received(:revoke)
    end

    it "セッションが失効している（破棄された）: unverifiable" do
      gone = login
      SessionStore.new.revoke(gone.session)

      connect_callback(flow, session: gone)

      expect_unverifiable
    end

    it "error=access_denied（利用者が同意画面で拒否・取り消した）を直接送る: scope_denied。コードを交換しない・失効させない" do
      connect_callback(flow, code: nil, error: "access_denied")

      expect_connect_redirect("scope_denied")
      expect(YoutubeConnection.count).to eq(0)
      expect(oidc).not_to have_received(:revoke)
    end

    it "error=access_denied と正しいコードが同時にあっても、コードを交換しない（接続を作らない）" do
      connect_callback(flow, error: "access_denied")

      expect_connect_redirect("scope_denied")
      expect(YoutubeConnection.count).to eq(0)
    end

    it "error が access_denied 以外（server_error など）: unverifiable" do
      connect_callback(flow, code: nil, error: "server_error")

      expect_unverifiable
    end

    it "error があっても、state が違えば、state の不一致として扱う（access_denied の値を信用しない）。測定イベントの符号は unverifiable" do
      connect_callback(flow, code: nil, error: "access_denied", state: "dummy-other-state")

      expect_unverifiable
      expect(UsageEvent.where(event_type: "connect_failed").sole.reason_code).to eq("unverifiable")
    end

    it "コードが無い・空・配列・長すぎる" do
      connect_callback(flow, code: nil)
      expect_unverifiable

      connect_callback(flow, code: "")
      expect_unverifiable

      api_get "/api/youtube/connect/callback?code[]=x&state=#{flow[:state]}", headers: { "Cookie" => cookie_header_of(flow[:oauth_cookie], login.token) }
      expect_unverifiable

      connect_callback(flow, code: "a" * 5000)
      expect_unverifiable
    end

    it "コードが書き換えられている・期限切れ（疑似のコードは 300 秒）" do
      connect_callback(flow, code: flow[:code].sub(/.\z/) { |char| char == "A" ? "B" : "A" })
      expect_unverifiable

      travel_to(now + 301)
      connect_callback(flow)
      expect_unverifiable
    end

    it "進行中の配信がある: 再接続を受け付けない（7.4）。unverifiable。既存の接続を変えない" do
      existing = create(:youtube_connection, :with_stream, user: user)
      create(:broadcast, :live, user: user)
      before = snapshot(existing)

      connect_callback(flow)

      expect_connect_redirect("unverifiable")
      expect(snapshot(existing)).to eq(before)
      expect(oidc).not_to have_received(:revoke)
    end

    it "失敗の応答は、セッション・アカウントを作らない・変えない" do
      expect { connect_callback(flow, state: "dummy-other-state") }.not_to change { [ User.count, Session.count ] }
    end
  end

  describe "測定イベント: ログイン中のアカウントが開始した接続（有効な bl_oauth）の結果だけ記録する。匿名・開始していない要求は、DB へ書き込まない" do
    let!(:flow) { begin_browser_flow }
    let(:result_events) { UsageEvent.where(event_type: %w[ connect_completed connect_failed ]) }
    let(:login_purpose_cookie) do
      OAuthStateCookie.new(secret: Rails.application.secret_key_base).seal(
        state: flow[:state], nonce: "dummy-nonce", code_verifier: "dummy-verifier", purpose: "login", now: now
      )
    end
    let(:foreign_secret_cookie) do
      OAuthStateCookie.new(secret: "dummy-another-secret-key-base-0002").seal(
        state: flow[:state], nonce: "dummy-nonce", code_verifier: "dummy-verifier", purpose: "connect", user_id: user.id, now: now
      )
    end

    it "ログインしていない要求を、Cookie なしで何度送っても（40 回）、行が増えない。いずれも unverifiable で戻す" do
      expect do
        40.times { api_get "/api/youtube/connect/callback", headers: no_cookies }
      end.not_to change(UsageEvent, :count)

      expect(response.headers["Location"]).to eq("#{origin}/account?connect=unverifiable")
    end

    it "ログインしていなくて、有効な bl_oauth を持つ要求（セッションの Cookie だけが無い）も、記録しない" do
      expect { 5.times { connect_callback(flow, session: nil) } }.not_to change(UsageEvent, :count)
    end

    it "ログインしていても、有効な bl_oauth が無い要求（無い・改ざん・でたらめ・ほかの秘密値・用途 login）は、記録しない。何度送っても、行が増えない" do
      variants = {
        "bl_oauth が無い" => nil,
        "改ざん" => flow[:oauth_cookie].sub(/.\z/) { |char| char == "A" ? "B" : "A" },
        "でたらめ" => "garbage",
        "ほかの秘密値" => foreign_secret_cookie,
        "用途が login" => login_purpose_cookie
      }

      expect do
        variants.each_value { |cookie| 10.times { connect_callback(flow, oauth_cookie: cookie) } }
      end.not_to change(UsageEvent, :count)
      expect_connect_redirect("unverifiable")
    end

    it "期限切れの bl_oauth（開始から 10 分以上）も、記録しない" do
      travel_to(now + 601)

      expect { connect_callback(flow) }.not_to change(UsageEvent, :count)
      expect_connect_redirect("unverifiable")
    end

    it "セッションが失効している（破棄された）: 記録しない" do
      gone = login
      SessionStore.new.revoke(gone.session)

      expect { connect_callback(flow, session: gone) }.not_to change(UsageEvent, :count)
    end

    it "ほかのアカウントの bl_oauth を、他方のセッションで使っても、どちらのアカウントにも記録しない" do
      other = create(:user, google_sub: "dev-user-2")

      expect { connect_callback(flow, session: sign_in(other, now: now)) }.not_to change(UsageEvent, :count)
      expect(result_events.where(user_id: [ user.id, other.id ])).to be_empty
    end

    {
      "state が違う" => { state: "dummy-other-state" },
      "コードが無い" => { code: nil },
      "コードが書き換えられている" => { code: "dummy-tampered-code" },
      "error=server_error" => { code: nil, error: "server_error" }
    }.each do |label, overrides|
      it "開始した接続の失敗（#{label}）は、記録する: connect_failed を 1 件、このアカウントに、結果の符号 unverifiable だけで" do
        expect { connect_callback(flow, **overrides) }.to change { result_events.count }.by(1)

        expect(result_events.sole).to have_attributes(event_type: "connect_failed", user_id: user.id, reason_code: "unverifiable")
        expect_connect_redirect("unverifiable")
      end
    end

    it "開始した接続の成功は、connect_completed を 1 件、このアカウントに記録する" do
      expect { connect_callback(flow) }.to change { result_events.count }.by(1)

      expect(result_events.sole).to have_attributes(event_type: "connect_completed", user_id: user.id, reason_code: "connected")
    end
  end

  describe "リダイレクト先は、常に公開オリジン（PublicOrigin。X-Forwarded-Host から作る）" do
    let(:railway_host) { "backend-production-1234.up.railway.app" }

    it "バックエンドのホスト（Host）がどれでも、成立・不成立の Location は、フロントエンドのホスト" do
      flow = begin_browser_flow
      connect_callback(flow, headers: { "Host" => railway_host })
      success = response.headers["Location"]

      denied = begin_browser_flow(scenario: "deny")
      connect_callback(denied, headers: { "Host" => railway_host })

      expect([ success, response.headers["Location"] ]).to eq([ "#{origin}/account?connect=connected", "#{origin}/account?connect=scope_denied" ])
      expect([ success, response.headers["Location"] ]).to all(satisfy { |location| !location.include?("railway") })
    end

    it "Location のホストとスキームは、X-Forwarded-Host・X-Forwarded-Proto から決まる（開発: http://localhost:3000）" do
      # コードは、認可の開始の戻り先に結びつく。ここでは戻り先を変えるので、コードを使わない拒否（error=access_denied）で確かめる
      connect_callback(begin_browser_flow(scenario: "deny"), headers: { "X-Forwarded-Host" => "localhost:3000", "X-Forwarded-Proto" => "http" })

      expect(response.headers["Location"]).to eq("http://localhost:3000/account?connect=scope_denied")
    end

    it "コードは、認可の開始の戻り先に結びつく: 戻り先（公開オリジン）が開始のときと違えば、交換できず unverifiable" do
      connect_callback(begin_browser_flow, headers: { "X-Forwarded-Host" => "localhost:3000", "X-Forwarded-Proto" => "http" })

      expect(response.headers["Location"]).to eq("http://localhost:3000/account?connect=unverifiable")
      expect(YoutubeConnection.count).to eq(0)
    end

    it "公開オリジンが分からない（X-Forwarded-Host が無い）ときは、バックエンドのホストへ倒さず、500 internal_error（リダイレクトしない）" do
      connect_callback(begin_browser_flow, headers: { "X-Forwarded-Host" => nil })

      expect(response).to have_http_status(500)
      expect(response.headers["Location"]).to be_nil
      expect(error_code).to eq("internal_error")
    end

    it "攻撃者が選べる Host ヘッダは、リダイレクト先に影響しない" do
      connect_callback(begin_browser_flow, error: "access_denied", code: nil, headers: { "Host" => "evil.example.test" })

      expect(URI.parse(response.headers["Location"]).host).to eq(ApiHelpers::PUBLIC_HOST)
    end
  end

  describe "共通の規約（#7 の基盤）" do
    it "X-BFF-Secret が無い要求は、リダイレクトせず 403 forbidden。接続を作らない" do
      flow = begin_browser_flow

      connect_callback(flow, headers: { "X-BFF-Secret" => nil })

      expect(response).to have_http_status(403)
      expect(error_code).to eq("forbidden")
      expect(response.headers["Location"]).to be_nil
      expect(YoutubeConnection.count).to eq(0)
    end

    it "ログインの方針は、匿名と宣言している（Api::YoutubeController#connect_callback。セッションとの一致は、手続きで確かめる）" do
      expect(Api::YoutubeController.login_policy_for("connect_callback")).to eq(:anonymous)
    end

    it "POST は経路が無い（GET だけ）" do
      api_post "/api/youtube/connect/callback", {}, signed_in: login

      expect(response).to have_http_status(404)
    end
  end

  describe "機密（ログ・DB・応答）" do
    it "全体の流れのログに、認可コード・state・bl_oauth の値・トークン・チャンネル名・IP が出ない（成立・不成立の両方）" do
      secrets = []
      output = capture_logs do
        flow = begin_browser_flow
        secrets += [ flow[:code], flow[:state], flow[:oauth_cookie] ]
        connect_callback(flow)

        denied = begin_browser_flow(scenario: "allow_without_youtube")
        secrets += [ denied[:code], denied[:state], denied[:oauth_cookie] ]
        connect_callback(denied)
      end

      (secrets + [ "fake-refresh-token-", "fake-connect-access-token-", "Fake Channel", ApiHelpers::CLIENT_IP ]).each do |secret|
        expect(output).not_to include(secret), "ログに機密が出ている: #{secret[0, 12]}"
      end
      expect(output).to include("[youtube_connect] completed user_id=#{user.id} result=connected")
    end

    it "応答（302）の本文は空。Location に、コード・state・トークンを含めない" do
      flow = begin_browser_flow

      connect_callback(flow)

      expect(response.body).to be_empty
      expect(response.headers["Location"]).not_to include(flow[:code])
      expect(response.headers["Location"]).not_to include(flow[:state])
    end

    it "保存されるのは、暗号化した更新トークンだけ（アクセストークン・平文の更新トークン・チャンネル名・コード・state は、DB のどの表にも無い）" do
      flow = begin_browser_flow

      connect_callback(flow)

      dump = database_dump
      [ "fake-refresh-token-", "fake-connect-access-token-", "Fake Channel", flow[:code], flow[:state] ].each { |secret| expect(dump).not_to include(secret) }
      expect(dump).to include(connection_of.refresh_token_ciphertext)
    end
  end

  describe "他のアカウントに影響しない（2 アカウント）" do
    it "あるアカウントの接続が、他のアカウントの接続の行・ストリームの識別子を変えない" do
      other = create(:user)
      other_connection = create(:youtube_connection, :with_stream, user: other, state: "live_not_enabled")
      before = snapshot(other_connection)

      connect_callback(begin_browser_flow)

      expect(snapshot(other_connection)).to eq(before)
      expect(YoutubeConnection.owned_by(user).count).to eq(1)
    end

    it "2 つのアカウントが、それぞれの流れで接続できる（互いの bl_oauth・セッションは、混ざらない）" do
      other = create(:user, google_sub: "dev-user-2")
      first_session = login
      second_session = sign_in(other, now: now)
      first = begin_browser_flow(first_session)
      second = begin_browser_flow(second_session)

      connect_callback(first, session: first_session)
      connect_callback(second, session: second_session)

      expect(YoutubeConnection.owned_by(user).count).to eq(1)
      expect(YoutubeConnection.owned_by(other).count).to eq(1)
      expect(connection_of.refresh_token_ciphertext).not_to eq(connection_of(other).refresh_token_ciphertext)
    end

    it "取り違え: 一方のアカウントの bl_oauth を、他方のセッションで使えない" do
      other = create(:user, google_sub: "dev-user-2")
      first = begin_browser_flow

      connect_callback(first, session: sign_in(other, now: now))

      expect_connect_redirect("unverifiable")
      expect(YoutubeConnection.count).to eq(0)
    end
  end
end
