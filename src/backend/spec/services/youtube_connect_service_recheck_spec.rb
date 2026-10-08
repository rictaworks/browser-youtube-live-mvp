require "rails_helper"
require "support/youtube_connect_support"

# YouTube 接続の再確認 YouTubeConnectService#recheck と、チャンネル名の取得 #channel_title（issue #11。requirements.md 7.2・7.3・8.4・25.4・28.2。
# src/contracts/http-api.md 3 章 recheck・2.3 channel_title）。
#   再確認: 接続済み・ライブ未有効のとき、チャンネルとライブの有効を再確認し（各 1 ユニットの一覧取得。共通枠から支出）、connected と live_not_enabled を更新する。
#           接続が無ければ not_connected。認可失効（revoked）は、再確認せず、そのまま返す。
#           トークンの更新が恒久的に失敗した・権限が不足していれば、認可失効にする。確認不能（共通枠の枯渇・一時的な失敗・チャンネルが見つからない）は、状態を変えない。
#   チャンネル名: 最長 10 分のメモリのキャッシュ。キャッシュがあれば再取得しない（共通枠を消費しない）。取得に失敗しても例外にせず nil（失敗を記録する）。状態を変えない。
RSpec.describe YouTubeConnectService, "#recheck・#channel_title" do
  include LedgerSupport
  include YouTubeConnectSupport
  include ActiveSupport::Testing::TimeHelpers
  include_context "YouTube 接続の環境"

  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:user) { create(:user, google_sub: "dev-user-1") }
  let(:service) { connect_service }

  before { travel_to(now) }
  after { travel_back }

  # 実際に保存した接続（暗号化した更新トークン。アクセストークンを取得できる）。state を指定すると、その状態にする
  def store_connection(account = user, state: "connected", at: now - 2.days)
    connection = token_vault.store(user_id: account.id, refresh_token: "1//dummy-refresh-token-#{SecureRandom.hex(4)}", now: at)
    connection.update!(state: state) unless state == "connected"
    connection.reload
  end

  def state_of(account = user)
    YoutubeConnection.owned_by(account).take&.state
  end

  def common_entries
    QuotaEntry.where(bucket: "common").map { |entry| [ entry.method, entry.units ] }
  end

  describe "#recheck" do
    describe "接続が無い・認可失効" do
      it "接続が無い: not_connected。外部を呼ばない・台帳に記帳しない" do
        allow(fake_youtube).to receive(:probe_channel).and_call_original

        outcome = service.recheck(user: user, now: now)

        expect(outcome).to have_attributes(outcome: :not_connected, state: "not_connected")
        expect(outcome).to be_not_connected
        expect(fake_youtube).not_to have_received(:probe_channel)
        expect(QuotaEntry.count).to eq(0)
      end

      it "認可失効（revoked）: 再確認せず、revoked を返す（再接続を促す）。外部を呼ばない・台帳に記帳しない・状態を変えない" do
        connection = store_connection(state: "revoked")
        allow(fake_youtube).to receive(:probe_channel).and_call_original

        outcome = service.recheck(user: user, now: now)

        expect(outcome).to have_attributes(outcome: :checked, state: "revoked")
        expect(outcome).to be_checked
        expect(fake_youtube).not_to have_received(:probe_channel)
        expect(QuotaEntry.count).to eq(0)
        expect(connection.reload.last_verified_at).to eq(now - 2.days)
      end
    end

    describe "状態の更新（接続済み ⇄ ライブ未有効）" do
      it "接続済みのまま: ライブ配信が有効。確認の時刻を更新する。共通枠から 2 ユニット" do
        connection = store_connection(state: "connected")

        outcome = service.recheck(user: user, now: now)

        expect(outcome).to have_attributes(outcome: :checked, state: "connected")
        expect(connection.reload).to have_attributes(state: "connected", last_verified_at: now)
        expect(common_entries).to contain_exactly([ "channels.list", 1 ], [ "liveBroadcasts.list", 1 ])
      end

      it "ライブ未有効 -> 接続済み（再確認でライブ有効）" do
        connection = store_connection(state: "live_not_enabled")

        outcome = service.recheck(user: user, now: now)

        expect(outcome).to have_attributes(outcome: :checked, state: "connected")
        expect(connection.reload).to have_attributes(state: "connected", last_verified_at: now)
      end

      it "接続済み -> ライブ未有効（再確認でライブ未有効・制限中）" do
        connection = store_connection(state: "connected")
        fake_youtube.fail_next(:live_not_enabled, on: :probe_live_enabled)

        outcome = service.recheck(user: user, now: now)

        expect(outcome).to have_attributes(outcome: :checked, state: "live_not_enabled")
        expect(connection.reload).to have_attributes(state: "live_not_enabled", last_verified_at: now)
      end

      it "ライブ未有効のまま: ライブ配信がまだ有効でない" do
        connection = store_connection(state: "live_not_enabled")
        fake_youtube.fail_next(:live_not_enabled, on: :probe_live_enabled)

        expect(service.recheck(user: user, now: now)).to have_attributes(outcome: :checked, state: "live_not_enabled")
        expect(connection.reload.last_verified_at).to eq(now)
      end

      it "ライブ配信が制限されている（livePermissionBlocked）も、ライブ未有効（制限中）" do
        store_connection(state: "connected")
        fake_youtube.fail_next(:live_streaming_restricted, on: :probe_live_enabled)

        expect(service.recheck(user: user, now: now)).to have_attributes(state: "live_not_enabled")
      end

      it "チャンネルの一覧取得の側で、チャンネルの閉鎖・停止が返ったときは、disposition の接続状態（ライブ未有効・制限中）に従う" do
        store_connection(state: "connected")
        fake_youtube.fail_next(:live_streaming_restricted, on: :probe_channel_lookup)

        expect(service.recheck(user: user, now: now)).to have_attributes(outcome: :checked, state: "live_not_enabled")
        expect(state_of).to eq("live_not_enabled")
      end

      it "窓口（YouTube の確認）は、トランザクションの外で呼ぶ" do
        store_connection(state: "connected")
        inside = []
        allow(fake_youtube).to receive(:probe_channel).and_wrap_original do |original, *args, **options|
          inside << ApplicationRecord.with_connection { |connection| connection.current_transaction.joinable? }
          original.call(*args, **options)
        end

        service.recheck(user: user, now: now)
        service.channel_title(create(:user).tap { |other| store_connection(other, state: "connected") })

        expect(inside).to eq([ false, false ])
      end

      it "成功したとき、チャンネル名をメモリに置く（応答には含めない。次の状態の取得が、共通枠を消費しない）" do
        store_connection(state: "connected")

        service.recheck(user: user, now: now)

        expect(channel_names.cached(user.id)).to eq("Fake Channel")
      end

      it "ライブ未有効（チャンネルの閉鎖）でチャンネル名が分からないとき、前のチャンネル名を残さない" do
        store_connection(state: "connected")
        channel_names.write(user.id, "dummy-previous-channel-title")
        fake_youtube.fail_next(:live_streaming_restricted, on: :probe_channel_lookup)

        service.recheck(user: user, now: now)

        expect(channel_names.cached(user.id)).to be_nil
      end

      it "配信用ストリームの識別子・暗号文は変えない（再接続ではない）" do
        connection = store_connection(state: "live_not_enabled")
        connection.update!(youtube_stream_id: "dummy-stream-id-0001", stream_verified_at: now - 1.day)
        ciphertext = connection.reload.refresh_token_ciphertext

        service.recheck(user: user, now: now)

        expect(connection.reload).to have_attributes(youtube_stream_id: "dummy-stream-id-0001", refresh_token_ciphertext: ciphertext)
      end
    end

    describe "認可失効にする（接続済み・ライブ未有効 -> 認可失効）" do
      %w[ connected live_not_enabled ].each do |from|
        it "#{from} -> 認可失効: トークンの更新が恒久的に失敗した（invalid_grant・取り消し）。外部の呼び出しまで進まない" do
          store_connection(state: from)
          fake_youtube.fail_next(:token_revoked)

          outcome = service.recheck(user: user, now: now)

          expect(outcome).to have_attributes(outcome: :checked, state: "revoked")
          expect(state_of).to eq("revoked")
          expect(QuotaEntry.count).to eq(0) # アクセストークンを得られず、YouTube を呼んでいない（記帳しない）
        end

        it "#{from} -> 認可失効: 権限が不足している（insufficientPermissions）" do
          store_connection(state: from)
          fake_youtube.fail_next(:insufficient_permissions, on: :probe_channel_lookup)

          expect(service.recheck(user: user, now: now)).to have_attributes(outcome: :checked, state: "revoked")
          expect(state_of).to eq("revoked")
        end
      end

      it "認可失効にしたとき、確認の時刻は更新しない" do
        connection = store_connection(state: "connected")
        fake_youtube.fail_next(:insufficient_permissions, on: :probe_channel_lookup)

        service.recheck(user: user, now: now)

        expect(connection.reload.last_verified_at).to eq(now - 2.days)
      end

      it "認可失効にした後の再確認は、再確認せず revoked を返す（トークンの更新を試みない）" do
        store_connection(state: "connected")
        fake_youtube.fail_next(:token_revoked)
        service.recheck(user: user, now: now)
        allow(fake_youtube).to receive(:probe_channel).and_call_original

        expect(service.recheck(user: user, now: now)).to have_attributes(outcome: :checked, state: "revoked")
        expect(fake_youtube).not_to have_received(:probe_channel)
      end
    end

    describe "確認不能（unverifiable）: 状態を変えない" do
      {
        "一時的な失敗" => ->(youtube) { youtube.fail_next(:transient) },
        "タイムアウト" => ->(youtube) { youtube.fail_next(:timeout) },
        "ライブ配信の確認の一時的な失敗" => ->(youtube) { youtube.fail_next(:transient, on: :probe_live_enabled) },
        "割り当て超過（YouTube）" => ->(youtube) { youtube.fail_next(:quota_exceeded) },
        "要求が多すぎる" => ->(youtube) { youtube.fail_next(:rate_limited) },
        "想定外の応答" => ->(youtube) { youtube.fail_next(:unexpected_response) },
        "チャンネルが見つからない" => ->(youtube) { youtube.fail_next(:no_channel) },
        "アクセストークンの更新の一時的な失敗" => ->(youtube) { youtube.fail_next(:token_temporarily_unavailable) }
      }.each do |label, arrange|
        %w[ connected live_not_enabled ].each do |from|
          it "#{label}（#{from}）: unverifiable。状態も確認の時刻も、変えない" do
            connection = store_connection(state: from)
            arrange.call(fake_youtube)

            outcome = service.recheck(user: user, now: now)

            expect(outcome).to have_attributes(outcome: :unverifiable, state: from)
            expect(outcome).to be_unverifiable
            expect(connection.reload).to have_attributes(state: from, last_verified_at: now - 2.days)
          end
        end
      end

      it "共通枠の枯渇: 窓口が YouTube を呼ばず、unverifiable。状態を変えない" do
        connection = store_connection(state: "connected")
        seed_day(UsageCalendar.quota_date(now), common: QuotaPolicy::COMMON_UNITS)

        expect(service.recheck(user: user, now: now)).to have_attributes(outcome: :unverifiable, state: "connected")
        expect(connection.reload).to have_attributes(state: "connected", last_verified_at: now - 2.days)
      end

      it "暗号文を復号できない（鍵の取り違え・破損）: unverifiable。状態を変えない（全員を認可失効にしない）" do
        connection = create(:youtube_connection, user: user, state: "connected", last_verified_at: now - 2.days) # 工場の暗号文は、復号できない

        expect(service.recheck(user: user, now: now)).to have_attributes(outcome: :unverifiable, state: "connected")
        expect(connection.reload.state).to eq("connected")
      end

      it "確認不能のとき、チャンネル名のキャッシュを変えない" do
        store_connection(state: "connected")
        channel_names.write(user.id, "dummy-cached-channel-title")
        fake_youtube.fail_next(:transient)

        service.recheck(user: user, now: now)

        expect(channel_names.cached(user.id)).to eq("dummy-cached-channel-title")
      end
    end

    describe "他のアカウントに影響しない" do
      it "あるアカウントの再確認が、他のアカウントの接続の状態・確認の時刻・チャンネル名を変えない" do
        store_connection(state: "live_not_enabled")
        other = create(:user)
        other_connection = store_connection(other, state: "live_not_enabled")
        channel_names.write(other.id, "dummy-other-channel-title")

        service.recheck(user: user, now: now)

        expect(state_of).to eq("connected")
        expect(other_connection.reload).to have_attributes(state: "live_not_enabled", last_verified_at: now - 2.days)
        expect(channel_names.cached(other.id)).to eq("dummy-other-channel-title")
      end

      it "他のアカウントの接続を、再確認の対象にしない（自分の接続が無ければ not_connected）" do
        store_connection(create(:user), state: "connected")

        expect(service.recheck(user: user, now: now)).to have_attributes(outcome: :not_connected)
      end
    end

    describe "機密" do
      it "DB のどの表にも、アクセストークン・チャンネル名が無い" do
        store_connection(state: "live_not_enabled")

        service.recheck(user: user, now: now)

        expect(database_dump).not_to include("Fake Channel")
        expect(database_dump).not_to include("fake-access-token-")
      end

      it "ログ: 内部のアカウント識別子と結果の符号だけ（トークン・チャンネル名を出さない）" do
        store_connection(state: "live_not_enabled")
        access = token_vault.access_token(user_id: user.id, now: now)

        output = capture_logs { service.recheck(user: user, now: now) }

        expect(output).to include("[youtube_connect] rechecked user_id=#{user.id} state=connected")
        expect(output).not_to include(access)
        expect(output).not_to include("Fake Channel")
      end

      it "ログ（確認不能）: 理由の符号だけ。YouTube の応答の本文を出さない" do
        store_connection(state: "connected")
        fake_youtube.fail_next(:transient)

        output = capture_logs { service.recheck(user: user, now: now) }

        expect(output).to include("[youtube_connect] recheck unverifiable user_id=#{user.id} reason=transient")
        expect(output).not_to include("fake error")
      end
    end

    it "引数の検査: user は保存済みのアカウント・now は Time" do
      expect { service.recheck(user: nil, now: now) }.to raise_error(ArgumentError, /user/)
      expect { service.recheck(user: user, now: 123) }.to raise_error(ArgumentError, /now/)
    end
  end

  describe "接続の状態遷移（25.4）の通し" do
    it "未接続 -> 接続済み -> ライブ未有効 -> 接続済み -> 認可失効 -> （再接続）ライブ未有効 -> 接続済み" do
      expect(state_of).to be_nil # 未接続

      expect(run_connect(user)).to have_attributes(result: "connected")
      expect(state_of).to eq("connected")

      fake_youtube.fail_next(:live_not_enabled, on: :probe_live_enabled)
      expect(service.recheck(user: user, now: now)).to have_attributes(state: "live_not_enabled")
      expect(state_of).to eq("live_not_enabled")

      expect(service.recheck(user: user, now: now)).to have_attributes(state: "connected")
      expect(state_of).to eq("connected")

      fake_youtube.fail_next(:token_revoked)
      expect(service.recheck(user: user, now: now)).to have_attributes(state: "revoked")
      expect(state_of).to eq("revoked")

      fake_youtube.fail_next(:live_not_enabled, on: :probe_live_enabled)
      expect(run_connect(user)).to have_attributes(result: "live_not_enabled")
      expect(state_of).to eq("live_not_enabled")

      expect(service.recheck(user: user, now: now)).to have_attributes(state: "connected")
      expect(state_of).to eq("connected")
    end

    it "未接続 -> ライブ未有効（接続の成立・ライブ未有効）" do
      fake_youtube.fail_next(:live_not_enabled, on: :probe_live_enabled)

      expect(run_connect(user)).to have_attributes(result: "live_not_enabled")
      expect(state_of).to eq("live_not_enabled")
    end

    it "認可失効 -> 接続済み（再接続・ライブ有効）" do
      store_connection(state: "revoked")

      expect(run_connect(user)).to have_attributes(result: "connected")
      expect(state_of).to eq("connected")
    end
  end

  describe "#channel_title（チャンネル名。最長 10 分のメモリのキャッシュ）" do
    it "接続が無ければ nil。外部を呼ばない" do
      allow(fake_youtube).to receive(:probe_channel).and_call_original

      expect(service.channel_title(user)).to be_nil
      expect(fake_youtube).not_to have_received(:probe_channel)
    end

    it "認可失効なら nil。外部を呼ばない" do
      store_connection(state: "revoked")
      allow(fake_youtube).to receive(:probe_channel).and_call_original

      expect(service.channel_title(user)).to be_nil
      expect(fake_youtube).not_to have_received(:probe_channel)
    end

    it "接続済み: チャンネル名を取得して返す。共通枠から 2 ユニット" do
      store_connection(state: "connected")

      expect(service.channel_title(user)).to eq("Fake Channel")
      expect(common_entries).to contain_exactly([ "channels.list", 1 ], [ "liveBroadcasts.list", 1 ])
    end

    it "ライブ未有効でも、チャンネル名を取得できる" do
      store_connection(state: "live_not_enabled")
      fake_youtube.fail_next(:live_not_enabled, on: :probe_live_enabled)

      expect(service.channel_title(user)).to eq("Fake Channel")
    end

    it "キャッシュがあれば、取得しない（再取得を省く = 共通枠を消費しない）" do
      store_connection(state: "connected")
      service.channel_title(user)
      before = QuotaEntry.count
      allow(fake_youtube).to receive(:probe_channel).and_call_original

      5.times { expect(service.channel_title(user)).to eq("Fake Channel") }

      expect(QuotaEntry.count).to eq(before)
      expect(fake_youtube).not_to have_received(:probe_channel)
    end

    it "取得から 10 分で失効する。599 秒後はキャッシュ、600 秒後は取得し直す（共通枠 2 ユニット）" do
      store_connection(state: "connected")
      service.channel_title(user)

      travel_to(now + 599)
      service.channel_title(user)
      expect(QuotaEntry.count).to eq(2)

      travel_to(now + 600)
      expect(service.channel_title(user)).to eq("Fake Channel")
      expect(QuotaEntry.count).to eq(4)
    end

    it "接続の成立でメモリに置いたチャンネル名を、そのまま使う（成立の直後の状態の取得が、共通枠を消費しない）" do
      run_connect(user)
      before = QuotaEntry.count

      expect(service.channel_title(user)).to eq("Fake Channel")
      expect(QuotaEntry.count).to eq(before)
    end

    describe "取得に失敗しても例外にしない（nil。失敗を記録する。キャッシュしない）" do
      {
        "一時的な失敗" => [ ->(youtube) { youtube.fail_next(:transient) }, "transient" ],
        "タイムアウト" => [ ->(youtube) { youtube.fail_next(:timeout) }, "timeout" ],
        "割り当て超過" => [ ->(youtube) { youtube.fail_next(:quota_exceeded) }, "quota_exceeded" ],
        "想定外の応答" => [ ->(youtube) { youtube.fail_next(:unexpected_response) }, "unexpected_response" ],
        "チャンネルが無い" => [ ->(youtube) { youtube.fail_next(:no_channel) }, "channel_not_found" ],
        "アクセストークンの更新の一時的な失敗" => [ ->(youtube) { youtube.fail_next(:token_temporarily_unavailable) }, "token_temporarily_unavailable" ]
      }.each do |label, (arrange, reason)|
        it "#{label}: nil を返し、キャッシュしない（次の呼び出しは取得し直す）。理由を記録する" do
          store_connection(state: "connected")
          arrange.call(fake_youtube)

          output = capture_logs { expect(service.channel_title(user)).to be_nil }

          expect(output).to include("[youtube_connect] channel title unavailable user_id=#{user.id} reason=#{reason}")
          expect(channel_names.cached(user.id)).to be_nil
          expect(service.channel_title(user)).to eq("Fake Channel") # 次は取得し直せる
        end
      end

      it "共通枠の枯渇: nil（YouTube を呼ばない）" do
        store_connection(state: "connected")
        seed_day(UsageCalendar.quota_date(now), common: QuotaPolicy::COMMON_UNITS)

        output = capture_logs { expect(service.channel_title(user)).to be_nil }

        expect(output).to include("reason=quota_insufficient")
      end

      it "暗号文を復号できない: nil。記録する" do
        create(:youtube_connection, user: user, state: "connected")

        output = capture_logs { expect(service.channel_title(user)).to be_nil }

        expect(output).to include("[youtube_connect] channel title unavailable user_id=#{user.id}")
      end

      it "トークンの更新が恒久的に失敗（取り消し）: nil。接続の状態は、窓口（TokenVault）が認可失効にする。次の呼び出しは、外部を呼ばない" do
        store_connection(state: "connected")
        fake_youtube.fail_next(:token_revoked)

        expect(service.channel_title(user)).to be_nil
        expect(state_of).to eq("revoked")

        allow(fake_youtube).to receive(:probe_channel).and_call_original
        expect(service.channel_title(user)).to be_nil
        expect(fake_youtube).not_to have_received(:probe_channel)
      end

      it "失敗の記録に、トークン・チャンネル名・YouTube の応答の本文を出さない" do
        store_connection(state: "connected")
        fake_youtube.fail_next(:transient)

        output = capture_logs { service.channel_title(user) }

        expect(output).not_to include("fake error")
        expect(output).not_to include("Fake Channel")
        expect(output).not_to include("fake-access-token-")
      end
    end

    it "状態を変えない（GET /api/state の副作用なし）: 取得でライブ未有効が分かっても、接続済みのまま" do
      connection = store_connection(state: "connected")
      fake_youtube.fail_next(:live_not_enabled, on: :probe_live_enabled)

      expect(service.channel_title(user)).to eq("Fake Channel")
      expect(connection.reload).to have_attributes(state: "connected", last_verified_at: now - 2.days)
    end

    it "状態を変えない: 権限不足が分かっても、認可失効にしない（再確認の仕事）。nil" do
      connection = store_connection(state: "connected")
      fake_youtube.fail_next(:insufficient_permissions, on: :probe_channel_lookup)

      expect(service.channel_title(user)).to be_nil
      expect(connection.reload.state).to eq("connected")
    end

    it "アカウントごとに分かれている（別のアカウントのキャッシュを返さない・消費しない）" do
      store_connection(state: "connected")
      other = create(:user)
      store_connection(other, state: "connected")
      channel_names.write(other.id, "dummy-other-channel-title")

      expect(service.channel_title(user)).to eq("Fake Channel")
      expect(service.channel_title(other)).to eq("dummy-other-channel-title")
    end

    it "DB のどの表にも、チャンネル名を保存しない" do
      store_connection(state: "connected")

      service.channel_title(user)

      expect(database_dump).not_to include("Fake Channel")
    end

    it "user は保存済みのアカウント" do
      expect { service.channel_title(nil) }.to raise_error(ArgumentError, /user/)
    end
  end
end
