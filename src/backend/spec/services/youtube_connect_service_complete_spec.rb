require "rails_helper"
require "support/youtube_connect_support"

# YouTube 接続のコールバックと接続時の確認 YouTubeConnectService#complete（issue #11。requirements.md 7.2・7.3・10.5・23.1・25.4・28.2。
# src/contracts/http-api.md 3 章 connect/callback）。
#   判定（7.2 の表）: 権限の部分拒否 -> scope_denied / 更新トークンなし -> no_refresh_token / チャンネルなし -> no_channel /
#                     確認不能（共通枠の枯渇・一時的な失敗）-> unverifiable / ライブ配信が有効 -> connected / 有効でない -> live_not_enabled
#   成立: 更新トークンを暗号化して保存（TokenVault）。接続の行を作成または更新（状態・接続の時刻・確認の時刻）。保存済みの配信用ストリームの識別子を破棄する
#         （10.5。再接続を含め、成立のたびに）。チャンネル名をメモリに置く
#   不成立: 受け取ったトークンを保存せず破棄する。既存の接続が無い場合に限り、Google 側でも失効させる。既存の接続の状態・トークン・ストリームの識別子は変更しない
RSpec.describe YouTubeConnectService, "#complete（コールバックと接続時の確認）" do
  include LedgerSupport
  include YouTubeConnectSupport
  include ActiveSupport::Testing::TimeHelpers
  include_context "YouTube 接続の環境"

  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:user) { create(:user, google_sub: "dev-user-1") }
  let(:service) { connect_service }
  let(:flow) { begin_connect(user) }
  let(:code) { grant_code(flow) }

  before { travel_to(now) }
  after { travel_back }

  def connection_of(account = user)
    YoutubeConnection.owned_by(account).take
  end

  # 接続の行の、保護の対象の値（不成立のとき、変わらないこと）
  def snapshot(connection)
    connection.reload.slice(:state, :refresh_token_ciphertext, :youtube_stream_id, :stream_verified_at, :connected_at, :last_verified_at)
  end

  # 共通枠の明細（呼び出しの種別・ユニット）。時間を固定しているので、並びは定まらない（順序に依存しない比較で使う）
  def common_entries
    QuotaEntry.where(bucket: "common").map { |entry| [ entry.method, entry.units ] }
  end

  describe "成立: ライブ配信が有効（connected）" do
    it "未接続 -> 接続済み。接続の行を作る（状態 connected・接続の時刻・確認の時刻は now）。ストリームの識別子は持たない" do
      completion = complete_connect(flow, code: code)

      expect(completion).to have_attributes(result: "connected", reason: nil)
      expect(completion).to be_success
      expect(YoutubeConnection.owned_by(user).count).to eq(1)
      expect(connection_of).to have_attributes(
        state: "connected", connected_at: now, last_verified_at: now, youtube_stream_id: nil, stream_verified_at: nil
      )
    end

    it "更新トークンは、暗号化して保存する。DB の暗号文は平文を含まず、保存した更新トークンで、アクセストークンを取得できる" do
      token_client = instance_double(GoogleTokenClient)
      vault = TokenVault.new(key: connect_key, token_client: token_client, cache: TokenVault::AccessTokenCache.new)
      granted = grant_of(flow, code)

      complete_connect(flow, code: code, service: connect_service_with(vault))

      ciphertext = connection_of.refresh_token_ciphertext
      expect(ciphertext).not_to include(granted.refresh_token)
      expect(ciphertext).not_to include(granted.access_token)
      expect(token_client).to receive(:refresh).with(refresh_token: granted.refresh_token)
                                               .and_return(GoogleTokenClient::Tokens.new(access_token: "ya29.dummy-after-connect", expires_in: 3600))
      expect(vault.access_token(user_id: user.id, now: now)).to eq("ya29.dummy-after-connect")
    end

    it "保存されるのは、暗号化した更新トークンだけ。アクセストークン・平文の更新トークン・チャンネル名・コード・state・検証子は、DB のどの表にも無い" do
      granted = grant_of(flow, code)

      complete_connect(flow, code: code)

      dump = database_dump
      [ granted.access_token, granted.refresh_token, "Fake Channel", code, flow.started.state, flow.started.code_verifier ].each do |secret|
        expect(dump).not_to include(secret)
      end
      expect(dump).to include(connection_of.refresh_token_ciphertext)
    end

    it "チャンネル名は、メモリ（ChannelNameCache）に置く。取得から 10 分で失効する" do
      complete_connect(flow, code: code)

      expect(channel_names.cached(user.id)).to eq("Fake Channel")

      travel_to(now + 599)
      expect(channel_names.cached(user.id)).to eq("Fake Channel")
      travel_to(now + 600)
      expect(channel_names.cached(user.id)).to be_nil
    end

    it "確認は、共通枠から 2 ユニット（チャンネルの一覧取得 1 + 配信の一覧取得 1）。配信の予約（準備・確認枠・終了・清算枠）は取り崩さない" do
      complete_connect(flow, code: code)

      expect(common_entries).to contain_exactly([ "channels.list", 1 ], [ "liveBroadcasts.list", 1 ])
      expect(QuotaEntry.where(bucket: %w[ prep settle ])).to be_empty
    end

    it "成立のとき、Google 側でトークンを失効させない" do
      allow(fake_oidc).to receive(:revoke)

      complete_connect(flow, code: code)

      expect(fake_oidc).not_to have_received(:revoke)
    end

    it "窓口（YouTube の確認）は、トランザクションの外で呼ぶ（記帳が HTTP の失敗で巻き戻らない・台帳の行ロックを HTTP の待ちのあいだ持たない）。" \
       "確認が済んでから、保存のトランザクションを開く" do
      inside = []
      allow(fake_youtube).to receive(:probe_channel).and_wrap_original do |original, *args, **options|
        inside << ApplicationRecord.with_connection { |connection| connection.current_transaction.joinable? }
        original.call(*args, **options)
      end

      complete_connect(flow, code: code)

      expect(inside).to eq([ false ]) # テスト自身のトランザクションは、結合できない。結合できるトランザクションの中ではない
      expect(YoutubeConnection.owned_by(user).count).to eq(1)
    end

    it "確認には、交換で得たアクセストークンを使う（接続の行はまだ無い。窓口は conn = nil・access_token つきで呼ばれる）" do
      allow(fake_youtube).to receive(:probe_channel).and_call_original
      granted = grant_of(flow, code)

      complete_connect(flow, code: code)

      expect(fake_youtube).to have_received(:probe_channel).with(nil, access_token: granted.access_token).once
    end
  end

  describe "成立: ライブ配信が有効でない（live_not_enabled）" do
    it "未接続 -> ライブ未有効。接続の行の状態は live_not_enabled（接続は成立）。チャンネル名はメモリに置く" do
      fake_youtube.fail_next(:live_not_enabled, on: :probe_live_enabled)

      completion = complete_connect(flow, code: code)

      expect(completion).to have_attributes(result: "live_not_enabled", reason: nil)
      expect(completion).to be_success
      expect(connection_of).to have_attributes(state: "live_not_enabled", connected_at: now, last_verified_at: now)
      expect(channel_names.cached(user.id)).to eq("Fake Channel")
    end

    it "ライブ配信が制限されている（livePermissionBlocked）も、ライブ未有効・制限中として成立する" do
      fake_youtube.fail_next(:live_streaming_restricted, on: :probe_live_enabled)

      expect(complete_connect(flow, code: code)).to have_attributes(result: "live_not_enabled")
      expect(connection_of.state).to eq("live_not_enabled")
    end

    it "チャンネルの一覧取得の側で、チャンネルの閉鎖・停止（channelClosed 等）が返っても、例外のまま伝わる（窓口は結果にしない）。" \
       "disposition の接続状態に従って、ライブ未有効・制限中として成立する。チャンネル名は無い" do
      fake_youtube.fail_next(:live_streaming_restricted, on: :probe_channel_lookup)

      completion = complete_connect(flow, code: code)

      expect(completion).to have_attributes(result: "live_not_enabled")
      expect(connection_of.state).to eq("live_not_enabled")
      expect(channel_names.cached(user.id)).to be_nil
    end

    it "チャンネルの一覧取得の側で LiveNotEnabled が返っても、同じ（disposition の接続状態に従う）" do
      fake_youtube.fail_next(:live_not_enabled, on: :probe_channel_lookup)

      expect(complete_connect(flow, code: code)).to have_attributes(result: "live_not_enabled")
    end
  end

  describe "再接続（既存の接続がある）" do
    let!(:existing) { create(:youtube_connection, :with_stream, user: user, connected_at: now - 30.days, last_verified_at: now - 1.day) }

    it "更新トークンの暗号文だけを置き換え、状態・接続の時刻・確認の時刻を更新する。行は増えない" do
      before_ciphertext = existing.refresh_token_ciphertext

      complete_connect(flow, code: code)

      connection = connection_of
      expect(YoutubeConnection.owned_by(user).count).to eq(1)
      expect(connection.id).to eq(existing.id)
      expect(connection.refresh_token_ciphertext).not_to eq(before_ciphertext)
      expect(connection).to have_attributes(state: "connected", connected_at: now, last_verified_at: now)
    end

    it "保存済みの配信用ストリームの識別子を破棄する（10.5。再接続を含め、成立のたびに）。最終確認の時刻も消す" do
      expect(existing.youtube_stream_id).to be_present

      complete_connect(flow, code: code)

      expect(connection_of).to have_attributes(youtube_stream_id: nil, stream_verified_at: nil)
    end

    it "ストリームの取り替えの規則（StreamReplacementPolicy）の、接続の成立のトリガーに従う" do
      allow(StreamReplacementPolicy).to receive(:discard?).and_call_original

      complete_connect(flow, code: code)

      expect(StreamReplacementPolicy).to have_received(:discard?).with(trigger: StreamReplacementPolicy::YOUTUBE_CONNECTED)
    end

    it "識別子を持たない接続でも、成立する（破棄は冪等）" do
      existing.update!(youtube_stream_id: nil, stream_verified_at: nil)

      expect(complete_connect(flow, code: code)).to have_attributes(result: "connected")
      expect(connection_of.youtube_stream_id).to be_nil
    end

    it "ライブ未有効 -> 接続済み（再接続でライブ有効）" do
      existing.update!(state: "live_not_enabled")

      expect(complete_connect(flow, code: code)).to have_attributes(result: "connected")
      expect(connection_of.state).to eq("connected")
    end

    it "接続済み -> ライブ未有効（再接続でライブ未有効）" do
      fake_youtube.fail_next(:live_not_enabled, on: :probe_live_enabled)

      expect(complete_connect(flow, code: code)).to have_attributes(result: "live_not_enabled")
      expect(connection_of.state).to eq("live_not_enabled")
    end

    it "認可失効 -> 接続済み（再接続・ライブ有効）。保存し直した更新トークンで、アクセストークンを取得できる（認可失効のままだと TokenRevoked が続く）" do
      existing.update!(state: "revoked")
      expect { token_vault.access_token(user_id: user.id, now: now) }.to raise_error(YouTubeErrors::TokenRevoked)

      expect(complete_connect(flow, code: code)).to have_attributes(result: "connected")

      expect(connection_of.state).to eq("connected")
      expect(token_vault.access_token(user_id: user.id, now: now)).to start_with("fake-access-token-")
    end

    it "認可失効 -> ライブ未有効（再接続・ライブ未有効）" do
      existing.update!(state: "revoked")
      fake_youtube.fail_next(:live_not_enabled, on: :probe_live_enabled)

      expect(complete_connect(flow, code: code)).to have_attributes(result: "live_not_enabled")
      expect(connection_of.state).to eq("live_not_enabled")
    end

    it "成立のとき、前のアクセストークン（メモリ上のキャッシュ）を捨てる" do
      stored_user = create(:user)
      token_vault.store(user_id: stored_user.id, refresh_token: "1//dummy-previous-refresh-token", now: now - 1.day)
      token_vault.access_token(user_id: stored_user.id, now: now) # キャッシュに載せる
      expect(YouTubeServices.shared_access_token_cache.size).to eq(1)
      reconnect = begin_connect(stored_user)

      complete_connect(reconnect, code: grant_code(reconnect))

      expect(YouTubeServices.shared_access_token_cache.size).to eq(0)
    end

    it "チャンネル名のキャッシュを置き換える（別のチャンネルを選んだ再接続で、前のチャンネル名を返さない）" do
      channel_names.write(user.id, "dummy-previous-channel-title")

      complete_connect(flow, code: code)

      expect(channel_names.cached(user.id)).to eq("Fake Channel")
    end

    it "再接続でチャンネル名が分からないとき（チャンネルの閉鎖）は、前のチャンネル名を捨てる（古い名前を残さない）" do
      channel_names.write(user.id, "dummy-previous-channel-title")
      fake_youtube.fail_next(:live_streaming_restricted, on: :probe_channel_lookup)

      complete_connect(flow, code: code)

      expect(channel_names.cached(user.id)).to be_nil
    end

    it "成立の更新は、1 つのトランザクション: 途中で失敗すると、暗号文も状態もストリームの識別子も、元のまま。例外は伝わる" do
      before = snapshot(existing)
      allow_any_instance_of(YoutubeConnection).to receive(:discard_stream!).and_raise(ActiveRecord::StatementInvalid, "dummy failure")

      expect { complete_connect(flow, code: code) }.to raise_error(ActiveRecord::StatementInvalid)

      expect(snapshot(existing)).to eq(before)
    end

    it "成立の更新が失敗したとき、チャンネル名のキャッシュを置き換えない" do
      channel_names.write(user.id, "dummy-previous-channel-title")
      allow_any_instance_of(YoutubeConnection).to receive(:discard_stream!).and_raise(ActiveRecord::StatementInvalid, "dummy failure")

      expect { complete_connect(flow, code: code) }.to raise_error(ActiveRecord::StatementInvalid)

      expect(channel_names.cached(user.id)).to eq("dummy-previous-channel-title")
    end
  end

  describe "他のアカウントに影響しない（2 アカウント）" do
    let(:other) { create(:user) }
    let!(:other_connection) { create(:youtube_connection, :with_stream, user: other, state: "live_not_enabled") }

    it "あるアカウントの接続・再接続が、他のアカウントの接続の行・ストリームの識別子・チャンネル名を変えない" do
      channel_names.write(other.id, "dummy-other-channel-title")
      before = snapshot(other_connection)

      complete_connect(flow, code: code)

      expect(snapshot(other_connection)).to eq(before)
      expect(channel_names.cached(other.id)).to eq("dummy-other-channel-title")
      expect(YoutubeConnection.owned_by(user).count).to eq(1)
    end

    it "不成立のときも、他のアカウントに影響しない" do
      before = snapshot(other_connection)

      expect(complete_connect(flow, code: grant_code(flow, kind: FakeGoogleOidc::WITHOUT_YOUTUBE_SCOPE))).to have_attributes(result: "scope_denied")

      expect(snapshot(other_connection)).to eq(before)
    end

    it "別のアカウントの bl_oauth（user_id が違う）は、不成立にする。どちらのアカウントの接続も作らず・変えず、コードを交換しない" do
      stolen = flow.payload
      before = snapshot(other_connection)
      allow(fake_oidc).to receive(:exchange_youtube_code).and_call_original

      completion = complete_connect(flow, code: code, user: other, payload: stolen)

      expect(completion).to have_attributes(result: "unverifiable", reason: :account_mismatch)
      expect(fake_oidc).not_to have_received(:exchange_youtube_code)
      expect(YoutubeConnection.owned_by(user)).to be_empty
      expect(snapshot(other_connection)).to eq(before)
    end
  end

  describe "不成立（受け取ったトークンを保存せず破棄する。既存の接続が無い場合に限り、Google 側でも失効させる）" do
    before { allow(fake_oidc).to receive(:revoke).and_call_original }

    # 不成立の種類 -> [準備（YouTube・台帳への注入）, 期待する結果, 理由, 付与の種類]
    {
      "権限の部分拒否（youtube のスコープが付与されていない）" => [ nil, "scope_denied", :youtube_scope_not_granted, FakeGoogleOidc::WITHOUT_YOUTUBE_SCOPE ],
      "更新トークンが無い" => [ nil, "no_refresh_token", :refresh_token_missing, FakeGoogleOidc::WITHOUT_REFRESH_TOKEN ],
      "チャンネルが無い" => [ ->(youtube) { youtube.fail_next(:no_channel) }, "no_channel", :channel_not_found, FakeGoogleOidc::FULL ],
      "確認不能（一時的な失敗）" => [ ->(youtube) { youtube.fail_next(:transient) }, "unverifiable", :transient, FakeGoogleOidc::FULL ],
      "確認不能（タイムアウト）" => [ ->(youtube) { youtube.fail_next(:timeout) }, "unverifiable", :timeout, FakeGoogleOidc::FULL ],
      "確認不能（ライブ配信の確認の一時的な失敗）" => [ ->(youtube) { youtube.fail_next(:transient, on: :probe_live_enabled) }, "unverifiable", :transient, FakeGoogleOidc::FULL ],
      "確認不能（YouTube が割り当て超過を返した）" => [ ->(youtube) { youtube.fail_next(:quota_exceeded) }, "unverifiable", :quota_exceeded, FakeGoogleOidc::FULL ],
      "確認不能（想定外の応答）" => [ ->(youtube) { youtube.fail_next(:unexpected_response) }, "unverifiable", :unexpected_response, FakeGoogleOidc::FULL ],
      "確認不能（要求が多すぎる）" => [ ->(youtube) { youtube.fail_next(:rate_limited) }, "unverifiable", :rate_limited, FakeGoogleOidc::FULL ],
      "権限が不足している（insufficientPermissions）" => [ ->(youtube) { youtube.fail_next(:insufficient_permissions) }, "scope_denied", :insufficient_permissions, FakeGoogleOidc::FULL ]
    }.each do |label, (arrange, result, reason, kind)|
      context label do
        before { arrange&.call(fake_youtube) }

        it "結果は #{result}（理由 #{reason}）。接続の行を作らない" do
          completion = complete_connect(flow, code: grant_code(flow, kind: kind))

          expect(completion).to have_attributes(result: result, reason: reason)
          expect(completion).not_to be_success
          expect(YoutubeConnection.owned_by(user)).to be_empty
        end

        it "受け取ったトークンを保存しない。DB のどの表にも、トークンが無い" do
          granted_code = grant_code(flow, kind: kind)
          granted = grant_of(flow, granted_code)

          complete_connect(flow, code: granted_code)

          dump = database_dump
          [ granted.access_token, granted.refresh_token ].compact.each { |secret| expect(dump).not_to include(secret) }
        end

        it "既存の接続が無いので、Google 側でも失効させる（更新トークンがあればそれを、無ければアクセストークンを）" do
          granted_code = grant_code(flow, kind: kind)
          granted = grant_of(flow, granted_code)

          complete_connect(flow, code: granted_code)

          expect(fake_oidc).to have_received(:revoke).with(token: granted.refresh_token || granted.access_token).once
        end

        it "チャンネル名をメモリに置かない" do
          complete_connect(flow, code: grant_code(flow, kind: kind))

          expect(channel_names.cached(user.id)).to be_nil
        end

        %w[ connected live_not_enabled revoked ].each do |existing_state|
          it "既存の接続（#{existing_state}）があれば、状態・暗号文・ストリームの識別子・時刻を変更せず、Google 側でも失効させない（同じ付与を共有するため）" do
            existing = create(:youtube_connection, :with_stream, user: user, state: existing_state, connected_at: now - 9.days, last_verified_at: now - 2.days)
            channel_names.write(user.id, "dummy-existing-channel-title")
            before = snapshot(existing)

            completion = complete_connect(flow, code: grant_code(flow, kind: kind))

            expect(completion.result).to eq(result)
            expect(snapshot(existing)).to eq(before)
            expect(fake_oidc).not_to have_received(:revoke)
            expect(channel_names.cached(user.id)).to eq("dummy-existing-channel-title")
          end
        end
      end
    end

    it "確認不能（共通枠の枯渇）: 窓口が YouTube を呼ばず、unverifiable。受け取ったトークンは破棄し、失効させる" do
      seed_day(UsageCalendar.quota_date(now), common: QuotaPolicy::COMMON_UNITS)

      completion = complete_connect(flow, code: code)

      expect(completion).to have_attributes(result: "unverifiable", reason: :quota_insufficient)
      expect(YoutubeConnection.owned_by(user)).to be_empty
      expect(fake_oidc).to have_received(:revoke).once
    end

    it "確認不能（共通枠が 1 ユニットだけ残っている）: 1 呼び出し目は通り、2 呼び出し目で止まる。unverifiable で、接続を作らない" do
      seed_day(UsageCalendar.quota_date(now), common: QuotaPolicy::COMMON_UNITS - 1)

      expect(complete_connect(flow, code: code)).to have_attributes(result: "unverifiable", reason: :quota_insufficient)
      expect(YoutubeConnection.owned_by(user)).to be_empty
    end

    it "割り当て超過を YouTube が返したとき、台帳に超過の印を付ける（窓口の動作）。接続は不成立" do
      fake_youtube.fail_next(:quota_exceeded)

      complete_connect(flow, code: code)

      expect(QuotaDay.find(UsageCalendar.quota_date(now))).to have_attributes(exhausted: true)
    end

    it "Google 側の失効が失敗しても（一時的な失敗・想定外の応答）、結果は変わらない。失敗を記録する" do
      allow(fake_oidc).to receive(:revoke).and_raise(YouTubeErrors::TokenTemporarilyUnavailable.new(call_kind: :token_revoke, status: 503))

      output = capture_logs { @completion = complete_connect(flow, code: grant_code(flow, kind: FakeGoogleOidc::WITHOUT_YOUTUBE_SCOPE)) }

      expect(@completion).to have_attributes(result: "scope_denied")
      expect(output).to include("[youtube_connect] revoke failed user_id=#{user.id}")
      expect(YoutubeConnection.owned_by(user)).to be_empty
    end

    it "Google 側の失効が想定外の応答でも、結果は変わらない" do
      allow(fake_oidc).to receive(:revoke).and_raise(YouTubeErrors::UnexpectedResponse.new(call_kind: :token_revoke, status: 403))

      expect(complete_connect(flow, code: grant_code(flow, kind: FakeGoogleOidc::WITHOUT_REFRESH_TOKEN))).to have_attributes(result: "no_refresh_token")
    end

    it "失効の呼び出しは、台帳の外（YouTube API ではなく Google のトークンの失効の口）: 失効で、台帳の明細も、YouTube への呼び出しも増えない" do
      fake_youtube.fail_next(:no_channel)
      allow(fake_youtube).to receive(:probe_channel).and_call_original

      complete_connect(flow, code: code)

      expect(fake_oidc).to have_received(:revoke).once
      expect(fake_youtube).to have_received(:probe_channel).once
      expect(common_entries).to contain_exactly([ "channels.list", 1 ]) # チャンネルの確認の 1 ユニットだけ。失効は記帳されない
    end
  end

  describe "コードを交換する前の拒否（unverifiable。トークンを受け取らないので、失効もしない）" do
    before do
      allow(fake_oidc).to receive(:exchange_youtube_code).and_call_original
      allow(fake_oidc).to receive(:revoke).and_call_original
    end

    def expect_refused(completion, reason, result: "unverifiable")
      expect(completion).to have_attributes(result: result, reason: reason)
      expect(fake_oidc).not_to have_received(:exchange_youtube_code)
      expect(fake_oidc).not_to have_received(:revoke)
      expect(YoutubeConnection.owned_by(user)).to be_empty
      expect(QuotaEntry.count).to eq(0)
    end

    it "bl_oauth が無い・無効（nil）" do
      expect_refused(complete_connect(flow, code: code, payload: nil), :state_cookie_invalid)
    end

    it "state が一致しない" do
      expect_refused(complete_connect(flow, code: code, state: "dummy-other-state"), :state_mismatch)
    end

    it "state が無い・文字列でない（nil・配列・ハッシュ）" do
      [ nil, [ flow.started.state ], { "a" => flow.started.state }, 123 ].each do |bad|
        expect_refused(complete_connect(flow, code: code, state: bad), :state_mismatch)
      end
    end

    it "ログイン中のセッションのアカウントが、bl_oauth のアカウントと違う" do
      other = create(:user)

      expect_refused(complete_connect(flow, code: code, user: other), :account_mismatch)
      expect(YoutubeConnection.owned_by(other)).to be_empty
    end

    it "ログインしていない（セッションが無い）" do
      expect_refused(complete_connect(flow, code: code, user: nil), :not_logged_in)
    end

    it "error=access_denied（同意画面での拒否・取り消し）: scope_denied" do
      expect_refused(complete_connect(flow, code: nil, error: "access_denied"), :authorization_denied, result: "scope_denied")
    end

    it "error=access_denied と正しいコードが同時にあっても、コードを交換しない" do
      expect_refused(complete_connect(flow, code: code, error: "access_denied"), :authorization_denied, result: "scope_denied")
    end

    [ "server_error", "temporarily_unavailable", "invalid_scope", "interaction_required", "", [ "access_denied" ], { "a" => 1 } ].each do |other_error|
      it "error=#{other_error.inspect}（access_denied 以外）: unverifiable" do
        expect_refused(complete_connect(flow, code: nil, error: other_error), :authorization_error)
      end
    end

    it "error があっても、state が一致しなければ、state の不一致（error の値を信用しない）" do
      expect_refused(complete_connect(flow, code: nil, error: "access_denied", state: "dummy-other-state"), :state_mismatch)
    end

    [ nil, "", "   ", 123, [ "x" ], { "a" => 1 } ].each do |bad_code|
      it "コードが#{bad_code.inspect}: unverifiable" do
        expect_refused(complete_connect(flow, code: bad_code), :code_missing)
      end
    end

    it "コードが長すぎる" do
      expect_refused(complete_connect(flow, code: "a" * (LoginProcedure::CODE_MAX_LENGTH + 1)), :code_too_long)
    end

    it "bl_oauth の用途が connect でない（ログインの状態を、YouTube 接続に使えない）は、呼び出しの誤り（ArgumentError）" do
      login_payload = OAuthStateCookie::Payload.new(state: "s", nonce: "n", code_verifier: "v", purpose: "login", user_id: nil)

      expect { complete_connect(flow, code: code, payload: login_payload) }.to raise_error(ArgumentError, /payload/)
    end

    it "進行中の配信がある: 再接続を受け付けない（7.4）。unverifiable。コードを交換せず、既存の接続を変えない" do
      existing = create(:youtube_connection, :with_stream, user: user)
      create(:broadcast, :live, user: user)
      before = snapshot(existing)

      expect_refused_with_existing(complete_connect(flow, code: code), :broadcast_in_progress)
      expect(snapshot(existing)).to eq(before)
    end

    def expect_refused_with_existing(completion, reason)
      expect(completion).to have_attributes(result: "unverifiable", reason: reason)
      expect(fake_oidc).not_to have_received(:exchange_youtube_code)
      expect(fake_oidc).not_to have_received(:revoke)
    end
  end

  describe "コードの交換の失敗（unverifiable。トークンを受け取っていないので、失効しない）" do
    before do
      allow(fake_oidc).to receive(:revoke).and_call_original
    end

    it "コードが書き換えられている" do
      tampered = code.sub(/.\z/) { |char| char == "A" ? "B" : "A" }

      completion = complete_connect(flow, code: tampered)

      expect(completion).to have_attributes(result: "unverifiable", reason: :exchange_code_invalid)
      expect(fake_oidc).not_to have_received(:revoke)
    end

    it "コードが期限切れ（疑似のコードは 300 秒）" do
      issued = code # 時間を進める前に発行する
      travel_to(now + 301)

      expect(complete_connect(flow, code: issued, now: Time.current)).to have_attributes(result: "unverifiable", reason: :exchange_code_expired)
    end

    it "PKCE の検証子が違う（bl_oauth の検証子と、認可の開始の challenge が対応しない）" do
      mismatched = flow.payload.with(code_verifier: "dummy-other-verifier-0123456789-abcdefghijklmnopqrstuvwxyz")

      expect(complete_connect(flow, code: code, payload: mismatched)).to have_attributes(result: "unverifiable", reason: :exchange_pkce_mismatch)
    end

    it "Google が交換を拒否した・到達できない・応答が壊れている（GoogleOidc::AuthenticationFailed の理由の符号を、理由に残す）" do
      %i[ token_exchange_rejected token_endpoint_unreachable token_response_invalid ].each do |failure_reason|
        allow(fake_oidc).to receive(:exchange_youtube_code).and_raise(GoogleOidc::AuthenticationFailed.new(failure_reason))

        completion = complete_connect(flow, code: code)

        expect(completion).to have_attributes(result: "unverifiable", reason: :"exchange_#{failure_reason}")
        expect(YoutubeConnection.owned_by(user)).to be_empty
      end
    end

    it "既存の接続は変更しない" do
      existing = create(:youtube_connection, :with_stream, user: user)
      before = snapshot(existing)

      complete_connect(flow, code: "garbage")

      expect(snapshot(existing)).to eq(before)
    end
  end

  describe "ログ（トークン・コード・state・検証子・チャンネル名を出さない。何が・どのアカウントで・なぜ失敗したかは出す）" do
    def secrets_for(granted, flow_in, code_in)
      [ granted.access_token, granted.refresh_token, code_in, flow_in.started.state, flow_in.started.code_verifier, "Fake Channel" ].compact
    end

    it "成立: 内部のアカウント識別子と結果だけ" do
      granted = grant_of(flow, code)

      output = capture_logs { complete_connect(flow, code: code) }

      expect(output).to include("[youtube_connect] completed user_id=#{user.id} result=connected")
      secrets_for(granted, flow, code).each { |secret| expect(output).not_to include(secret) }
    end

    it "不成立: 結果と理由の符号とアカウント識別子" do
      broken = grant_code(flow, kind: FakeGoogleOidc::WITHOUT_REFRESH_TOKEN)
      granted = grant_of(flow, broken)

      output = capture_logs { complete_connect(flow, code: broken) }

      expect(output).to include("[youtube_connect] failed user_id=#{user.id} result=no_refresh_token reason=refresh_token_missing")
      secrets_for(granted, flow, broken).each { |secret| expect(output).not_to include(secret) }
    end

    it "確認の失敗: YouTube の応答の本文・メッセージを出さない" do
      fake_youtube.fail_next(:transient)

      output = capture_logs { complete_connect(flow, code: code) }

      expect(output).to include("result=unverifiable reason=transient")
      expect(output).not_to include("fake error")
    end

    it "ログインしていない拒否: アカウント識別子の代わりに none" do
      output = capture_logs { complete_connect(flow, code: code, user: nil) }

      expect(output).to include("[youtube_connect] failed user_id=none result=unverifiable reason=not_logged_in")
    end

    it "inspect・to_s・pretty_inspect: 完了の結果に、トークンが無い（結果の符号と理由だけ）" do
      completion = complete_connect(flow, code: code)

      expect(completion.to_h.keys).to eq(%i[ result reason ])
    end
  end

  describe "引数の検査（呼び出しの誤りは ArgumentError）" do
    it "now が Time でない・redirect_uri が空" do
      expect { complete_connect(flow, code: code, now: 123) }.to raise_error(ArgumentError, /now/)
      expect do
        service.complete(user: user, payload: flow.payload, code: code, state: flow.started.state, error: nil, redirect_uri: "", now: now)
      end.to raise_error(ArgumentError, /redirect_uri/)
    end

    it "user が保存済みのアカウントでも nil でもない" do
      expect { complete_connect(flow, code: code, user: User.new(google_sub: "x")) }.to raise_error(ArgumentError, /user/)
    end
  end

  # 指定の TokenVault で組み立てたサービス（疑似の Google・疑似の YouTube・チャンネル名のキャッシュは、共通）
  def connect_service_with(vault)
    YouTubeConnectService.new(oidc: fake_oidc, token_vault: vault, youtube_gateway: fake_youtube, channel_names: channel_names)
  end
end
