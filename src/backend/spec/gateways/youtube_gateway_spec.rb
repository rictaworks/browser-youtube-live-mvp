require "rails_helper"
require "support/youtube_gateway_support"

# YouTube Data API の単一の窓口（issue #10。requirements.md 6.1・8.4・10.1・10.2・10.3・10.4・24.2）。実物の窓口を、WebMock で検査する。
# 呼び出しの順序・パラメータ（part を含む）・認可ヘッダ・応答の解釈・台帳の単価と枠を確かめる。エラーの分類の全種は youtube_gateway_errors_spec.rb、
# 台帳・トランザクション・トークンの順序は youtube_gateway_ledger_spec.rb。
# 実際の YouTube は呼ばない。応答の形は公式の文書に基づく（実物は未確認。U5）。
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
  let(:auth_headers) { { "Authorization" => "Bearer #{access_token_value}" } }

  before do
    connection
    broadcast
  end

  describe "#insert_broadcast（配信の作成）" do
    let(:scheduled_start) { now + 60 }
    let(:params) { { title: title_value, privacy_status: "unlisted", made_for_kids: false, scheduled_start_time: scheduled_start } }
    # 10.1 の「配信の作成内容」。scheduledEndTime は付けない
    let(:expected_body) do
      {
        "snippet" => { "title" => title_value, "scheduledStartTime" => scheduled_start.utc.iso8601 },
        "status" => { "privacyStatus" => "unlisted", "selfDeclaredMadeForKids" => false },
        "contentDetails" => { "enableAutoStart" => true, "enableAutoStop" => true, "monitorStream" => { "enableMonitorStream" => false } }
      }
    end

    def stub_insert(response = json_response(broadcast_resource))
      stub_request(:post, api_url("liveBroadcasts"))
        .with(query: { "part" => "snippet,contentDetails,status" }, body: expected_body, headers: auth_headers.merge("Content-Type" => "application/json"))
        .to_return(response)
    end

    it "POST liveBroadcasts?part=snippet,contentDetails,status。本文は、10.1 の作成内容だけ（自動開始・自動停止・モニター無効・開始予定時刻）。配信の識別子を返す" do
      stub = stub_insert

      result = gateway.insert_broadcast(connection, params, broadcast: broadcast)

      expect(result).to eq(youtube_broadcast_id)
      expect(stub).to have_been_requested.once
    end

    it "part に contentDetails を含める（含めないと、自動開始・自動停止・モニター無効の指定が捨てられて既定になる。事前確認）" do
      stub = stub_request(:post, api_url("liveBroadcasts")).with(query: hash_including("part" => "snippet,contentDetails,status")).to_return(json_response(broadcast_resource))

      gateway.insert_broadcast(connection, params, broadcast: broadcast)

      expect(stub).to have_been_requested.once
      expect(a_request(:post, api_url("liveBroadcasts")).with(query: { "part" => "snippet,status" })).not_to have_been_made
    end

    it "公開範囲・子ども向けの申告は、受付の入力値のまま送る（公開・限定公開・非公開 × はい・いいえ）" do
      %w[ public unlisted private ].product([ true, false ]).each do |privacy, kids|
        stub = stub_request(:post, api_url("liveBroadcasts"))
               .with(query: { "part" => "snippet,contentDetails,status" },
                     body: hash_including("status" => { "privacyStatus" => privacy, "selfDeclaredMadeForKids" => kids }))
               .to_return(json_response(broadcast_resource))

        gateway.insert_broadcast(connection, params.merge(privacy_status: privacy, made_for_kids: kids), broadcast: broadcast)

        expect(stub).to have_been_requested.once
      end
    end

    it "開始予定時刻は、渡された時刻を UTC の ISO 8601（秒単位）で送る（呼び出し側が作成時点から 1 分後を決め、配信レコードに保存する）" do
      stub = stub_request(:post, api_url("liveBroadcasts"))
             .with(query: { "part" => "snippet,contentDetails,status" }, body: hash_including("snippet" => hash_including("scheduledStartTime" => "2026-10-08T03:01:00Z")))
             .to_return(json_response(broadcast_resource))

      gateway.insert_broadcast(connection, params.merge(scheduled_start_time: Time.new(2026, 10, 8, 12, 1, 0, "+09:00")), broadcast: broadcast)

      expect(stub).to have_been_requested.once
    end

    it "作成時点から 1 分後の時刻を作る補助を持つ（10.1）" do
      expect(described_class::SCHEDULED_START_OFFSET_SECONDS).to eq(60)
      expect(described_class.scheduled_start_time(now)).to eq(now + 60)
      expect { described_class.scheduled_start_time("now") }.to raise_error(ArgumentError, /now/)
    end

    it "台帳へ、配信の作成（50 ユニット）を、準備・確認枠から記帳する" do
      stub_insert

      gateway.insert_broadcast(connection, params, broadcast: broadcast)

      expect(ledger_entries).to eq([ [ "liveBroadcasts.insert", 50, "prep", "ok" ] ])
      expect(QuotaDay.find(day)).to have_attributes(used_units: 50, reserved_units: 500)
      expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 290, settle_reserved_units: 210)
    end

    it "応答に配信の識別子が無い・形が違う: UnexpectedResponse（黙って成功にしない）。台帳には記帳済み" do
      [ [ {}, :missing_id ], [ { "id" => "" }, :missing_id ], [ { "id" => 1 }, :missing_id ], [ { "id" => "has space" }, :invalid_id ], [ [], :unexpected_shape ] ].each do |body, detail|
        stub_request(:post, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(json_response(body))

        expect { gateway.insert_broadcast(connection, params, broadcast: broadcast) }.to raise_error(YouTubeErrors::UnexpectedResponse) { |error|
          expect(error.detail).to eq(detail)
        }
      end
      expect(QuotaEntry.count).to eq(5)
    end

    it "scheduledEndTimeRequired（400）は、準備の失敗（UnexpectedResponse。reason を記録する）。scheduledEndTime は付けない（報告する）" do
      stub_request(:post, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(error_response(400, "scheduledEndTimeRequired"))

      expect { gateway.insert_broadcast(connection, params, broadcast: broadcast) }.to raise_error(YouTubeErrors::UnexpectedResponse) { |error|
        expect(error.reason).to eq("scheduledEndTimeRequired")
        expect(error.disposition.end_reason).to eq("prepare_failed")
      }
    end

    describe "引数の検査（ArgumentError。タイトルをメッセージに出さない・通信しない・記帳しない）" do
      invalid = {
        "タイトルが nil" => { title: nil },
        "タイトルが空" => { title: "" },
        "タイトルが 101 文字" => { title: "a" * 101 },
        "タイトルに <" => { title: "has < bracket" },
        "タイトルに >" => { title: "has > bracket" },
        "タイトルが文字列でない" => { title: 123 },
        "公開範囲が未知" => { privacy_status: "friends" },
        "公開範囲がシンボル" => { privacy_status: :unlisted },
        "子ども向けの申告が nil（未選択）" => { made_for_kids: nil },
        "子ども向けの申告が文字列" => { made_for_kids: "false" },
        "開始予定時刻が文字列" => { scheduled_start_time: "2026-10-08T00:00:00Z" },
        "開始予定時刻が nil" => { scheduled_start_time: nil }
      }
      invalid.each do |label, override|
        it label do
          expect { gateway.insert_broadcast(connection, params.merge(override), broadcast: broadcast) }.to raise_error(ArgumentError) { |error|
            expect(error.message).not_to include(title_value)
            expect(error.message).not_to include("has < bracket")
          }
          expect(QuotaEntry.count).to eq(0)
          expect_no_youtube_request
        end
      end

      it "タイトルは 1〜100 文字を受け付ける（境界）。日本語も可" do
        stub_request(:post, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(json_response(broadcast_resource))

        [ "a", "a" * 100, "ライブ配信 2026-10-08 20:00" ].each do |title|
          expect { gateway.insert_broadcast(connection, params.merge(title: title), broadcast: broadcast) }.not_to raise_error
        end
      end

      it "キーの過不足は ArgumentError（想定外のキーを、そのまま YouTube へ送らない）" do
        expect { gateway.insert_broadcast(connection, params.except(:title), broadcast: broadcast) }.to raise_error(ArgumentError, /title/)
        expect { gateway.insert_broadcast(connection, params.merge(description: "x"), broadcast: broadcast) }.to raise_error(ArgumentError, /description/)
        expect { gateway.insert_broadcast(connection, "params", broadcast: broadcast) }.to raise_error(ArgumentError, /params/)
      end
    end
  end

  describe "#list_unstarted_broadcasts（応答喪失時の引き継ぎ用）" do
    def stub_list(response)
      stub_request(:get, api_url("liveBroadcasts"))
        .with(query: { "part" => "id,snippet,status", "broadcastStatus" => "upcoming", "maxResults" => "50" }, headers: auth_headers)
        .to_return(response)
    end

    it "GET liveBroadcasts?part=id,snippet,status&broadcastStatus=upcoming&maxResults=50。未開始の配信（識別子・タイトル・開始予定時刻）を返す" do
      stub = stub_list(
        list_response(
          broadcast_resource(id: "dummybc0001", title: "dummy-title-a", scheduled_start_time: "2026-10-07T20:01:00Z"),
          broadcast_resource(id: "dummybc0002", title: "dummy-title-b", scheduled_start_time: "2026-10-07T21:30:00.000Z")
        )
      )

      result = gateway.list_unstarted_broadcasts(connection, broadcast: broadcast)

      expect(stub).to have_been_requested.once
      expect(result.map(&:youtube_broadcast_id)).to eq(%w[ dummybc0001 dummybc0002 ])
      expect(result.map(&:title)).to eq(%w[ dummy-title-a dummy-title-b ])
      expect(result.map(&:scheduled_start_time)).to eq([ Time.utc(2026, 10, 7, 20, 1, 0), Time.utc(2026, 10, 7, 21, 30, 0) ])
      expect(result).to all(be_a(UnstartedBroadcast))
    end

    it "タイトルと開始予定時刻が一致するものを、引き継ぎの対象にできる" do
      stub_list(list_response(broadcast_resource(id: "dummybc0001", title: "other", scheduled_start_time: "2026-10-07T20:01:00Z"), broadcast_resource(id: "dummybc0002", title: title_value, scheduled_start_time: "2026-10-07T20:01:00Z")))

      result = gateway.list_unstarted_broadcasts(connection, broadcast: broadcast)

      matched = result.select { |item| item.matches?(title: title_value, scheduled_start_time: Time.utc(2026, 10, 7, 20, 1, 0)) }
      expect(matched.map(&:youtube_broadcast_id)).to eq([ "dummybc0002" ])
    end

    it "未開始の配信が無ければ、空の配列。items が無い応答も、空" do
      stub_list(list_response)
      expect(gateway.list_unstarted_broadcasts(connection, broadcast: broadcast)).to eq([])

      stub_list(json_response({ "kind" => "youtube#liveBroadcastListResponse" }))
      expect(gateway.list_unstarted_broadcasts(connection, broadcast: broadcast)).to eq([])
    end

    it "タイトル・開始予定時刻が応答に無い配信は、何とも一致しない配信として返す。識別子が無い配信・形の違う応答は UnexpectedResponse" do
      stub_list(list_response({ "id" => "dummybc0003" }))
      incomplete = gateway.list_unstarted_broadcasts(connection, broadcast: broadcast).first

      expect(incomplete.matches?(title: title_value, scheduled_start_time: now)).to be(false)

      [ list_response({ "snippet" => {} }), list_response("not-a-hash"), json_response({ "items" => "x" }), json_response([]) ].each do |response|
        stub_list(response)
        expect { gateway.list_unstarted_broadcasts(connection, broadcast: broadcast) }.to raise_error(YouTubeErrors::UnexpectedResponse)
      end
    end

    it "開始予定時刻が不正な形なら UnexpectedResponse" do
      stub_list(list_response(broadcast_resource(scheduled_start_time: "yesterday")))

      expect { gateway.list_unstarted_broadcasts(connection, broadcast: broadcast) }.to raise_error(YouTubeErrors::UnexpectedResponse) { |error|
        expect(error.detail).to eq(:invalid_scheduled_start_time)
      }
    end

    it "台帳へ、一覧取得（1 ユニット）を、準備・確認枠から記帳する" do
      stub_list(list_response)

      gateway.list_unstarted_broadcasts(connection, broadcast: broadcast)

      expect(ledger_entries).to eq([ [ "liveBroadcasts.list", 1, "prep", "ok" ] ])
    end
  end

  describe "#ensure_stream（配信用ストリームの確認と作成）" do
    let(:stored_connection) { create(:youtube_connection, :with_stream, user: create(:user), youtube_stream_id: youtube_stream_id) }
    let(:stream_user_broadcast) { create_reserved_broadcast(quota_date: day, user: stored_connection.user) }
    let(:create_body) do
      {
        "snippet" => { "title" => "Browser Live" },
        "cdn" => { "ingestionType" => "rtmp", "resolution" => "variable", "frameRate" => "variable" },
        "contentDetails" => { "isReusable" => true }
      }
    end

    def stub_stream_create(resource = stream_resource)
      stub_request(:post, api_url("liveStreams"))
        .with(query: { "part" => "snippet,cdn,contentDetails,status" }, body: create_body, headers: auth_headers.merge("Content-Type" => "application/json"))
        .to_return(json_response(resource))
    end

    def stub_stream_check(response)
      stub_request(:get, api_url("liveStreams")).with(query: { "part" => "id,cdn,status", "id" => youtube_stream_id }, headers: auth_headers).to_return(response)
    end

    context "保存した識別子が無いとき" do
      it "ストリームを作成する: POST liveStreams?part=snippet,cdn,contentDetails,status。RTMP・解像度とフレームレートは variable（自動検出）・再利用可能" do
        stub = stub_stream_create

        info = gateway.ensure_stream(connection, broadcast: broadcast)

        expect(stub).to have_been_requested.once
        expect(info).to be_a(StreamInfo)
        expect(info).to have_attributes(stream_id: youtube_stream_id, ingest_url: rtmps_url, stream_key: stream_key_value, created: true)
      end

      it "取り込み先は rtmpsIngestionAddress（平文の ingestionAddress・バックアップは使わない）" do
        stub_stream_create

        info = gateway.ensure_stream(connection, broadcast: broadcast)

        expect(info.ingest_url).to eq("rtmps://a.rtmps.youtube.com:443/live2")
        expect(info.ingest_url).not_to include("rtmp://")
        expect(info.ingest_url).not_to include("backup")
      end

      it "確認の呼び出しはしない（作成の 1 回だけ）。台帳へ、ストリームの作成（50 ユニット）を、準備・確認枠から記帳する" do
        stub_stream_create

        gateway.ensure_stream(connection, broadcast: broadcast)

        expect(ledger_entries).to eq([ [ "liveStreams.insert", 50, "prep", "ok" ] ])
        expect(a_request(:get, api_url("liveStreams"))).not_to have_been_made
      end

      it "接続の行（保存した識別子）を書き換えない（保存は、呼び出し側が行う）" do
        stub_stream_create

        gateway.ensure_stream(connection, broadcast: broadcast)

        expect(YoutubeConnection.find(connection.id)).to have_attributes(youtube_stream_id: nil, stream_verified_at: nil)
        expect(connection.youtube_stream_id).to be_nil
      end
    end

    context "保存した識別子があるとき" do
      it "識別子で確認する: GET liveStreams?part=id,cdn,status&id=<識別子>（1 ユニット）。有効なら作成しない" do
        check = stub_stream_check(list_response(stream_resource))

        info = gateway.ensure_stream(stored_connection, broadcast: stream_user_broadcast)

        expect(check).to have_been_requested.once
        expect(info).to have_attributes(stream_id: youtube_stream_id, ingest_url: rtmps_url, stream_key: stream_key_value, created: false)
        expect(a_request(:post, api_url("liveStreams"))).not_to have_been_made
        expect(ledger_entries).to eq([ [ "liveStreams.list", 1, "prep", "ok" ] ])
      end

      it "チャンネルの既存のストリームを一覧して再利用しない（保存した識別子でのみ確認する。mine での一覧を呼ばない）" do
        stub_stream_check(list_response(stream_resource))

        gateway.ensure_stream(stored_connection, broadcast: stream_user_broadcast)

        expect(a_request(:get, api_url("liveStreams")).with(query: hash_including("mine" => "true"))).not_to have_been_made
        expect(a_request(:get, api_url("liveStreams")).with { |request| request.uri.query_values.key?("id") == false }).not_to have_been_made
      end

      it "存在しない識別子（空の items）は無効: 新しいストリームを作成する（確認 1 + 作成 50 を記帳）" do
        stub_stream_check(list_response)
        create = stub_stream_create(stream_resource(id: "dummy-stream-id-0002"))

        info = gateway.ensure_stream(stored_connection, broadcast: stream_user_broadcast)

        expect(create).to have_been_requested.once
        expect(info).to have_attributes(stream_id: "dummy-stream-id-0002", created: true)
        expect(ledger_entries).to eq([ [ "liveStreams.list", 1, "prep", "ok" ], [ "liveStreams.insert", 50, "prep", "ok" ] ])
      end

      it "存在しない識別子（404 liveStreamNotFound）も無効: 新しいストリームを作成する" do
        stub_stream_check(error_response(404, "liveStreamNotFound"))
        create = stub_stream_create

        info = gateway.ensure_stream(stored_connection, broadcast: stream_user_broadcast)

        expect(create).to have_been_requested.once
        expect(info.created).to be(true)
      end

      it "存在しない識別子（理由の符号が無い 404）も無効: 新しいストリームを作成する" do
        stub_stream_check(json_response({}, status: 404))
        create = stub_stream_create

        gateway.ensure_stream(stored_connection, broadcast: stream_user_broadcast)

        expect(create).to have_been_requested.once
      end

      it "確認の失敗が一時的な失敗（Transient・Timeout）なら、作成へ進まず、そのまま伝える（無効と取り違えて、ストリームを増やさない）" do
        stub_stream_check(error_response(503, "backendError"))

        expect { gateway.ensure_stream(stored_connection, broadcast: stream_user_broadcast) }.to raise_error(YouTubeErrors::Transient)
        expect(a_request(:post, api_url("liveStreams"))).not_to have_been_made
      end

      it "確認で権限の不足・ライブ未有効が返れば、作成へ進まず、そのまま伝える" do
        stub_stream_check(error_response(403, "liveStreamingNotEnabled"))

        expect { gateway.ensure_stream(stored_connection, broadcast: stream_user_broadcast) }.to raise_error(YouTubeErrors::LiveNotEnabled)
        expect(a_request(:post, api_url("liveStreams"))).not_to have_been_made
      end

      it "応答のストリームの識別子が、要求した識別子と違えば UnexpectedResponse（他のストリームの接続情報を返さない）" do
        stub_stream_check(list_response(stream_resource(id: "dummy-stream-id-other")))

        expect { gateway.ensure_stream(stored_connection, broadcast: stream_user_broadcast) }.to raise_error(YouTubeErrors::UnexpectedResponse) { |error|
          expect(error.detail).to eq(:id_mismatch)
        }
      end
    end

    describe "取り込み先の検証（返す前に IngestDestination.validate!）" do
      it "平文の RTMP しか無い（rtmpsIngestionAddress が無い）: 平文へ倒さず UnexpectedResponse" do
        stub_stream_create(stream_resource(rtmps: nil))

        expect { gateway.ensure_stream(connection, broadcast: broadcast) }.to raise_error(YouTubeErrors::UnexpectedResponse) { |error|
          expect(error.detail).to eq(:missing_ingestion_address)
        }
      end

      {
        "平文の RTMP" => [ "rtmp://a.rtmps.youtube.com:443/live2", :scheme_not_allowed ],
        "YouTube でないホスト" => [ "rtmps://evil.example:443/live2", :host_not_allowed ],
        "ポートが 443 でない" => [ "rtmps://a.rtmps.youtube.com:1935/live2", :port_not_allowed ],
        "バックアップの印（?backup=1）" => [ "rtmps://a.rtmps.youtube.com:443/live2?backup=1", :query_not_allowed ],
        "ユーザー情報" => [ "rtmps://user:pass@a.rtmps.youtube.com:443/live2", :userinfo_not_allowed ],
        "配信キーを混ぜた形" => [ "rtmps://a.rtmps.youtube.com:443/live2/dummy-stream-key-must-not-appear", :path_not_allowed ],
        "疑似の取り込み口（本番では許可されない）" => [ "rtmps://fake-ingest:1935/live2", :host_not_allowed ]
      }.each do |label, (url, code)|
        it "#{label}: IngestDestination::Invalid（#{code}）。配信キー・取り込み先を返さず、例外にも出さない" do
          stub_stream_create(stream_resource(rtmps: url))

          expect { gateway.ensure_stream(connection, broadcast: broadcast) }.to raise_error(IngestDestination::Invalid) { |error|
            expect(error.code).to eq(code)
            expect(error.message).not_to include(url)
            expect(error.message).not_to include(stream_key_value)
          }
        end
      end

      it "開発・テストの環境の窓口は、疑似の取り込み口（fake-ingest:1935）を許す" do
        stub_stream_create(stream_resource(rtmps: "rtmps://fake-ingest:1935/live2"))
        development_gateway = build_gateway(vault: vault, now: now, environment: AppEnvironment.new("development"))

        expect(development_gateway.ensure_stream(connection, broadcast: broadcast).ingest_url).to eq("rtmps://fake-ingest:1935/live2")
      end

      it "検証に失敗しても、台帳には記帳済み（YouTube では、ストリームが作られている）" do
        stub_stream_create(stream_resource(rtmps: "rtmp://a.rtmps.youtube.com:443/live2"))

        expect { gateway.ensure_stream(connection, broadcast: broadcast) }.to raise_error(IngestDestination::Invalid)

        expect(ledger_entries).to eq([ [ "liveStreams.insert", 50, "prep", "ok" ] ])
      end
    end

    describe "配信キー・ストリームの識別子の検査" do
      it "配信キーが無い・空・空白や改行を含む: UnexpectedResponse（配信キーの値を、例外に出さない）" do
        [ nil, "", "has space", "line\nbreak", 123 ].each do |key|
          stub_stream_create(stream_resource(stream_key: key))

          expect { gateway.ensure_stream(connection, broadcast: broadcast) }.to raise_error(YouTubeErrors::UnexpectedResponse) { |error|
            expect(error.detail).to eq(:invalid_stream_key)
            expect(error.message).not_to include("has space")
          }
        end
      end

      it "ストリームの識別子が無い・形が違う: UnexpectedResponse" do
        [ nil, "", "has space", 1 ].each do |id|
          stub_stream_create(stream_resource(id: id))

          expect { gateway.ensure_stream(connection, broadcast: broadcast) }.to raise_error(YouTubeErrors::UnexpectedResponse)
        end
      end

      it "ingestionInfo が無い応答は UnexpectedResponse" do
        stub_stream_create({ "id" => youtube_stream_id, "cdn" => {} })

        expect { gateway.ensure_stream(connection, broadcast: broadcast) }.to raise_error(YouTubeErrors::UnexpectedResponse)
      end

      it "配信キーを、例外のメッセージ・inspect・ログに出さない（成功のときの StreamInfo の inspect も）" do
        stub_stream_create
        info = nil

        output = capture_logs { info = gateway.ensure_stream(connection, broadcast: broadcast) }

        expect(output).not_to include(stream_key_value)
        expect(info.inspect).not_to include(stream_key_value)
        expect(info.stream_key).to eq(stream_key_value)
      end
    end
  end

  describe "#bind（配信とストリームの紐づけ）" do
    def stub_bind(response = json_response(broadcast_resource(life_cycle_status: "ready")))
      stub_request(:post, api_url("liveBroadcasts/bind"))
        .with(query: { "id" => youtube_broadcast_id, "streamId" => youtube_stream_id, "part" => "id,contentDetails" }, headers: auth_headers)
        .to_return(response)
    end

    it "POST liveBroadcasts/bind?id=<配信>&streamId=<ストリーム>&part=id,contentDetails。true を返し、50 ユニットを記帳する" do
      stub = stub_bind

      expect(gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast)).to be(true)

      expect(stub).to have_been_requested.once
      expect(ledger_entries).to eq([ [ "liveBroadcasts.bind", 50, "prep", "ok" ] ])
    end

    it "応答の配信の識別子が違えば UnexpectedResponse" do
      stub_bind(json_response(broadcast_resource(id: "dummybc9999")))

      expect { gateway.bind(connection, youtube_broadcast_id, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::UnexpectedResponse) { |error|
        expect(error.detail).to eq(:id_mismatch)
      }
    end

    it "識別子の形が不正なら ArgumentError（通信しない・記帳しない）" do
      [ "", nil, "has space", "a&b=c", "a" * 129 ].each do |value|
        expect { gateway.bind(connection, value, youtube_stream_id, broadcast: broadcast) }.to raise_error(ArgumentError, /youtube_broadcast_id/)
        expect { gateway.bind(connection, youtube_broadcast_id, value, broadcast: broadcast) }.to raise_error(ArgumentError, /youtube_stream_id/)
      end
      expect(QuotaEntry.count).to eq(0)
      expect_no_youtube_request
    end
  end

  describe "#fetch_status（配信の状態）" do
    def stub_status(response)
      stub_request(:get, api_url("liveBroadcasts")).with(query: { "part" => "id,status", "id" => youtube_broadcast_id }, headers: auth_headers).to_return(response)
    end

    SettlementRules::LifeCycleStatus::ALL.each do |value|
      it "lifeCycleStatus #{value} を YouTubeStatus にする" do
        stub_status(list_response(broadcast_resource(life_cycle_status: value)))

        status = gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep)

        expect(status).to be_a(YouTubeStatus)
        expect(status.value).to eq(value)
      end
    end

    it "存在しない（空の items）は、YouTubeStatus.not_found" do
      stub_status(list_response)

      expect(gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep)).to eq(YouTubeStatus.not_found)
    end

    it "存在しない（404 liveBroadcastNotFound）も、YouTubeStatus.not_found（例外にしない）" do
      stub_status(error_response(404, "liveBroadcastNotFound"))

      expect(gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep)).to be_not_found
    end

    it "lifeCycleStatus が無い・未知の値: UnexpectedResponse（値をメッセージに出さない）" do
      [ [ broadcast_resource(life_cycle_status: nil), :missing_life_cycle_status ], [ broadcast_resource(life_cycle_status: "somethingNew"), :unknown_life_cycle_status ],
        [ { "id" => youtube_broadcast_id }, :missing_life_cycle_status ] ].each do |resource, detail|
        stub_status(list_response(resource))

        expect { gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep) }.to raise_error(YouTubeErrors::UnexpectedResponse) { |error|
          expect(error.detail).to eq(detail)
          expect(error.message).not_to include("somethingNew")
        }
      end
    end

    it "応答の配信の識別子が違えば UnexpectedResponse（他の配信の状態を返さない）" do
      stub_status(list_response(broadcast_resource(id: "dummybc9999")))

      expect { gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep) }.to raise_error(YouTubeErrors::UnexpectedResponse) { |error|
        expect(error.detail).to eq(:id_mismatch)
      }
    end

    it "準備・確認枠（prep）から 1 ユニットを記帳する。終了時の状態確認は、終了・清算枠（settle）から記帳する" do
      stub_status(list_response(broadcast_resource(life_cycle_status: "live")))

      gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep)
      gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle)

      expect(ledger_entries).to eq([ [ "liveBroadcasts.list", 1, "prep", "ok" ], [ "liveBroadcasts.list", 1, "settle", "ok" ] ])
      expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 339, settle_reserved_units: 209)
    end

    it "枠の指定が無い・共通枠・未知の枠は ArgumentError（用途で、呼び出し側が決める）。通信しない" do
      [ nil, :common, :other, "prep" ].each do |bucket|
        expect { gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: bucket) }.to raise_error(ArgumentError, /bucket/)
      end
      expect_no_youtube_request
      expect(QuotaEntry.count).to eq(0)
    end
  end

  describe "#fetch_stream_health（ストリームの健全性）" do
    def stub_health(response)
      stub_request(:get, api_url("liveStreams")).with(query: { "part" => "id,status", "id" => youtube_stream_id }, headers: auth_headers).to_return(response)
    end

    def health_for(health)
      stub_health(list_response(stream_resource(health: health)))
      gateway.fetch_stream_health(connection, youtube_stream_id, broadcast: broadcast)
    end

    it "GET liveStreams?part=id,status&id=<識別子>。healthStatus.status と、severity が error の設定の問題の type を返す" do
      health = health_for(
        "status" => "bad",
        "configurationIssues" => [
          { "type" => "gopSizeLong", "severity" => "error", "reason" => "Keyframe interval is too long", "description" => "dummy" },
          { "type" => "bitrateLow", "severity" => "warning", "reason" => "Low bitrate", "description" => "dummy" },
          { "type" => "videoCodec", "severity" => "info", "reason" => "Codec", "description" => "dummy" }
        ]
      )

      expect(health).to be_a(StreamHealth)
      expect(health).to have_attributes(status: "bad", error_types: [ "gopSizeLong" ])
      expect(health).to be_warning
    end

    # [healthStatus, 警告か]
    [
      [ { "status" => "good" }, false ],
      [ { "status" => "ok" }, false ],
      [ { "status" => "noData" }, false ],
      [ { "status" => "bad" }, true ],
      [ { "status" => "good", "configurationIssues" => [ { "type" => "gopSizeLong", "severity" => "error" } ] }, true ],
      [ { "status" => "noData", "configurationIssues" => [ { "type" => "gopSizeLong", "severity" => "error" } ] }, true ],
      [ { "status" => "good", "configurationIssues" => [ { "type" => "bitrateLow", "severity" => "warning" }, { "type" => "x", "severity" => "info" } ] }, false ],
      [ { "status" => "ok", "configurationIssues" => [] }, false ]
    ].each do |health, warning|
      it "healthStatus #{health.to_json} は 警告=#{warning}（bad または error のときだけ。noData・warning・info は警告にしない）" do
        expect(health_for(health).warning?).to be(warning)
      end
    end

    it "healthStatus が無い（情報が無い）なら noData として扱い、警告にしない" do
      stub_health(list_response({ "id" => youtube_stream_id, "status" => { "streamStatus" => "ready" } }))

      health = gateway.fetch_stream_health(connection, youtube_stream_id, broadcast: broadcast)

      expect(health.status).to eq("noData")
      expect(health.warning?).to be(false)
    end

    it "未知の healthStatus.status は UnexpectedResponse（good にしない）。応答のストリームの識別子が違えば UnexpectedResponse" do
      stub_health(list_response(stream_resource(health: { "status" => "excellent" })))
      expect { gateway.fetch_stream_health(connection, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::UnexpectedResponse) { |error|
        expect(error.detail).to eq(:unknown_health_status)
      }

      stub_health(list_response(stream_resource(id: "dummy-stream-id-other", health: { "status" => "good" })))
      expect { gateway.fetch_stream_health(connection, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::UnexpectedResponse) { |error|
        expect(error.detail).to eq(:id_mismatch)
      }
    end

    it "ストリームが存在しない（空の items）は NotFound（liveStreamNotFound）" do
      stub_health(list_response)

      expect { gateway.fetch_stream_health(connection, youtube_stream_id, broadcast: broadcast) }.to raise_error(YouTubeErrors::NotFound) { |error|
        expect(error.reason).to eq("liveStreamNotFound")
      }
    end

    it "配信キーを含む応答でも、返す値・ログに配信キーを出さない。台帳へ 1 ユニットを準備・確認枠から記帳する" do
      stub_health(list_response(stream_resource(health: { "status" => "good" })))
      health = nil

      output = capture_logs { health = gateway.fetch_stream_health(connection, youtube_stream_id, broadcast: broadcast) }

      expect(output).not_to include(stream_key_value)
      expect(health.inspect).not_to include(stream_key_value)
      expect(ledger_entries).to eq([ [ "liveStreams.list", 1, "prep", "ok" ] ])
    end
  end

  describe "#complete（完了への遷移）" do
    def stub_transition(response = json_response(broadcast_resource(life_cycle_status: "complete")))
      stub_request(:post, api_url("liveBroadcasts/transition"))
        .with(query: { "broadcastStatus" => "complete", "id" => youtube_broadcast_id, "part" => "status" }, headers: auth_headers)
        .to_return(response)
    end

    it "POST liveBroadcasts/transition?broadcastStatus=complete&id=<配信>&part=status。true を返す" do
      stub = stub_transition

      expect(gateway.complete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle)).to be(true)
      expect(stub).to have_been_requested.once
    end

    it "遷移は非同期。応答の状態が live のままでも成功として扱う" do
      stub_transition(json_response(broadcast_resource(life_cycle_status: "live")))

      expect(gateway.complete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle)).to be(true)
    end

    it "終了・清算枠（settle）から 50 ユニット。先行配信の清算（10.5）は、準備・確認枠（prep）から 50 ユニットを記帳する" do
      stub_transition

      gateway.complete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle)
      gateway.complete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep)

      expect(ledger_entries).to eq([ [ "liveBroadcasts.transition", 50, "settle", "ok" ], [ "liveBroadcasts.transition", 50, "prep", "ok" ] ])
      expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 290, settle_reserved_units: 160)
    end

    it "枠の指定が無い・共通枠は ArgumentError" do
      expect { gateway.complete(connection, youtube_broadcast_id, broadcast: broadcast) }.to raise_error(ArgumentError, /required/)
      expect { gateway.complete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :common) }.to raise_error(ArgumentError, /bucket/)
    end
  end

  describe "#delete（配信の削除）" do
    def stub_delete(response = { status: 204, body: "" })
      stub_request(:delete, api_url("liveBroadcasts")).with(query: { "id" => youtube_broadcast_id }, headers: auth_headers).to_return(response)
    end

    it "DELETE liveBroadcasts?id=<配信>。204 で true を返し、終了・清算枠から 50 ユニットを記帳する" do
      stub = stub_delete

      expect(gateway.delete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle)).to be(true)

      expect(stub).to have_been_requested.once
      expect(ledger_entries).to eq([ [ "liveBroadcasts.delete", 50, "settle", "ok" ] ])
    end

    it "先行配信の清算（10.5）は準備・確認枠から。200 や本文つきの成功も、成功" do
      stub_delete({ status: 200, body: "{}" })

      expect(gateway.delete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep)).to be(true)
      expect(ledger_entries).to eq([ [ "liveBroadcasts.delete", 50, "prep", "ok" ] ])
    end

    it "枠の指定が無い・共通枠は ArgumentError" do
      expect { gateway.delete(connection, youtube_broadcast_id, broadcast: broadcast) }.to raise_error(ArgumentError, /required/)
      expect { gateway.delete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :common) }.to raise_error(ArgumentError, /bucket/)
    end
  end

  describe "#probe_channel（接続時の確認）" do
    def stub_channels(response)
      stub_request(:get, api_url("channels")).with(query: { "part" => "snippet", "mine" => "true" }, headers: auth_headers).to_return(response)
    end

    def stub_live_check(response)
      stub_request(:get, api_url("liveBroadcasts")).with(query: { "part" => "id", "mine" => "true", "maxResults" => "1" }, headers: auth_headers).to_return(response)
    end

    it "チャンネルがあり、配信の一覧取得が成功すれば connected（チャンネル名つき）。各 1 ユニットを共通枠から記帳する" do
      channels = stub_channels(list_response(channel_resource))
      live = stub_live_check(list_response)

      result = gateway.probe_channel(connection)

      expect([ channels, live ]).to all(have_been_requested.once)
      expect(result).to be_a(ProbeResult)
      expect(result).to have_attributes(outcome: "connected", channel_title: channel_title_value)
      expect(ledger_entries).to eq([ [ "channels.list", 1, "common", "ok" ], [ "liveBroadcasts.list", 1, "common", "ok" ] ])
      expect(QuotaDay.find(day)).to have_attributes(common_used_units: 2, used_units: 0)
    end

    it "チャンネルが無い（空の items）なら no_channel。ライブ配信の確認はしない（1 ユニットだけ）" do
      stub_channels(list_response)

      result = gateway.probe_channel(connection)

      expect(result).to have_attributes(outcome: "no_channel", channel_title: nil)
      expect(a_request(:get, api_url("liveBroadcasts"))).not_to have_been_made
      expect(ledger_entries).to eq([ [ "channels.list", 1, "common", "ok" ] ])
    end

    it "チャンネルが無い（401 youtubeSignupRequired・403 channelNotFound）も no_channel" do
      [ error_response(401, "youtubeSignupRequired"), error_response(403, "channelNotFound"), error_response(404, "channelNotFound") ].each do |response|
        stub_channels(response)

        expect(gateway.probe_channel(connection).outcome).to eq("no_channel")
      end
    end

    it "配信の一覧取得が liveStreamingNotEnabled を返せば live_not_enabled（チャンネル名つき。7.2 の判定）" do
      stub_channels(list_response(channel_resource))
      stub_live_check(error_response(403, "liveStreamingNotEnabled"))

      expect(gateway.probe_channel(connection)).to have_attributes(outcome: "live_not_enabled", channel_title: channel_title_value)
    end

    it "ライブ配信が制限されている（閉鎖・停止など）も live_not_enabled と同じ扱い" do
      %w[ livePermissionBlocked channelClosed channelSuspended authenticatedUserAccountClosed authenticatedUserAccountSuspended ].each do |reason|
        stub_channels(list_response(channel_resource))
        stub_live_check(error_response(403, reason))

        expect(gateway.probe_channel(connection).outcome).to eq("live_not_enabled")
      end
    end

    it "確認不能（一時的な失敗・権限の不足・未知の応答）は、結果にせず、型付きの例外を投げる" do
      stub_channels(list_response(channel_resource))
      {
        error_response(503, "backendError") => YouTubeErrors::Transient,
        error_response(403, "insufficientPermissions") => YouTubeErrors::InsufficientPermissions,
        error_response(403, "someNewReason") => YouTubeErrors::UnexpectedResponse
      }.each do |response, error_class|
        stub_live_check(response)

        expect { gateway.probe_channel(connection) }.to raise_error(error_class)
      end
    end

    it "チャンネルの確認が失敗すれば、ライブ配信の確認へ進まない" do
      stub_channels(error_response(503, "backendError"))

      expect { gateway.probe_channel(connection) }.to raise_error(YouTubeErrors::Transient)
      expect(a_request(:get, api_url("liveBroadcasts"))).not_to have_been_made
    end

    it "access_token を渡すと、TokenVault を使わずに、そのトークンで確認する（接続の成立前。接続の行はまだ無い）" do
      stub_request(:get, api_url("channels")).with(query: { "part" => "snippet", "mine" => "true" }, headers: { "Authorization" => "Bearer ya29.dummy-direct-token" })
                                             .to_return(list_response(channel_resource))
      stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including("mine" => "true"), headers: { "Authorization" => "Bearer ya29.dummy-direct-token" })
                                                   .to_return(list_response)
      expect(vault).not_to receive(:access_token)

      result = gateway.probe_channel(nil, access_token: "ya29.dummy-direct-token")

      expect(result.outcome).to eq("connected")
    end

    it "接続も access_token も無ければ ArgumentError。access_token が空・空白・改行つきでも ArgumentError（通信しない）" do
      expect { gateway.probe_channel(nil) }.to raise_error(ArgumentError, /connection/)
      [ "", "  ", "has space", "line\nbreak", 1 ].each do |token|
        expect { gateway.probe_channel(nil, access_token: token) }.to raise_error(ArgumentError, /access_token/)
      end
      expect_no_youtube_request
    end

    it "チャンネル名を、ログ・結果の inspect に出さない" do
      stub_channels(list_response(channel_resource))
      stub_live_check(list_response)
      result = nil

      output = capture_logs { result = gateway.probe_channel(connection) }

      expect(output).not_to include(channel_title_value)
      expect(result.inspect).not_to include(channel_title_value)
    end

    it "チャンネル名が応答に無い・文字列でない: UnexpectedResponse" do
      [ { "id" => "c" }, { "snippet" => {} }, { "snippet" => { "title" => 1 } } ].each do |resource|
        stub_channels(list_response(resource))

        expect { gateway.probe_channel(connection) }.to raise_error(YouTubeErrors::UnexpectedResponse)
      end
    end
  end

  describe "認可ヘッダ" do
    it "すべての呼び出しが、TokenVault のアクセストークンを Authorization: Bearer で送る（アカウントの識別子と、窓口の時刻で取得する）" do
      stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(list_response(broadcast_resource(life_cycle_status: "live")))
      expect(vault).to receive(:access_token).with(user_id: user.id, now: now).and_return(access_token_value)

      gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep)

      expect(a_request(:get, api_url("liveBroadcasts")).with(headers: auth_headers, query: hash_including({}))).to have_been_made.once
    end

    it "リダイレクト（3xx）は追わない。想定外の応答（UnexpectedResponse）" do
      stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(status: 302, headers: { "Location" => "https://evil.example/" })

      expect { gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep) }.to raise_error(YouTubeErrors::UnexpectedResponse)
      expect(a_request(:get, "https://evil.example/")).not_to have_been_made
    end
  end

  describe "成功でない応答（3xx）" do
    it "本文を使わない呼び出し（complete・delete）でも、リダイレクト（3xx）は成功にしない（UnexpectedResponse）。追わない" do
      stub_request(:delete, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(status: 302, headers: { "Location" => "https://evil.example/" })
      stub_request(:post, api_url("liveBroadcasts/transition")).with(query: hash_including({})).to_return(status: 301, headers: { "Location" => "https://evil.example/" })

      expect { gateway.delete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle) }.to raise_error(YouTubeErrors::UnexpectedResponse)
      expect { gateway.complete(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :settle) }.to raise_error(YouTubeErrors::UnexpectedResponse)
      expect(a_request(:any, "https://evil.example/")).not_to have_been_made
    end
  end

  describe "構築" do
    let(:valid) { { http: ExternalHttp.new, token_vault: vault, api_base: api_base, stream_title: "Browser Live", environment: AppEnvironment.new("production"), clock: -> { now } } }

    it "必須の引数の検査（ArgumentError）" do
      expect { described_class.new(**valid, api_base: "http://insecure.example/v3") }.to raise_error(ArgumentError, /api_base/)
      expect { described_class.new(**valid, api_base: "https://www.googleapis.com/youtube/v3/") }.to raise_error(ArgumentError, /api_base/)
      expect { described_class.new(**valid, stream_title: "") }.to raise_error(ArgumentError, /stream_title/)
      expect { described_class.new(**valid, token_vault: nil) }.to raise_error(ArgumentError, /token_vault/)
      expect { described_class.new(**valid, http: nil) }.to raise_error(ArgumentError, /http/)
      expect { described_class.new(**valid, environment: "production") }.to raise_error(ArgumentError, /environment/)
      expect { described_class.new(**valid, clock: 1) }.to raise_error(ArgumentError, /clock/)
    end

    it "窓口の時計が Time を返さなければ ArgumentError（呼び出しの前に。通信しない）" do
      bad = described_class.new(**valid, clock: -> { "now" })

      expect { bad.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep) }.to raise_error(ArgumentError, /clock/)
      expect_no_youtube_request
    end

    it "inspect に、依存するもの（トークンの保管庫・HTTP）を出さない" do
      expect(gateway.inspect).to eq("#<YouTubeGateway>")
    end

    it "公開メソッドは、24.2 のメソッドだけ（9 つ）。ほかに HTTP の入口を持たない" do
      expected = %i[ insert_broadcast list_unstarted_broadcasts ensure_stream bind fetch_status fetch_stream_health complete delete probe_channel inspect ]

      expect(described_class.public_instance_methods(false)).to match_array(expected)
      expect(described_class.private_instance_methods(false)).to include(:call)
    end
  end
end
