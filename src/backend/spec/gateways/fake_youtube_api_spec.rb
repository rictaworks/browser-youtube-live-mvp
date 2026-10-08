require "rails_helper"

# 疑似の YouTube Data API（FakeYouTubeGateway::Api。issue #10）。開発・テストのみ。メモリの上で、YouTube の応答の形（liveBroadcasts・liveStreams・
# channels・bind・transition・エラー）を再現する。窓口（YouTubeGateway）は、HTTP の代わりに、これへ要求を渡す（同じ経路で、同じ分類・記帳を通る）。
#   決定的な識別子（fake-bc-N・fake-stream-N）・取り込み先（契約 dev_ingest の fake-ingest:1935）・配信キー（fake-key-N）
#   配信の状態: created -> ready（紐づけ後）-> live（紐づけから一定時間後。既定 5 秒。時計は注入）-> complete
#   part を尊重する（contentDetails を part に含めないと、自動開始・自動停止・モニター無効の指定が捨てられて既定になる。YouTube と同じ）
#   失敗の注入（次の呼び出しだけ）
# 要求は、ExternalHttp と同じ形（HTTP メソッド・URL・ヘッダ・本文）で受け、ExternalHttp::Response を返す。
RSpec.describe FakeYouTubeGateway::Api do
  let(:base) { "https://www.googleapis.com/youtube/v3" }
  let(:ingest) { { scheme: "rtmps", host: "fake-ingest", port: 1935 } }
  let(:clock_time) { [ Time.utc(2026, 10, 8, 3, 0, 0) ] }
  let(:clock) { -> { clock_time.first } }
  let(:api) { described_class.new(api_base: base, ingest: ingest, clock: clock, live_after_seconds: 5, channel_title: "Fake Channel") }
  let(:headers) { { "Authorization" => "Bearer fake-access-token-1" } }

  def advance(seconds)
    clock_time[0] = clock_time.first + seconds
  end

  def call(http_method, path, query: {}, json: nil, request_headers: headers, kind: nil)
    url = "#{base}/#{path}#{query.empty? ? '' : "?#{URI.encode_www_form(query)}"}"
    body = json ? JSON.generate(json) : nil
    api.handle(kind, http_method, url, request_headers, body)
  end

  def parsed(response)
    JSON.parse(response.body)
  end

  def broadcast_body(title: "dummy-title", start: Time.utc(2026, 10, 8, 3, 1, 0), privacy: "unlisted", auto_start: true, auto_stop: true, monitor: false)
    {
      "snippet" => { "title" => title, "scheduledStartTime" => start.iso8601 },
      "status" => { "privacyStatus" => privacy, "selfDeclaredMadeForKids" => false },
      "contentDetails" => { "enableAutoStart" => auto_start, "enableAutoStop" => auto_stop, "monitorStream" => { "enableMonitorStream" => monitor } }
    }
  end

  def stream_body
    { "snippet" => { "title" => "Browser Live" }, "cdn" => { "ingestionType" => "rtmp", "resolution" => "variable", "frameRate" => "variable" }, "contentDetails" => { "isReusable" => true } }
  end

  def create_broadcast(**options)
    parsed(call(:post, "liveBroadcasts", query: { part: "snippet,contentDetails,status" }, json: broadcast_body(**options))).fetch("id")
  end

  def create_stream
    parsed(call(:post, "liveStreams", query: { part: "snippet,cdn,contentDetails,status" }, json: stream_body)).fetch("id")
  end

  def life_cycle_status(id)
    parsed(call(:get, "liveBroadcasts", query: { part: "id,status", id: id })).dig("items", 0, "status", "lifeCycleStatus")
  end

  def reason_of(response)
    parsed(response).dig("error", "errors", 0, "reason")
  end

  describe "要求の受け付け" do
    it "ExternalHttp::Response を返す（状態・小文字のヘッダ・本文・ホスト）" do
      response = call(:get, "channels", query: { part: "snippet", mine: "true" })

      expect(response).to be_a(ExternalHttp::Response)
      expect(response.status).to eq(200)
      expect(response.headers["content-type"]).to start_with("application/json")
      expect(response.host).to eq("www.googleapis.com")
      expect(response.success?).to be(true)
    end

    it "request（種別を渡さない入口）でも同じ。ExternalHttp と同じ引数の形" do
      response = api.request(:get, "#{base}/channels?part=snippet&mine=true", headers: headers, body: nil)

      expect(response.status).to eq(200)
    end

    it "Authorization: Bearer が無ければ 401（authError）。トークンが空でも 401" do
      [ {}, { "Authorization" => "Bearer " }, { "Authorization" => "Basic abc" } ].each do |bad|
        response = call(:get, "channels", query: { part: "snippet", mine: "true" }, request_headers: bad)

        expect(response.status).to eq(401)
        expect(reason_of(response)).to eq("authError")
      end
    end

    it "基底の URL が違う・未知のパスは 400（unknownEndpoint）。実装の誤りを、清算済みと取り違えないよう、404 にしない" do
      other = api.handle(nil, :get, "https://example.invalid/youtube/v3/channels?part=snippet", headers, nil)
      unknown = call(:get, "liveThings", query: { part: "id" })
      wrong_verb = call(:delete, "channels", query: { part: "id" })

      expect([ other.status, unknown.status, wrong_verb.status ]).to all(eq(400))
      expect([ other, unknown, wrong_verb ].map { |response| reason_of(response) }).to all(eq("unknownEndpoint"))
    end

    it "本文が JSON でない POST は 400（parseError）" do
      response = api.handle(nil, :post, "#{base}/liveBroadcasts?part=snippet", headers, "not json")

      expect(response.status).to eq(400)
      expect(reason_of(response)).to eq("parseError")
    end
  end

  describe "配信の作成（liveBroadcasts.insert）" do
    it "決定的な識別子 fake-bc-N（1 から）。リソースは、part に応じた項目を持つ" do
      first = parsed(call(:post, "liveBroadcasts", query: { part: "snippet,contentDetails,status" }, json: broadcast_body))
      second = parsed(call(:post, "liveBroadcasts", query: { part: "snippet,contentDetails,status" }, json: broadcast_body))

      expect([ first["id"], second["id"] ]).to eq(%w[ fake-bc-1 fake-bc-2 ])
      expect(first).to include("kind" => "youtube#liveBroadcast")
      expect(first.fetch("snippet")).to include("title" => "dummy-title", "scheduledStartTime" => "2026-10-08T03:01:00Z")
      expect(first.fetch("status")).to include("lifeCycleStatus" => "created", "privacyStatus" => "unlisted", "selfDeclaredMadeForKids" => false)
      expect(first.fetch("contentDetails")).to include("enableAutoStart" => true, "enableAutoStop" => true, "monitorStream" => { "enableMonitorStream" => false })
    end

    it "part に含めない部分は、返さない" do
      resource = parsed(call(:post, "liveBroadcasts", query: { part: "snippet,status" }, json: broadcast_body))

      expect(resource.keys).to include("snippet", "status")
      expect(resource.keys).not_to include("contentDetails")
    end

    it "part に contentDetails を含めないと、自動開始・自動停止・モニター無効の指定が捨てられて既定になる（モニター有効・自動開始なし）。紐づけても、ライブにならない" do
      id = parsed(call(:post, "liveBroadcasts", query: { part: "snippet,status" }, json: broadcast_body)).fetch("id")
      stream_id = create_stream
      call(:post, "liveBroadcasts/bind", query: { id: id, streamId: stream_id, part: "id" })
      advance(3600)

      expect(life_cycle_status(id)).to eq("ready")
    end

    {
      "part が無い" => [ {}, :part ],
      "part に snippet が無い" => [ { part: "status" }, :part ],
      "part に status が無い" => [ { part: "snippet" }, :part ]
    }.each do |label, (query, _)|
      it "#{label}: 400（invalidPart）" do
        response = call(:post, "liveBroadcasts", query: query, json: broadcast_body)

        expect(response.status).to eq(400)
        expect(reason_of(response)).to eq("invalidPart")
      end
    end

    {
      "タイトルが空" => [ { title: "" }, "invalidTitle" ],
      "タイトルが 101 文字" => [ { title: "a" * 101 }, "invalidTitle" ],
      "タイトルに <" => [ { title: "a<b" }, "invalidTitle" ],
      "開始予定時刻が過去" => [ { start: Time.utc(2026, 10, 8, 2, 59, 59) }, "invalidScheduledStartTime" ],
      "開始予定時刻が現在" => [ { start: Time.utc(2026, 10, 8, 3, 0, 0) }, "invalidScheduledStartTime" ],
      "公開範囲が未知" => [ { privacy: "friends" }, "invalidPrivacyStatus" ]
    }.each do |label, (options, reason)|
      it "#{label}: 400（#{reason}）。識別子を消費しない" do
        response = call(:post, "liveBroadcasts", query: { part: "snippet,contentDetails,status" }, json: broadcast_body(**options))

        expect(response.status).to eq(400)
        expect(reason_of(response)).to eq(reason)
        expect(create_broadcast).to eq("fake-bc-1")
      end
    end

    it "開始予定時刻が無い・形が違う: 400。scheduledEndTime を付けても受け付ける（YouTube の既定に合わせて無視する）" do
      missing = broadcast_body.tap { |body| body["snippet"].delete("scheduledStartTime") }
      malformed = broadcast_body.tap { |body| body["snippet"]["scheduledStartTime"] = "tomorrow" }
      with_end = broadcast_body.tap { |body| body["snippet"]["scheduledEndTime"] = "2026-10-08T05:00:00Z" }

      expect(call(:post, "liveBroadcasts", query: { part: "snippet,contentDetails,status" }, json: missing).status).to eq(400)
      expect(call(:post, "liveBroadcasts", query: { part: "snippet,contentDetails,status" }, json: malformed).status).to eq(400)
      expect(call(:post, "liveBroadcasts", query: { part: "snippet,contentDetails,status" }, json: with_end).status).to eq(200)
    end
  end

  describe "配信の状態（created -> ready -> live -> complete）" do
    let(:stream_id) { create_stream }
    let(:broadcast_id) { create_broadcast }

    def bind!
      call(:post, "liveBroadcasts/bind", query: { id: broadcast_id, streamId: stream_id, part: "id,contentDetails" })
    end

    it "作成直後は created。紐づけると ready。紐づけから 5 秒（既定）で live。ちょうど 5 秒から" do
      expect(life_cycle_status(broadcast_id)).to eq("created")
      bind!
      expect(life_cycle_status(broadcast_id)).to eq("ready")

      advance(4)
      expect(life_cycle_status(broadcast_id)).to eq("ready")
      advance(1)
      expect(life_cycle_status(broadcast_id)).to eq("live")
      advance(3600)
      expect(life_cycle_status(broadcast_id)).to eq("live")
    end

    it "ライブになるまでの秒数は、構築時に指定できる" do
      quick = described_class.new(api_base: base, ingest: ingest, clock: clock, live_after_seconds: 1, channel_title: "Fake Channel")
      bc = JSON.parse(quick.handle(nil, :post, "#{base}/liveBroadcasts?part=snippet,contentDetails,status", headers, JSON.generate(broadcast_body)).body).fetch("id")
      st = JSON.parse(quick.handle(nil, :post, "#{base}/liveStreams?part=snippet,cdn,contentDetails,status", headers, JSON.generate(stream_body)).body).fetch("id")
      quick.handle(nil, :post, "#{base}/liveBroadcasts/bind?id=#{bc}&streamId=#{st}&part=id", headers, nil)
      advance(1)

      response = quick.handle(nil, :get, "#{base}/liveBroadcasts?part=id,status&id=#{bc}", headers, nil)

      expect(JSON.parse(response.body).dig("items", 0, "status", "lifeCycleStatus")).to eq("live")
    end

    it "紐づけの応答は、配信のリソース（boundStreamId を持つ）" do
      resource = parsed(bind!)

      expect(resource).to include("id" => broadcast_id)
      expect(resource.dig("contentDetails", "boundStreamId")).to eq(stream_id)
    end

    it "存在しない配信・ストリームへの紐づけは 404（liveBroadcastNotFound・liveStreamNotFound）" do
      stream_id
      missing_broadcast = call(:post, "liveBroadcasts/bind", query: { id: "fake-bc-99", streamId: stream_id, part: "id" })
      broadcast_id
      missing_stream = call(:post, "liveBroadcasts/bind", query: { id: broadcast_id, streamId: "fake-stream-99", part: "id" })

      expect([ missing_broadcast.status, reason_of(missing_broadcast) ]).to eq([ 404, "liveBroadcastNotFound" ])
      expect([ missing_stream.status, reason_of(missing_stream) ]).to eq([ 404, "liveStreamNotFound" ])
    end

    it "完了した配信は、紐づけを受け付けない（403 liveBroadcastBindingNotAllowed）" do
      bind!
      advance(5)
      call(:post, "liveBroadcasts/transition", query: { broadcastStatus: "complete", id: broadcast_id, part: "status" })

      response = bind!

      expect([ response.status, reason_of(response) ]).to eq([ 403, "liveBroadcastBindingNotAllowed" ])
    end

    describe "完了への遷移（liveBroadcasts.transition）" do
      def transition(status: "complete")
        call(:post, "liveBroadcasts/transition", query: { broadcastStatus: status, id: broadcast_id, part: "status" })
      end

      it "live から complete へ。応答は完了のリソース。以後の状態は complete のまま" do
        bind!
        advance(5)

        response = transition

        expect(response.status).to eq(200)
        expect(parsed(response).dig("status", "lifeCycleStatus")).to eq("complete")
        advance(3600)
        expect(life_cycle_status(broadcast_id)).to eq("complete")
      end

      it "すでに完了なら 403 redundantTransition" do
        bind!
        advance(5)
        transition

        response = transition

        expect([ response.status, reason_of(response) ]).to eq([ 403, "redundantTransition" ])
      end

      it "live でない（created・ready）なら 403 invalidTransition（すでに終端ではない）" do
        expect(reason_of(transition)).to eq("invalidTransition")
        bind!
        expect(reason_of(transition)).to eq("invalidTransition")
      end

      it "遷移中（liveStarting・testStarting）も 403 invalidTransition。testing は完了へ遷移できる" do
        bind!
        api.force_life_cycle_status(broadcast_id, "liveStarting")
        expect(reason_of(transition)).to eq("invalidTransition")
        api.force_life_cycle_status(broadcast_id, "testStarting")
        expect(reason_of(transition)).to eq("invalidTransition")
        api.force_life_cycle_status(broadcast_id, "testing")
        expect(transition.status).to eq(200)
      end

      it "存在しない配信は 404 liveBroadcastNotFound。完了以外への遷移は 400" do
        missing = call(:post, "liveBroadcasts/transition", query: { broadcastStatus: "complete", id: "fake-bc-99", part: "status" })
        other = transition(status: "live")

        expect([ missing.status, reason_of(missing) ]).to eq([ 404, "liveBroadcastNotFound" ])
        expect(other.status).to eq(400)
      end
    end

    describe "削除（liveBroadcasts.delete）" do
      def delete_broadcast(id = broadcast_id)
        call(:delete, "liveBroadcasts", query: { id: id })
      end

      it "未開始（created・ready）は削除できる（204・本文なし）。以後は存在しない" do
        bind!
        response = delete_broadcast

        expect(response.status).to eq(204)
        expect(response.body).to eq("")
        expect(parsed(call(:get, "liveBroadcasts", query: { part: "id,status", id: broadcast_id })).fetch("items")).to eq([])
      end

      it "遷移中（liveStarting・testStarting）で止まった配信も削除できる（公式の案内は「削除して作り直す」）" do
        bind!
        api.force_life_cycle_status(broadcast_id, "liveStarting")

        expect(delete_broadcast.status).to eq(204)
      end

      it "live の配信は削除できない（403 liveBroadcastDeletionNotAllowed）。完了した配信は削除できる" do
        bind!
        advance(5)
        expect(reason_of(delete_broadcast)).to eq("liveBroadcastDeletionNotAllowed")

        call(:post, "liveBroadcasts/transition", query: { broadcastStatus: "complete", id: broadcast_id, part: "status" })
        expect(delete_broadcast.status).to eq(204)
      end

      it "存在しない配信は 404 liveBroadcastNotFound" do
        response = delete_broadcast("fake-bc-99")

        expect([ response.status, reason_of(response) ]).to eq([ 404, "liveBroadcastNotFound" ])
      end
    end

    describe "一覧（liveBroadcasts.list）" do
      it "id 指定: その配信だけ。無ければ空の items（200）。part に応じて項目を返す（id は常に）" do
        broadcast_id
        found = parsed(call(:get, "liveBroadcasts", query: { part: "id,status", id: broadcast_id }))
        missing = parsed(call(:get, "liveBroadcasts", query: { part: "id,status", id: "fake-bc-99" }))
        id_only = parsed(call(:get, "liveBroadcasts", query: { part: "id", id: broadcast_id }))

        expect(found.dig("items", 0)).to include("id" => broadcast_id, "status" => include("lifeCycleStatus" => "created"))
        expect(found.dig("items", 0).keys).not_to include("snippet")
        expect(missing).to include("items" => [])
        expect(id_only.dig("items", 0).keys).to eq(%w[ kind id ])
      end

      it "broadcastStatus=upcoming: 未開始（created・ready）の配信。live・complete は含まない。maxResults を尊重する" do
        first = create_broadcast(title: "dummy-a")
        second = create_broadcast(title: "dummy-b")
        third = create_broadcast(title: "dummy-c")
        call(:post, "liveBroadcasts/bind", query: { id: second, streamId: stream_id, part: "id" })
        advance(5)
        call(:post, "liveBroadcasts/bind", query: { id: third, streamId: stream_id, part: "id" })

        ids = parsed(call(:get, "liveBroadcasts", query: { part: "id,snippet,status", broadcastStatus: "upcoming", maxResults: "50" })).fetch("items").map { |item| item["id"] }
        limited = parsed(call(:get, "liveBroadcasts", query: { part: "id", broadcastStatus: "upcoming", maxResults: "1" })).fetch("items")

        expect(ids).to eq([ first, third ])
        expect(limited.size).to eq(1)
      end

      it "mine=true: チャンネルのすべての配信（maxResults 件まで）" do
        create_broadcast
        create_broadcast

        items = parsed(call(:get, "liveBroadcasts", query: { part: "id", mine: "true", maxResults: "1" })).fetch("items")

        expect(items.size).to eq(1)
      end

      it "id・broadcastStatus・mine のどれも無ければ 400（YouTube は、フィルターのどれか 1 つを要求する）" do
        response = call(:get, "liveBroadcasts", query: { part: "id" })

        expect(response.status).to eq(400)
        expect(reason_of(response)).to eq("missingFilter")
      end
    end
  end

  describe "ストリーム" do
    it "作成: 決定的な識別子 fake-stream-N・配信キー fake-key-N。取り込み先は、疑似の取り込み口（RTMPS・1935）。平文の RTMP とバックアップも返す（窓口が選ぶ）" do
      first = parsed(call(:post, "liveStreams", query: { part: "snippet,cdn,contentDetails,status" }, json: stream_body))
      second = parsed(call(:post, "liveStreams", query: { part: "snippet,cdn,contentDetails,status" }, json: stream_body))
      info = first.dig("cdn", "ingestionInfo")

      expect([ first["id"], second["id"] ]).to eq(%w[ fake-stream-1 fake-stream-2 ])
      expect(info).to include(
        "streamName" => "fake-key-1", "rtmpsIngestionAddress" => "rtmps://fake-ingest:1935/live2", "ingestionAddress" => "rtmp://fake-ingest:1935/live2",
        "rtmpsBackupIngestionAddress" => "rtmps://fake-ingest:1935/live2?backup=1"
      )
      expect(second.dig("cdn", "ingestionInfo", "streamName")).to eq("fake-key-2")
      expect(first.dig("cdn", "ingestionType")).to eq("rtmp")
      expect(first.dig("status", "streamStatus")).to eq("ready")
    end

    it "作成の検査: part に cdn が無い・取り込み種別が rtmp でない・タイトルが無い は 400" do
      no_cdn = call(:post, "liveStreams", query: { part: "snippet,status" }, json: stream_body)
      not_rtmp = call(:post, "liveStreams", query: { part: "snippet,cdn" }, json: stream_body.tap { |body| body["cdn"]["ingestionType"] = "hls" })
      no_title = call(:post, "liveStreams", query: { part: "snippet,cdn" }, json: stream_body.tap { |body| body["snippet"].delete("title") })

      expect([ no_cdn.status, not_rtmp.status, no_title.status ]).to all(eq(400))
      expect(create_stream).to eq("fake-stream-1")
    end

    it "一覧（id 指定）: part に cdn を含めたときだけ ingestionInfo。無ければ空の items" do
      id = create_stream
      with_cdn = parsed(call(:get, "liveStreams", query: { part: "id,cdn,status", id: id }))
      without = parsed(call(:get, "liveStreams", query: { part: "id,status", id: id }))
      missing = parsed(call(:get, "liveStreams", query: { part: "id,cdn,status", id: "fake-stream-99" }))

      expect(with_cdn.dig("items", 0, "cdn", "ingestionInfo", "streamName")).to eq("fake-key-1")
      expect(without.dig("items", 0).keys).not_to include("cdn")
      expect(missing).to include("items" => [])
    end

    it "健全性: 紐づいた配信がライブになるまで noData、ライブ中は good。set_stream_health で上書きできる" do
      stream = create_stream
      broadcast = create_broadcast
      health = -> { parsed(call(:get, "liveStreams", query: { part: "id,status", id: stream })).dig("items", 0, "status") }

      expect(health.call.dig("healthStatus", "status")).to eq("noData")
      call(:post, "liveBroadcasts/bind", query: { id: broadcast, streamId: stream, part: "id" })
      advance(5)
      expect(health.call).to include("streamStatus" => "active", "healthStatus" => include("status" => "good"))

      api.set_stream_health(stream, status: "bad", error_types: [ "gopSizeLong" ])
      expect(health.call.dig("healthStatus")).to include("status" => "bad", "configurationIssues" => [ include("type" => "gopSizeLong", "severity" => "error") ])
    end

    it "set_stream_health の検査: 存在しないストリーム・未知の状態は ArgumentError" do
      stream = create_stream

      expect { api.set_stream_health("fake-stream-99", status: "good") }.to raise_error(ArgumentError, /stream/)
      expect { api.set_stream_health(stream, status: "great") }.to raise_error(ArgumentError, /status/)
    end
  end

  describe "チャンネル（channels.list）" do
    it "mine=true: 1 つのチャンネル（疑似のチャンネル名）。mine でなければ 400" do
      response = parsed(call(:get, "channels", query: { part: "snippet", mine: "true" }))

      expect(response.dig("items", 0, "snippet", "title")).to eq("Fake Channel")
      expect(call(:get, "channels", query: { part: "snippet" }).status).to eq(400)
    end

    it "part に snippet を含めないとき、snippet を返さない" do
      response = parsed(call(:get, "channels", query: { part: "id", mine: "true" }))

      expect(response.dig("items", 0).keys).not_to include("snippet")
    end
  end

  describe "失敗の注入（fail_next。次の呼び出しだけ）" do
    # 注入の名前 -> [HTTP ステータス, reason]
    {
      live_not_enabled: [ 403, "liveStreamingNotEnabled" ],
      live_streaming_restricted: [ 403, "livePermissionBlocked" ],
      insufficient_permissions: [ 403, "insufficientLivePermissions" ],
      broadcast_limit_exceeded: [ 403, "userBroadcastsExceedLimit" ],
      quota_exceeded: [ 403, "quotaExceeded" ],
      rate_limited: [ 403, "rateLimitExceeded" ],
      transient: [ 503, "backendError" ],
      not_found: [ 404, "liveBroadcastNotFound" ],
      already_terminal: [ 403, "redundantTransition" ],
      not_allowed: [ 403, "invalidTransition" ],
      no_channel: [ 401, "youtubeSignupRequired" ],
      unexpected_response: [ 403, "fakeUnexpectedReason" ]
    }.each do |name, (status, reason)|
      it "#{name}: 次の呼び出しが HTTP #{status}・reason #{reason}。その次は成功する" do
        api.fail_next(name)

        failed = call(:get, "channels", query: { part: "snippet", mine: "true" })
        succeeded = call(:get, "channels", query: { part: "snippet", mine: "true" })

        expect([ failed.status, reason_of(failed) ]).to eq([ status, reason ])
        expect(succeeded.status).to eq(200)
      end
    end

    it "timeout: 次の呼び出しで ExternalHttp::Failure（timeout）を投げる（実物のタイムアウトと同じ経路）" do
      api.fail_next(:timeout)

      expect { call(:get, "channels", query: { part: "snippet", mine: "true" }) }.to raise_error(ExternalHttp::Failure) { |error|
        expect(error.reason).to eq(:timeout)
      }
      expect(call(:get, "channels", query: { part: "snippet", mine: "true" }).status).to eq(200)
    end

    it "times: 指定した回数、続けて失敗する" do
      api.fail_next(:transient, times: 3)

      statuses = Array.new(4) { call(:get, "channels", query: { part: "snippet", mine: "true" }).status }

      expect(statuses).to eq([ 503, 503, 503, 200 ])
    end

    it "kinds: 窓口の呼び出しの種別を限ると、その種別の呼び出しだけが失敗する（ほかの呼び出しは通る。注入は残る）" do
      api.fail_next(:quota_exceeded, kinds: [ :bind ])

      other = call(:get, "channels", query: { part: "snippet", mine: "true" }, kind: :probe_channel_lookup)
      stream = create_stream
      broadcast = create_broadcast
      bound = call(:post, "liveBroadcasts/bind", query: { id: broadcast, streamId: stream, part: "id" }, kind: :bind)
      later = call(:post, "liveBroadcasts/bind", query: { id: broadcast, streamId: stream, part: "id" }, kind: :bind)

      expect(other.status).to eq(200)
      expect(reason_of(bound)).to eq("quotaExceeded")
      expect(later.status).to eq(200)
    end

    it "kinds を渡しても、種別が分からない呼び出し（kind が nil）は、対象にならない" do
      api.fail_next(:transient, kinds: [ :bind ])

      expect(call(:get, "channels", query: { part: "snippet", mine: "true" }, kind: nil).status).to eq(200)
    end

    it "注入の順序: 先に注入したものから消費する。種別を限った注入と、限らない注入が混ざっても、呼び出しに合う最初のもの" do
      api.fail_next(:not_found, kinds: [ :bind ])
      api.fail_next(:transient)

      first = call(:get, "channels", query: { part: "snippet", mine: "true" }, kind: :probe_channel_lookup)

      expect(reason_of(first)).to eq("backendError")
    end

    it "認証の検査(401)より先に注入を見ない: トークンが無い要求は 401（authError）のまま。注入は消費されない" do
      api.fail_next(:transient)

      unauthorized = call(:get, "channels", query: { part: "snippet", mine: "true" }, request_headers: {})

      expect(reason_of(unauthorized)).to eq("authError")
      expect(call(:get, "channels", query: { part: "snippet", mine: "true" }).status).to eq(503)
    end

    it "未知の名前・不正な回数・不正な種別は ArgumentError（黙って無視しない）" do
      expect { api.fail_next(:other) }.to raise_error(ArgumentError, /error/)
      expect { api.fail_next(:transient, times: 0) }.to raise_error(ArgumentError, /times/)
      expect { api.fail_next(:transient, times: "1") }.to raise_error(ArgumentError, /times/)
      expect { api.fail_next(:transient, kinds: [ :unknown_call ]) }.to raise_error(ArgumentError, /kinds/)
      expect { api.fail_next(:transient, kinds: []) }.to raise_error(ArgumentError, /kinds/)
    end

    it "失敗の応答は、YouTube のエラーの形（error.code・message・errors[].domain・reason）" do
      api.fail_next(:live_not_enabled)

      error = parsed(call(:get, "channels", query: { part: "snippet", mine: "true" })).fetch("error")

      expect(error).to include("code" => 403)
      expect(error.fetch("errors").first).to include("reason" => "liveStreamingNotEnabled", "domain" => "youtube.liveBroadcast")
    end
  end

  describe "force_life_cycle_status" do
    it "配信の状態を、指定した値に固定する（8 値のどれか）。以後は、時間が進んでも変わらない" do
      id = create_broadcast
      api.force_life_cycle_status(id, "revoked")
      advance(3600)

      expect(life_cycle_status(id)).to eq("revoked")
    end

    it "存在しない配信・未知の状態は ArgumentError" do
      id = create_broadcast

      expect { api.force_life_cycle_status("fake-bc-99", "live") }.to raise_error(ArgumentError, /broadcast/)
      expect { api.force_life_cycle_status(id, "bogus") }.to raise_error(ArgumentError, /status/)
    end
  end

  describe "reset! と共有" do
    it "reset! で、配信・ストリーム・注入・識別子の番号を初期状態へ戻す" do
      create_broadcast
      create_stream
      api.fail_next(:transient)

      api.reset!

      expect(create_broadcast).to eq("fake-bc-1")
      expect(create_stream).to eq("fake-stream-1")
      expect(call(:get, "channels", query: { part: "snippet", mine: "true" }).status).to eq(200)
    end

    it "スレッドセーフ: 多数のスレッドが同時に作成しても、識別子は重ならない" do
      ids = Array.new(8) { Thread.new { Array.new(10) { create_broadcast } } }.flat_map(&:value)

      expect(ids.uniq.size).to eq(80)
      expect(ids.sort_by { |id| id.split("-").last.to_i }.last).to eq("fake-bc-80")
    end
  end

  describe "構築" do
    it "取り込み先は RTMPS のみ（scheme が rtmps でなければ ArgumentError）。時計は呼び出し可能なもの" do
      expect { described_class.new(api_base: base, ingest: ingest.merge(scheme: "rtmp"), clock: clock, live_after_seconds: 5, channel_title: "x") }.to raise_error(ArgumentError, /scheme/)
      expect { described_class.new(api_base: base, ingest: ingest, clock: 1, live_after_seconds: 5, channel_title: "x") }.to raise_error(ArgumentError, /clock/)
      expect { described_class.new(api_base: base, ingest: ingest, clock: clock, live_after_seconds: 0, channel_title: "x") }.to raise_error(ArgumentError, /live_after_seconds/)
      expect { described_class.new(api_base: base, ingest: ingest, clock: clock, live_after_seconds: 5, channel_title: "") }.to raise_error(ArgumentError, /channel_title/)
    end

    it "inspect は中身を出さない" do
      create_stream

      expect(api.inspect).to eq("#<FakeYouTubeGateway::Api>")
    end
  end
end
