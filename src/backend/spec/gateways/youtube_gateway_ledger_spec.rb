require "rails_helper"
require "support/youtube_gateway_support"

# 窓口の台帳への記帳と、呼び出しの前処理の順序（issue #10。requirements.md 8.4・10.4・10.5・14 章・27 章）。
#   - 呼び出しのたびに、実費を台帳へ記帳する（配信に属する呼び出しは配信の予約の枠から、属さない呼び出しは共通枠から）
#   - 枠が足りなければ、HTTP を呼ばずに QuotaInsufficient。終了・清算枠は、準備の支出で取り崩さない
#   - 割り当て超過（quotaExceeded・dailyLimitExceeded）が返れば、台帳に超過の印を付ける（呼び出しの時刻の割り当て日）
#   - アクセストークンの取得 -> 記帳 -> HTTP の順。トークンの取得に失敗したら、記帳しない（YouTube を呼んでいない）
#   - 記帳は、HTTP の前に、独立した短いトランザクションで確定させる。呼び出し側のトランザクションの内側では呼べない（InsideTransaction）
#     （内側で呼ぶと、HTTP が失敗して巻き戻ったときに、YouTube で消費済みの実費の記帳まで消える。台帳の行ロックを、HTTP の待ちのあいだ持ち続けることにもなる）
#   - HTTP が失敗（4xx・5xx・タイムアウト）でも、実費を記帳する。記帳は呼び出しの前に行うので、明細の result は ok 固定
# 台帳の行が、コミットされること（別の接続から見える・行ロックを持たない）は youtube_gateway_commit_spec.rb。
RSpec.describe YouTubeGateway do
  include LedgerSupport
  include YouTubeGatewaySupport
  include LogCapture

  let(:day) { quota_day(0) }
  let(:now) { noon_of(day) }
  let(:user) { create(:user) }
  let(:connection) { create(:youtube_connection, user: user) }
  let(:broadcast) { create_reserved_broadcast(quota_date: day, user: user) }
  let(:vault) { token_vault_double }
  let(:gateway) { build_gateway(vault: vault, now: now) }

  before do
    connection
    broadcast
  end

  def stub_any_youtube(response)
    stub_request(:any, %r{\Ahttps://www\.googleapis\.com/youtube/v3/}).to_return(response)
  end

  def fetch_status(bucket: :prep, target: gateway)
    target.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: bucket)
  end

  # 準備・確認枠・終了・清算枠・共通枠を、台帳（QuotaLedger）から直接使い切る補助
  def drain_prep!(remaining = 340)
    QuotaLedger.spend!(broadcast, method: "liveBroadcasts.list", units: remaining, bucket: :prep, result: "ok", now: now)
  end

  describe "記帳の単価と枠（呼び出しごと）" do
    it "9 つの公開メソッドのすべてが、台帳へ記帳する: 種別・単価・枠・結果 ok" do
      stub_request(:post, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(json_response(broadcast_resource))
      stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(list_response(broadcast_resource(life_cycle_status: "live")))
      stub_request(:post, api_url("liveStreams")).with(query: hash_including({})).to_return(json_response(stream_resource))
      stub_request(:post, api_url("liveBroadcasts/bind")).with(query: hash_including({})).to_return(json_response(broadcast_resource))
      stub_request(:get, api_url("liveStreams")).with(query: hash_including({})).to_return(list_response(stream_resource))
      stub_request(:post, api_url("liveBroadcasts/transition")).with(query: hash_including({})).to_return(json_response(broadcast_resource))
      stub_request(:delete, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(status: 204)
      stub_request(:get, api_url("channels")).with(query: hash_including({})).to_return(list_response(channel_resource))

      gateway.insert_broadcast(connection, { title: title_value, privacy_status: "unlisted", made_for_kids: false, scheduled_start_time: now + 60 }, broadcast: broadcast)
      gateway.list_unstarted_broadcasts(connection, broadcast: broadcast)
      gateway.ensure_stream(connection, broadcast: broadcast)
      gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast)
      gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep)
      gateway.fetch_stream_health(connection, youtube_stream_id, broadcast: broadcast)
      gateway.complete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle)
      gateway.delete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle)
      gateway.probe_channel(connection)

      expect(ledger_entries).to eq(
        [
          [ "liveBroadcasts.insert", 50, "prep", "ok" ],
          [ "liveBroadcasts.list", 1, "prep", "ok" ],
          [ "liveStreams.insert", 50, "prep", "ok" ],
          [ "liveBroadcasts.bind", 50, "prep", "ok" ],
          [ "liveBroadcasts.list", 1, "prep", "ok" ],
          [ "liveStreams.list", 1, "prep", "ok" ],
          [ "liveBroadcasts.transition", 50, "settle", "ok" ],
          [ "liveBroadcasts.delete", 50, "settle", "ok" ],
          [ "channels.list", 1, "common", "ok" ],
          [ "liveBroadcasts.list", 1, "common", "ok" ]
        ]
      )
    end

    it "使用済み・予約中・配信の枠の残額が、記帳した額だけ動く（配信の使用済み 201 = 準備・確認枠 101 + 終了・清算枠 100。共通枠は別に 2）" do
      stub_any_youtube(json_response(broadcast_resource))
      stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including("part" => "id,status")).to_return(list_response(broadcast_resource(life_cycle_status: "live")))
      stub_request(:get, api_url("channels")).with(query: hash_including({})).to_return(list_response(channel_resource))
      stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including("mine" => "true")).to_return(list_response)

      gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast)
      gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast)
      gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep)
      gateway.complete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle)
      gateway.complete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle)
      gateway.probe_channel(connection)

      expect(QuotaDay.find(day)).to have_attributes(used_units: 201, reserved_units: 349, common_used_units: 2)
      expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 239, settle_reserved_units: 110)
      expect_whole_ledger_consistent
    end

    it "明細の時刻は、窓口の時計の now。メモリ上の配信の枠にも、残額が反映される" do
      stub_any_youtube(json_response(broadcast_resource))

      gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast)

      expect(QuotaEntry.first.called_at).to eq(now)
      expect(broadcast).to have_attributes(prep_reserved_units: 290)
    end

    it "明細には、トークン・配信キー・タイトル・チャンネル名・配信の識別子を残さない（呼び出しの種別と数だけ）" do
      stub_any_youtube(json_response(broadcast_resource))

      gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast)

      dump = QuotaEntry.all.map { |entry| entry.attributes.values.map(&:to_s).join(" ") }.join(" ")
      [ access_token_value, stream_key_value, title_value, channel_title_value, youtube_broadcast_id, youtube_stream_id ].each do |secret|
        expect(dump).not_to include(secret)
      end
    end
  end

  describe "HTTP が失敗しても、実費を記帳する（記帳は呼び出しの前。結果は ok 固定）" do
    [ [ 400, "invalidRequest" ], [ 403, "liveStreamingNotEnabled" ], [ 404, "liveBroadcastNotFound" ], [ 500, "backendError" ], [ 503, "backendError" ] ].each do |status, reason|
      it "HTTP #{status}（#{reason}）でも、50 ユニットを記帳済み" do
        stub_any_youtube(error_response(status, reason))

        expect { gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::Base)

        expect(ledger_entries).to eq([ [ "liveBroadcasts.bind", 50, "prep", "ok" ] ])
        expect(QuotaDay.find(day).used_units).to eq(50)
      end
    end

    it "タイムアウト・接続の失敗でも、記帳済み。再送しない（要求は 1 回）" do
      request = stub_request(:post, api_url("liveBroadcasts/bind")).with(query: hash_including({})).to_timeout

      expect { gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::Timeout)

      expect(request).to have_been_requested.once
      expect(ledger_entries).to eq([ [ "liveBroadcasts.bind", 50, "prep", "ok" ] ])
    end

    it "応答の本文が壊れていても（JSON でない・壊れた gzip）、記帳済み" do
      stub_request(:post, api_url("liveBroadcasts/bind")).with(query: hash_including({})).to_return(status: 200, body: "not json")
      expect { gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::UnexpectedResponse)

      stub_request(:post, api_url("liveBroadcasts/bind")).with(query: hash_including({})).to_raise(Zlib::DataError)
      expect { gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::UnexpectedResponse) { |error|
        expect(error.detail).to eq(:invalid_encoding)
      }

      expect(QuotaEntry.count).to eq(2)
    end
  end

  describe "枠が足りないとき（HTTP を呼ばずに QuotaInsufficient）" do
    it "準備・確認枠が足りない: QuotaInsufficient（枠 prep・呼び出しの種別）。YouTube を呼ばず、台帳を変えない" do
      drain_prep!
      before_entries = ledger_entries

      expect { gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::QuotaInsufficient) { |error|
        expect(error).to have_attributes(bucket: :prep, call_kind: :bind, status: nil)
        expect(error.disposition.end_reason).to eq("prepare_failed")
      }

      expect_no_youtube_request
      expect(ledger_entries).to eq(before_entries)
      expect(QuotaDay.find(day).used_units).to eq(340)
    end

    it "境界: 残額 49 では 50 ユニットの呼び出しを断り、1 ユニットの呼び出しは通す" do
      drain_prep!(340 - 49)
      stub_request(:post, api_url("liveBroadcasts/bind")).with(query: hash_including({})).to_return(json_response(broadcast_resource))
      stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(list_response(broadcast_resource(life_cycle_status: "live")))

      expect { gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::QuotaInsufficient)
      expect(fetch_status).to be_live
      expect(Broadcast.find(broadcast.id).prep_reserved_units).to eq(48)
    end

    it "境界: 残額がちょうど 50 なら、50 ユニットの呼び出しが通り、残額は 0 になる。そのあとの呼び出しは断られる" do
      drain_prep!(340 - 50)
      stub_request(:post, api_url("liveBroadcasts/bind")).with(query: hash_including({})).to_return(json_response(broadcast_resource))

      expect(gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast)).to be(true)
      expect(Broadcast.find(broadcast.id).prep_reserved_units).to eq(0)
      expect { fetch_status }.to raise_error(YouTubeErrors::QuotaInsufficient)
    end

    it "準備・確認枠を使い切っても、終了・清算枠は使える（準備の支出が、終了と清算に必要な支出を不足させない。8.4）" do
      drain_prep!
      stub_request(:post, api_url("liveBroadcasts/transition")).with(query: hash_including({})).to_return(json_response(broadcast_resource))
      stub_request(:delete, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(status: 204)

      expect { gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::QuotaInsufficient)
      expect(gateway.complete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle)).to be(true)
      expect(gateway.delete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle)).to be(true)

      expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 0, settle_reserved_units: 110)
    end

    it "終了・清算枠が足りない: settle の呼び出しは QuotaInsufficient（枠 settle）。準備・確認枠からは取り崩さない" do
      QuotaLedger.spend!(broadcast, method: "liveBroadcasts.transition", units: 210, bucket: :settle, result: "ok", now: now)

      expect { gateway.complete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle) }.to raise_error(YouTubeErrors::QuotaInsufficient) { |error|
        expect(error.bucket).to eq(:settle)
      }
      expect_no_youtube_request
      expect(Broadcast.find(broadcast.id).prep_reserved_units).to eq(340)
    end

    it "先行配信の清算（10.5）は、準備・確認枠から。準備・確認枠が足りなければ断られる（終了・清算枠が残っていても）" do
      drain_prep!

      expect { gateway.complete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep) }.to raise_error(YouTubeErrors::QuotaInsufficient) { |error|
        expect(error.bucket).to eq(:prep)
      }
      expect(Broadcast.find(broadcast.id).settle_reserved_units).to eq(210)
    end

    it "共通枠が足りない: probe_channel は QuotaInsufficient（枠 common）。YouTube を呼ばない" do
      QuotaLedger.spend_common!(method: "channels.list", units: 500, quota_date: day, now: now)

      expect { gateway.probe_channel(connection) }.to raise_error(YouTubeErrors::QuotaInsufficient) { |error|
        expect(error).to have_attributes(bucket: :common, call_kind: :probe_channel_lookup)
      }
      expect_no_youtube_request
    end

    it "共通枠が、チャンネルの確認と配信の確認のあいだで尽きたら、2 つ目で QuotaInsufficient（1 つ目の記帳は残る）" do
      QuotaLedger.spend_common!(method: "channels.list", units: 499, quota_date: day, now: now)
      stub_request(:get, api_url("channels")).with(query: hash_including({})).to_return(list_response(channel_resource))

      expect { gateway.probe_channel(connection) }.to raise_error(YouTubeErrors::QuotaInsufficient) { |error|
        expect(error.call_kind).to eq(:probe_live_enabled)
      }
      expect(QuotaDay.find(day).common_used_units).to eq(500)
    end

    it "配信の予約が無い（予約前・解放済み）なら断る。共通枠には、取り崩さない" do
      broadcast.update_columns(prep_reserved_units: 0, settle_reserved_units: 0)

      expect { fetch_status }.to raise_error(YouTubeErrors::QuotaInsufficient)
      expect_no_youtube_request
    end

    it "断ったことをログに残す（台帳の拒否のログ）。タイトル・トークンは出さない" do
      drain_prep!

      output = capture_logs do
        gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast)
      rescue YouTubeErrors::QuotaInsufficient
        nil
      end

      expect(output).to include("quota_ledger refused operation=spend")
      expect(output).not_to include(access_token_value)
    end
  end

  describe "割り当て超過（quotaExceeded）が返ったとき" do
    %w[ quotaExceeded dailyLimitExceeded ].each do |reason|
      it "#{reason}: 台帳に超過の印を付け（呼び出しの時刻の割り当て日）、QuotaExceeded を投げる。実費は記帳済み" do
        stub_any_youtube(error_response(403, reason))

        expect { gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::QuotaExceeded)

        expect(QuotaDay.find(day).exhausted).to be(true)
        expect(ledger_entries).to eq([ [ "liveBroadcasts.bind", 50, "prep", "ok" ] ])
      end
    end

    it "超過の印がある日は、新しい配信の予約を受け付けない（8.4）。進行中の配信の記帳は続けられる" do
      stub_any_youtube(error_response(403, "quotaExceeded"))
      expect { gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::QuotaExceeded)

      another = create_bare_broadcast(quota_date: day)
      expect(QuotaLedger.reserve!(another, quota_date: day, daily_total: 10_000)).to be(false)

      stub_any_youtube(json_response(broadcast_resource))
      expect(gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast)).to be(true)
    end

    it "rateLimitExceeded（要求が多すぎる）は、超過の印を付けない（RateLimited）" do
      stub_any_youtube(error_response(403, "rateLimitExceeded"))

      expect { gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::RateLimited)

      expect(QuotaDay.find(day).exhausted).to be(false)
    end

    it "割り当て日をまたいだ呼び出しは、呼び出しの時刻の割り当て日に印を付ける（予約は、新しい割り当て日へ移る）" do
      next_day_now = noon_of(quota_day(1))
      next_day_gateway = build_gateway(vault: vault, now: next_day_now)
      stub_any_youtube(error_response(403, "quotaExceeded"))

      expect { next_day_gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::QuotaExceeded)

      expect(QuotaDay.find(quota_day(1)).exhausted).to be(true)
      expect(QuotaDay.find(day).exhausted).to be(false)
      expect(Broadcast.find(broadcast.id).quota_date).to eq(quota_day(1))
    end

    it "割り当て日は太平洋時間で決める（UTC の日付ではない）: UTC 03:00 は、太平洋時間（夏時間）の前日 20:00。記帳も超過の印も、前日の割り当て日に付く" do
      late = Time.utc(2026, 10, 8, 3, 0, 0)
      late_gateway = build_gateway(vault: vault, now: late)
      stub_any_youtube(error_response(403, "quotaExceeded"))

      expect(UsageCalendar.quota_date(late)).to eq(Date.new(2026, 10, 7))
      expect(late.utc.to_date).to eq(Date.new(2026, 10, 8))
      expect { late_gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::QuotaExceeded)
      expect { late_gateway.probe_channel(connection) }.to raise_error(YouTubeErrors::QuotaExceeded)

      expect(QuotaDay.find(Date.new(2026, 10, 7))).to have_attributes(exhausted: true, used_units: 50, common_used_units: 1)
      expect(QuotaDay.where(quota_date: Date.new(2026, 10, 8))).to be_empty
    end

    it "共通枠の呼び出し（probe_channel）で割り当て超過が返っても、印を付ける" do
      stub_any_youtube(error_response(403, "quotaExceeded"))

      expect { gateway.probe_channel(connection) }.to raise_error(YouTubeErrors::QuotaExceeded)

      expect(QuotaDay.find(day).exhausted).to be(true)
      expect(QuotaDay.find(day).common_used_units).to eq(1)
    end
  end

  describe "アクセストークンの取得との順序（取得 -> 記帳 -> HTTP）" do
    [
      YouTubeErrors::TokenRevoked.new(call_kind: :token_refresh, status: 400, reason: "invalid_grant"),
      YouTubeErrors::TokenTemporarilyUnavailable.new(call_kind: :token_refresh, status: 503),
      YouTubeErrors::UnexpectedResponse.new(call_kind: :token_refresh, status: 401),
      TokenVault::NotConnected.new(user_id: "7f2b8c1e-0000-4000-8000-000000000001"),
      TokenVault::Undecryptable.new(user_id: "7f2b8c1e-0000-4000-8000-000000000001")
    ].each do |failure|
      it "トークンの取得が #{failure.class.name} で失敗したら、そのまま伝え、記帳せず、YouTube を呼ばない（呼んでいないので、実費は無い）" do
        allow(vault).to receive(:access_token).and_raise(failure)

        expect { gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(failure.class)

        expect(QuotaEntry.count).to eq(0)
        expect(Broadcast.find(broadcast.id).prep_reserved_units).to eq(340)
        expect_no_youtube_request
      end
    end

    it "実物の TokenVault（疑似の Google）と組み合わせる: 認可失効の接続は TokenRevoked で、記帳しない" do
      fake_client = FakeGoogleTokenClient.new(environment: AppEnvironment.new("test"))
      real_vault = TokenVault.new(key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", token_client: fake_client, cache: TokenVault::AccessTokenCache.new)
      real_vault.store(user_id: user.id, refresh_token: "1//dummy-refresh-token", now: now)
      YoutubeConnection.where(user_id: user.id).update_all(state: "revoked")
      real_gateway = build_gateway(vault: real_vault, now: now)

      expect { real_gateway.bind(YoutubeConnection.find_by!(user_id: user.id), youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }
        .to raise_error(YouTubeErrors::TokenRevoked)

      expect(QuotaEntry.count).to eq(0)
      expect_no_youtube_request
    end

    it "トークンの取得は、窓口の時計の now とアカウントの識別子で呼ぶ。記帳の時刻と同じ now" do
      stub_any_youtube(json_response(broadcast_resource))
      expect(vault).to receive(:access_token).with(user_id: user.id, now: now).and_return(access_token_value)

      gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast)

      expect(QuotaEntry.first.called_at).to eq(now)
    end

    it "YouTube が 401（トークンの拒否）を返したら、メモリ上のアクセストークンを捨てる。次の呼び出しで取得し直す" do
      stub_any_youtube(json_response({ "error" => { "code" => 401, "errors" => [ { "reason" => "authError", "domain" => "global" } ] } }, status: 401))
      expect(vault).to receive(:forget_access_token).with(user_id: user.id)

      expect { gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::UnexpectedResponse) { |error|
        expect(error.status).to eq(401)
      }
    end

    it "401 以外では、捨てない" do
      stub_any_youtube(error_response(503, "backendError"))
      expect(vault).not_to receive(:forget_access_token)

      expect { gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::Transient)
    end
  end

  describe "トランザクションの外で呼ぶ（記帳を、独立した短いトランザクションで確定させるため）" do
    it "呼び出し側のトランザクションの内側では、InsideTransaction。YouTube を呼ばず、記帳もしない" do
      ApplicationRecord.transaction do
        expect { fetch_status }.to raise_error(YouTubeGateway::InsideTransaction, /fetch_status/)
      end

      expect_no_youtube_request
      expect(QuotaEntry.count).to eq(0)
    end

    it "入れ子のトランザクション（requires_new）の内側でも InsideTransaction" do
      ApplicationRecord.transaction do
        ApplicationRecord.transaction(requires_new: true) do
          expect { fetch_status }.to raise_error(YouTubeGateway::InsideTransaction)
        end
      end
    end

    it "probe_channel を含む、すべての公開メソッドが同じ（トランザクションの内側では呼べない）" do
      ApplicationRecord.transaction do
        expect { gateway.probe_channel(connection) }.to raise_error(YouTubeGateway::InsideTransaction)
        expect { gateway.ensure_stream(connection, broadcast: broadcast) }.to raise_error(YouTubeGateway::InsideTransaction)
        expect { gateway.list_unstarted_broadcasts(connection, broadcast: broadcast) }.to raise_error(YouTubeGateway::InsideTransaction)
      end
    end

    it "トランザクションの外では呼べる（テストの外側のトランザクションは、参加できない（joinable でない）ので、内側とみなさない）" do
      stub_any_youtube(list_response(broadcast_resource(life_cycle_status: "live")))

      expect(fetch_status).to be_live
    end

    it "InsideTransaction のメッセージは、呼び出しの種別だけ" do
      ApplicationRecord.transaction do
        expect { fetch_status }.to raise_error(YouTubeGateway::InsideTransaction) { |error|
          expect(error.message).to eq("youtube gateway call fetch_status must be made outside of a database transaction")
        }
      end
    end
  end

  describe "アカウントの一致（他のアカウントの配信へ、記帳・操作しない）" do
    it "接続と配信のアカウントが違えば ArgumentError。YouTube を呼ばず、記帳しない" do
      other_user = create(:user)
      other_connection = create(:youtube_connection, user: other_user)

      expect { gateway.fetch_status(other_connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep) }.to raise_error(ArgumentError, /account/)

      expect(QuotaEntry.count).to eq(0)
      expect_no_youtube_request
    end

    it "接続・配信が保存されていない、または型が違うなら ArgumentError" do
      expect { gateway.fetch_status(build(:youtube_connection, user: user), youtube_broadcast_id, broadcast: broadcast, bucket: :prep) }.to raise_error(ArgumentError, /connection/)
      expect { gateway.fetch_status(nil, youtube_broadcast_id, broadcast: broadcast, bucket: :prep) }.to raise_error(ArgumentError, /connection/)
      expect { gateway.fetch_status(connection, youtube_broadcast_id, broadcast: build(:broadcast, user: user), bucket: :prep) }.to raise_error(ArgumentError, /broadcast/)
      expect { gateway.fetch_status(connection, youtube_broadcast_id, broadcast: nil, bucket: :prep) }.to raise_error(ArgumentError, /broadcast/)
      expect_no_youtube_request
    end
  end

  describe "ログ（機密を出さない）" do
    it "失敗は、呼び出しの種別・配信レコードの識別子・アカウントの内部の識別子・ステータス・reason の符号を出す。トークン・タイトル・配信キー・応答の message を出さない" do
      stub_any_youtube(error_response(403, "liveStreamingNotEnabled", message: "dummy-title-must-not-appear dummy-stream-key-must-not-appear"))
      error = nil

      output = capture_logs do
        error = begin
          gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast)
        rescue YouTubeErrors::LiveNotEnabled => e
          e
        end
      end

      expect(output).to include("[youtube_gateway] failed call=bind", "broadcast_id=#{broadcast.id}", "user_id=#{user.id}", "status=403", "reason=liveStreamingNotEnabled")
      [ access_token_value, stream_key_value, title_value, youtube_broadcast_id, youtube_stream_id ].each { |secret| expect(output).not_to include(secret) }
      [ error.message, error.inspect, error.full_message ].each { |text| expect(text).not_to include("dummy-title-must-not-appear") }
    end
  end
end
