require "json"
require "uri"

class FakeYouTubeGateway
  # 疑似の YouTube Data API（issue #10）。開発・テストのみ（FakeYouTubeGateway が、環境を検査してから作る）。
  # メモリの上で、YouTube の応答の形（liveBroadcasts・liveStreams・channels・bind・transition・エラー）を再現する。窓口（YouTubeGateway）は、
  # HTTP の代わりに、これへ要求を渡す。したがって、台帳への記帳・アクセストークンの取得・エラーの分類・応答の解釈は、実物と同じ経路を通る。
  #
  #   識別子        決定的。配信 fake-bc-N、ストリーム fake-stream-N、配信キー fake-key-N（N は 1 から）
  #   取り込み先    契約 dev_ingest（設定ファイルの youtube.dev_ingest）の疑似の取り込み口。RTMPS（rtmps://fake-ingest:1935/live2）。
  #                 平文の RTMP とバックアップの形も返す（窓口は、RTMPS の主系だけを選ぶ）
  #   配信の状態    created -> ready（紐づけ後）-> live（紐づけから live_after_seconds 後。既定 5 秒。時計は注入）-> complete
  #                 force_life_cycle_status で、8 値のどれかに固定できる（遷移中で止まった配信など）
  #   part          尊重する（返す項目・受け付ける指定）。contentDetails を part に含めないと、自動開始・自動停止・モニター無効の指定が捨てられて
  #                 既定になる（モニター有効・自動開始なし。YouTube と同じ）。この場合、紐づけても、ライブにならない
  #   失敗の注入    fail_next（次の呼び出しだけ。呼び出しの種別で限れる）。HTTP のエラー応答として返す（窓口の分類を通る）。timeout は ExternalHttp::Failure
  #
  # 要求は ExternalHttp と同じ形（HTTP メソッド・URL・ヘッダ・本文）で受け、ExternalHttp::Response を返す。未知のパスは 400（unknownEndpoint）。
  # 404 にしない（窓口の実装の誤りが、「存在しない」＝清算済みと取り違えられないように）。スレッドセーフ（1 本の排他）。状態はメモリにだけ置く。
  class Api
    RESPONSE_HEADERS = { "content-type" => "application/json; charset=UTF-8" }.freeze
    BROADCAST_ID_PREFIX = "fake-bc-".freeze
    STREAM_ID_PREFIX = "fake-stream-".freeze
    STREAM_KEY_PREFIX = "fake-key-".freeze
    # 取り込み先のアプリ名（YouTube は live2）
    INGEST_APP = "live2".freeze
    TITLE_LENGTH = (1..100)
    DEFAULT_MAX_RESULTS = 5
    MAX_RESULTS_LIMIT = 50
    BEARER_PREFIX = "Bearer ".freeze
    # 未開始（upcoming）の配信の状態
    UPCOMING_STATUSES = [ SettlementRules::LifeCycleStatus::CREATED, SettlementRules::LifeCycleStatus::READY ].freeze

    # 失敗の注入の名前（YouTubeErrors のクラス名の snake_case）-> [HTTP ステータス, reason]。timeout だけは、HTTP の応答ではなく、通信の失敗
    FAILURES = {
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
    }.freeze
    TIMEOUT = :timeout
    INJECTIONS = (FAILURES.keys + [ TIMEOUT ]).freeze

    # 注入 1 件。kinds が nil なら、どの呼び出しにも当たる
    Injection = Struct.new(:error, :kinds, :remaining)
    private_constant :Injection

    def initialize(api_base:, ingest:, clock:, live_after_seconds:, channel_title:)
      raise ArgumentError, "clock must respond to call" unless clock.respond_to?(:call)
      raise ArgumentError, "live_after_seconds must be a positive Integer" unless live_after_seconds.is_a?(Integer) && live_after_seconds.positive?
      raise ArgumentError, "channel_title must be a non-empty String" unless channel_title.is_a?(String) && !channel_title.strip.empty?
      raise ArgumentError, "the scheme of ingest must be #{IngestDestination::SCHEME}" unless ingest.fetch(:scheme) == IngestDestination::SCHEME

      @api_base = api_base
      @host = URI.parse(api_base).host
      @base_path = URI.parse(api_base).path
      @ingest = "#{ingest.fetch(:scheme)}://#{ingest.fetch(:host)}:#{ingest.fetch(:port)}/#{INGEST_APP}"
      @plain_ingest = "rtmp://#{ingest.fetch(:host)}:#{ingest.fetch(:port)}/#{INGEST_APP}"
      @clock = clock
      @live_after_seconds = live_after_seconds
      @channel_title = channel_title
      @mutex = Mutex.new
      reset_state
    end

    # ExternalHttp#request と同じ入口（呼び出しの種別を渡さない）
    def request(http_method, url, headers: {}, body: nil)
      handle(nil, http_method, url, headers, body)
    end

    # 要求を処理して ExternalHttp::Response を返す。kind は窓口の呼び出しの種別（失敗の注入の対象を決める。不明なら nil）
    def handle(kind, http_method, url, headers, body)
      @mutex.synchronize { dispatch(kind, http_method, url, headers, body) }
    end

    # 次の呼び出し（kinds に当たるもの。nil ならどれでも）を、times 回、失敗させる。error は INJECTIONS のどれか
    def fail_next(error, kinds: nil, times: 1)
      raise ArgumentError, "error must be one of #{INJECTIONS.inspect}" unless INJECTIONS.include?(error)
      raise ArgumentError, "times must be a positive Integer" unless times.is_a?(Integer) && times.positive?

      unless kinds.nil? || (kinds.is_a?(Array) && !kinds.empty? && kinds.all? { |kind| YouTubeGateway::Calls::TABLE.key?(kind) })
        raise ArgumentError, "kinds must be nil or a non-empty Array of call kinds"
      end

      @mutex.synchronize { @injections << Injection.new(error, kinds&.dup&.freeze, times) }
      nil
    end

    # 配信の状態を、8 値のどれかに固定する（以後、時間が進んでも変わらない）。完了への遷移・削除の判定にも使われる
    def force_life_cycle_status(youtube_broadcast_id, status)
      raise ArgumentError, "status must be a YouTube lifeCycleStatus" unless SettlementRules::LifeCycleStatus::ALL.include?(status)

      @mutex.synchronize do
        broadcast = @broadcasts[youtube_broadcast_id]
        raise ArgumentError, "broadcast does not exist" if broadcast.nil?

        broadcast[:forced_status] = status
      end
      nil
    end

    # ストリームの健全性を上書きする（status: good・ok・bad・noData。error_types: severity が error の設定の問題の type）
    def set_stream_health(youtube_stream_id, status:, error_types: [])
      raise ArgumentError, "status must be one of #{StreamHealth::STATUSES.inspect}" unless StreamHealth::STATUSES.include?(status)
      raise ArgumentError, "error_types must be an Array of codes" unless error_types.is_a?(Array) && error_types.all? { |type| type.is_a?(String) }

      @mutex.synchronize do
        stream = @streams[youtube_stream_id]
        raise ArgumentError, "stream does not exist" if stream.nil?

        stream[:health] = { status: status, error_types: error_types.dup }
      end
      nil
    end

    # 配信・ストリーム・注入・識別子の番号を、初期状態へ戻す
    def reset!
      @mutex.synchronize { reset_state }
      nil
    end

    # 作成済みの配信・ストリームの識別子（テストの確認用）
    def broadcast_ids
      @mutex.synchronize { @broadcasts.keys }
    end

    def stream_ids
      @mutex.synchronize { @streams.keys }
    end

    def inspect
      "#<#{self.class.name}>"
    end

    private

    def reset_state
      @broadcasts = {}
      @streams = {}
      @broadcast_count = 0
      @stream_count = 0
      @injections = []
    end

    # --- 入口 ---

    def dispatch(kind, http_method, url, headers, body)
      uri = parse_url(url)
      return error_response(400, "unknownEndpoint") if uri.nil?
      return error_response(401, "authError") unless bearer?(headers)

      injected = take_injection(kind)
      return injected if injected.is_a?(ExternalHttp::Response)

      route(http_method, uri.path.delete_prefix(@base_path).delete_prefix("/"), query_of(uri), body)
    end

    def route(http_method, path, params, body)
      case [ http_method, path ]
      when [ :post, "liveBroadcasts" ] then with_json(body) { |json| insert_broadcast(params, json) }
      when [ :get, "liveBroadcasts" ] then list_broadcasts(params)
      when [ :post, "liveBroadcasts/bind" ] then bind(params)
      when [ :post, "liveBroadcasts/transition" ] then transition(params)
      when [ :delete, "liveBroadcasts" ] then delete_broadcast(params)
      when [ :post, "liveStreams" ] then with_json(body) { |json| insert_stream(params, json) }
      when [ :get, "liveStreams" ] then list_streams(params)
      when [ :get, "channels" ] then list_channels(params)
      else error_response(400, "unknownEndpoint")
      end
    end

    def parse_url(url)
      uri = URI.parse(url)
      uri if uri.host == @host && uri.path.start_with?("#{@base_path}/")
    rescue URI::InvalidURIError
      nil
    end

    def query_of(uri)
      URI.decode_www_form(uri.query.to_s).to_h
    end

    def bearer?(headers)
      value = headers.is_a?(Hash) ? headers["Authorization"] : nil
      value.is_a?(String) && value.start_with?(BEARER_PREFIX) && !value.delete_prefix(BEARER_PREFIX).strip.empty?
    end

    def with_json(body)
      json = JSON.parse(body.to_s)
      return error_response(400, "parseError") unless json.is_a?(Hash)

      yield json
    rescue JSON::ParserError
      error_response(400, "parseError")
    end

    def parts_of(params)
      params["part"].to_s.split(",")
    end

    def now
      @clock.call
    end

    # --- 失敗の注入 ---

    # kind に当たる最初の注入を 1 回分消費する。HTTP のエラー応答、または（timeout は）通信の失敗の例外。無ければ nil
    def take_injection(kind)
      index = @injections.index { |injection| injection.kinds.nil? || (!kind.nil? && injection.kinds.include?(kind)) }
      return nil if index.nil?

      injection = @injections.fetch(index)
      injection.remaining -= 1
      @injections.delete_at(index) if injection.remaining.zero?
      raise ExternalHttp::Failure.new(:timeout, host: @host) if injection.error == TIMEOUT

      status, reason = FAILURES.fetch(injection.error)
      error_response(status, reason)
    end

    # --- 配信 ---

    def insert_broadcast(params, json)
      parts = parts_of(params)
      return error_response(400, "invalidPart") unless parts.include?("snippet") && parts.include?("status")

      snippet = json["snippet"].is_a?(Hash) ? json["snippet"] : {}
      status = json["status"].is_a?(Hash) ? json["status"] : {}
      title = snippet["title"]
      return error_response(400, "invalidTitle") unless title.is_a?(String) && TITLE_LENGTH.cover?(title.length) && !title.match?(/[<>]/)

      start = parse_time(snippet["scheduledStartTime"])
      return error_response(400, "invalidScheduledStartTime") unless start && start > now
      return error_response(400, "invalidPrivacyStatus") unless Broadcast::PRIVACY_STATUSES.include?(status["privacyStatus"])

      # contentDetails を part に含めないと、指定が捨てられて既定になる（YouTube と同じ）
      details = parts.include?("contentDetails") && json["contentDetails"].is_a?(Hash) ? json["contentDetails"] : {}
      id = "#{BROADCAST_ID_PREFIX}#{@broadcast_count += 1}"
      @broadcasts[id] = {
        id: id, title: title, scheduled_start_time: start.utc.iso8601, privacy_status: status["privacyStatus"],
        made_for_kids: status["selfDeclaredMadeForKids"] == true,
        auto_start: details["enableAutoStart"] == true, auto_stop: details["enableAutoStop"] == true,
        monitor: details.dig("monitorStream", "enableMonitorStream") != false,
        stream_id: nil, bound_at: nil, completed: false, forced_status: nil
      }
      json_response(broadcast_resource(@broadcasts.fetch(id), parts))
    end

    def list_broadcasts(params)
      parts = parts_of(params)
      return error_response(400, "invalidPart") if parts.empty?

      selected =
        if params.key?("id") then @broadcasts.values_at(*params["id"].split(",")).compact
        elsif params["broadcastStatus"] == "upcoming" then @broadcasts.values.select { |broadcast| UPCOMING_STATUSES.include?(life_cycle_status(broadcast)) }
        elsif params["mine"] == "true" then @broadcasts.values
        end
      return error_response(400, "missingFilter") if selected.nil?

      items = selected.first(max_results(params)).map { |broadcast| broadcast_resource(broadcast, parts) }
      json_response({ "kind" => "youtube#liveBroadcastListResponse", "items" => items })
    end

    def bind(params)
      broadcast = @broadcasts[params["id"]]
      return error_response(404, "liveBroadcastNotFound") if broadcast.nil?

      stream = @streams[params["streamId"]]
      return error_response(404, "liveStreamNotFound") if stream.nil?
      return error_response(403, "liveBroadcastBindingNotAllowed") if life_cycle_status(broadcast) == SettlementRules::LifeCycleStatus::COMPLETE

      broadcast[:stream_id] = stream.fetch(:id)
      broadcast[:bound_at] = now
      json_response(broadcast_resource(broadcast, parts_of(params)))
    end

    def transition(params)
      return error_response(400, "invalidRequest") unless params["broadcastStatus"] == "complete"

      broadcast = @broadcasts[params["id"]]
      return error_response(404, "liveBroadcastNotFound") if broadcast.nil?

      case life_cycle_status(broadcast)
      when SettlementRules::LifeCycleStatus::COMPLETE then error_response(403, "redundantTransition")
      when SettlementRules::LifeCycleStatus::LIVE, SettlementRules::LifeCycleStatus::TESTING
        broadcast[:completed] = true
        broadcast[:forced_status] = nil
        json_response(broadcast_resource(broadcast, parts_of(params)))
      else error_response(403, "invalidTransition")
      end
    end

    def delete_broadcast(params)
      broadcast = @broadcasts[params["id"]]
      return error_response(404, "liveBroadcastNotFound") if broadcast.nil?
      return error_response(403, "liveBroadcastDeletionNotAllowed") if life_cycle_status(broadcast) == SettlementRules::LifeCycleStatus::LIVE

      @broadcasts.delete(broadcast.fetch(:id))
      ExternalHttp::Response.new(status: 204, headers: {}.freeze, body: "", host: @host)
    end

    # 配信の状態。固定されていればそれ。完了済みは complete。紐づけ前は created。紐づけ後は ready で、自動開始なら紐づけから live_after_seconds 後に live
    def life_cycle_status(broadcast)
      return broadcast.fetch(:forced_status) if broadcast.fetch(:forced_status)
      return SettlementRules::LifeCycleStatus::COMPLETE if broadcast.fetch(:completed)
      return SettlementRules::LifeCycleStatus::CREATED if broadcast.fetch(:stream_id).nil?

      live = broadcast.fetch(:auto_start) && now >= broadcast.fetch(:bound_at) + @live_after_seconds
      live ? SettlementRules::LifeCycleStatus::LIVE : SettlementRules::LifeCycleStatus::READY
    end

    def broadcast_resource(broadcast, parts)
      resource = { "kind" => "youtube#liveBroadcast", "id" => broadcast.fetch(:id) }
      if parts.include?("snippet")
        resource["snippet"] = { "title" => broadcast.fetch(:title), "scheduledStartTime" => broadcast.fetch(:scheduled_start_time) }
      end
      if parts.include?("status")
        resource["status"] = {
          "lifeCycleStatus" => life_cycle_status(broadcast), "privacyStatus" => broadcast.fetch(:privacy_status),
          "selfDeclaredMadeForKids" => broadcast.fetch(:made_for_kids)
        }
      end
      if parts.include?("contentDetails")
        details = {
          "enableAutoStart" => broadcast.fetch(:auto_start), "enableAutoStop" => broadcast.fetch(:auto_stop),
          "monitorStream" => { "enableMonitorStream" => broadcast.fetch(:monitor) }
        }
        details["boundStreamId"] = broadcast.fetch(:stream_id) if broadcast.fetch(:stream_id)
        resource["contentDetails"] = details
      end
      resource
    end

    # --- ストリーム ---

    def insert_stream(params, json)
      parts = parts_of(params)
      return error_response(400, "invalidPart") unless parts.include?("snippet") && parts.include?("cdn")

      title = json.dig("snippet", "title") if json["snippet"].is_a?(Hash)
      return error_response(400, "invalidTitle") unless title.is_a?(String) && !title.strip.empty?

      cdn = json["cdn"].is_a?(Hash) ? json["cdn"] : {}
      return error_response(400, "invalidIngestionType") unless cdn["ingestionType"] == "rtmp"

      number = @stream_count += 1
      id = "#{STREAM_ID_PREFIX}#{number}"
      @streams[id] = { id: id, number: number, title: title, health: nil }
      json_response(stream_resource(@streams.fetch(id), parts))
    end

    def list_streams(params)
      parts = parts_of(params)
      return error_response(400, "invalidPart") if parts.empty?

      selected =
        if params.key?("id") then @streams.values_at(*params["id"].split(",")).compact
        elsif params["mine"] == "true" then @streams.values
        end
      return error_response(400, "missingFilter") if selected.nil?

      json_response({ "kind" => "youtube#liveStreamListResponse", "items" => selected.first(max_results(params)).map { |stream| stream_resource(stream, parts) } })
    end

    def stream_resource(stream, parts)
      resource = { "kind" => "youtube#liveStream", "id" => stream.fetch(:id) }
      resource["snippet"] = { "title" => stream.fetch(:title) } if parts.include?("snippet")
      resource["cdn"] = cdn_resource(stream) if parts.include?("cdn")
      resource["contentDetails"] = { "isReusable" => true } if parts.include?("contentDetails")
      resource["status"] = stream_status(stream) if parts.include?("status")
      resource
    end

    def cdn_resource(stream)
      {
        "ingestionType" => "rtmp", "resolution" => "variable", "frameRate" => "variable",
        "ingestionInfo" => {
          "streamName" => "#{STREAM_KEY_PREFIX}#{stream.fetch(:number)}",
          "ingestionAddress" => @plain_ingest, "backupIngestionAddress" => "#{@plain_ingest}?backup=1",
          "rtmpsIngestionAddress" => @ingest, "rtmpsBackupIngestionAddress" => "#{@ingest}?backup=1"
        }
      }
    end

    # ストリームの状態。紐づいた配信がライブなら active（健全性は good）。それ以外は ready（健全性の情報は無い = noData）。上書きがあればそれ
    def stream_status(stream)
      live = @broadcasts.values.any? { |broadcast| broadcast.fetch(:stream_id) == stream.fetch(:id) && life_cycle_status(broadcast) == SettlementRules::LifeCycleStatus::LIVE }
      override = stream.fetch(:health)
      health = override || { status: (live ? "good" : "noData"), error_types: [] }
      {
        "streamStatus" => live ? "active" : "ready",
        "healthStatus" => {
          "status" => health.fetch(:status),
          "configurationIssues" => health.fetch(:error_types).map { |type| { "type" => type, "severity" => "error", "reason" => "fake issue", "description" => "fake issue" } }
        }
      }
    end

    # --- チャンネル ---

    def list_channels(params)
      return error_response(400, "missingFilter") unless params["mine"] == "true"

      channel = { "kind" => "youtube#channel", "id" => "fake-channel" }
      channel["snippet"] = { "title" => @channel_title } if parts_of(params).include?("snippet")
      json_response({ "kind" => "youtube#channelListResponse", "items" => [ channel ] })
    end

    # --- 応答 ---

    def max_results(params)
      value = params["maxResults"]
      return DEFAULT_MAX_RESULTS if value.nil?

      value.to_i.clamp(0, MAX_RESULTS_LIMIT)
    end

    def parse_time(value)
      Time.iso8601(value) if value.is_a?(String)
    rescue ArgumentError
      nil
    end

    def json_response(body, status: 200)
      ExternalHttp::Response.new(status: status, headers: RESPONSE_HEADERS, body: JSON.generate(body), host: @host)
    end

    def error_response(status, reason)
      body = { "error" => { "code" => status, "message" => "fake error #{reason}", "errors" => [ { "domain" => "youtube.liveBroadcast", "reason" => reason, "message" => "fake error #{reason}" } ] } }
      json_response(body, status: status)
    end
  end
end
