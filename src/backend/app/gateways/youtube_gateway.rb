require "json"
require "zlib"

# YouTube Data API の単一の窓口（issue #10。requirements.md 6.1・8.4・10.1〜10.6・24.2）。
#
# アプリケーションから YouTube への HTTP 呼び出しは、すべて、このクラスの 1 つの経路（call）を通る。ほかのコードは、YouTube へ HTTP を送らない
# （スペック spec/sources/youtube_gateway_sources_spec.rb が app/ を走査して確かめる）。外部サービスへの HTTP は ExternalHttp
# （接続 3 秒・読み取り 5 秒・リダイレクトを追わない・再送しない）を通す。
#
# 24.2 のメソッド（配信に属する呼び出しは、配信レコード broadcast: を渡す。台帳へ、その配信の予約から記帳するため）
#   insert_broadcast(conn, params, broadcast:)                   配信の作成。配信の識別子を返す
#   list_unstarted_broadcasts(conn, broadcast:)                  未開始の配信の一覧（応答喪失時の引き継ぎ用。10.1）
#   ensure_stream(conn, broadcast:)                              配信用ストリームの確認（保存した識別子で）。無い・無効な場合のみ作成。取り込み先と配信キーを返す
#   bind(conn, youtube_broadcast_id, youtube_stream_id, broadcast:)     配信とストリームの紐づけ
#   fetch_status(conn, youtube_broadcast_id, broadcast:, bucket:)       配信の状態（YouTubeStatus。存在しない = not_found）
#   fetch_stream_health(conn, youtube_stream_id, broadcast:)    ストリームの健全性（StreamHealth）
#   complete(conn, youtube_broadcast_id, broadcast:, bucket:)   完了への遷移
#   delete(conn, youtube_broadcast_id, broadcast:, bucket:)     配信の削除
#   probe_channel(conn, access_token: nil)                       接続時の確認（チャンネルの有無・チャンネル名・ライブ配信が有効か。7.2）
# bucket: は、枠が 2 つある呼び出し（状態確認・完了への遷移・削除）だけ。終了・清算の用途は :settle、準備・確認・先行配信の清算は :prep。省略できない。
#
# 呼び出しごとの手順（call）
#   1. 引数の検査（ArgumentError）。呼び出し側のトランザクションの内側では呼べない（InsideTransaction。下記）
#   2. アクセストークンを TokenVault から得る（失敗したら、記帳せず、そのまま伝える。YouTube を呼んでいないので、実費は無い）
#   3. 割り当て台帳へ記帳する（QuotaLedger#spend!・spend_common!）。枠が足りなければ、HTTP を呼ばず QuotaInsufficient
#   4. HTTP を 1 回だけ送る。HTTP が失敗（4xx・5xx・タイムアウト）でも、実費は記帳済み
#   5. 応答を解釈する。エラーは YouTubeErrors.classify で型付きの例外にする。quotaExceeded は、台帳に超過の印を付けてから QuotaExceeded を投げる
#
# 記帳は、HTTP の前に、独立した短いトランザクションで確定させる。QuotaLedger の記帳は、呼び出し側のトランザクションに参加するので、
# 呼び出し側のトランザクションの内側で呼ぶと、HTTP が失敗して巻き戻ったときに、YouTube で消費済みの実費の記帳まで消える。
# 台帳の行ロックを、HTTP の待ち時間のあいだ持ち続けることにもなる。そこで、内側で呼ばれたら、InsideTransaction にする。
# 記帳は呼び出しの前なので、結果が分からない。明細の result は ok 固定（失敗した呼び出しの明細も ok で残る。実費は記帳済み）。
#
# 窓口は、接続の状態を変えない。変えるかどうかは、例外の disposition（YouTubeErrors）を見て、呼び出し側が決める。
# 配信キー・トークン・タイトル・チャンネル名を、ログ・例外・台帳の明細・inspect に出さない。ログは、符号と内部の識別子だけ。
# 窓口は状態を持たない（スレッドセーフ）。実時計を読まない（時刻は clock から得る）。
class YouTubeGateway
  LOG_TAG = "[youtube_gateway]".freeze
  # 配信の開始予定時刻は、作成時点から 1 分後（10.1）
  SCHEDULED_START_OFFSET_SECONDS = 60
  # 台帳の明細の result。記帳は呼び出しの前に行うので、結果が分からない（失敗しても ok）
  BOOKED_RESULT = "ok".freeze
  JSON_CONTENT_TYPE = "application/json".freeze
  UNAUTHORIZED_STATUS = 401
  SUCCESS_STATUSES = (200..299)
  # 未開始の配信の一覧で取る件数（1 ページ。YouTube の上限）。8.4 の支出は 1 回の取得（1 ユニット）なので、次のページは引かない
  UNSTARTED_MAX_RESULTS = "50".freeze
  # ライブ配信が有効でないことを表す例外（ライブ未有効・制限中。7.2・10.6）
  LIVE_DISABLED_ERRORS = [ YouTubeErrors::LiveNotEnabled, YouTubeErrors::LiveStreamingRestricted ].freeze

  # 呼び出し側のトランザクションの内側で呼ばれた（記帳が、HTTP の失敗で巻き戻る・台帳の行ロックを HTTP の待ちのあいだ持つ）
  class InsideTransaction < StandardError
    def initialize(kind)
      super("youtube gateway call #{kind} must be made outside of a database transaction")
    end
  end

  # 配信の開始予定時刻（作成時点 now から 1 分後。10.1）。呼び出し側が、配信レコードに保存してから渡す
  # （応答を受け取れなかったとき、タイトルと開始予定時刻の一致で、作成済みの配信を引き継ぐため）
  def self.scheduled_start_time(now)
    Preconditions.time!(now, "now") + SCHEDULED_START_OFFSET_SECONDS
  end

  # http は ExternalHttp（request に応える）、token_vault は TokenVault（access_token・forget_access_token に応える）、
  # api_base は YouTube Data API の基底の URL（https。末尾の / なし。設定ファイルの youtube.api_base）、stream_title は配信用ストリームの名前、
  # environment は取り込み先の検証（疑似の取り込み口を許す環境か）、clock は現在の時刻を返す呼び出し可能なもの
  def initialize(http:, token_vault:, api_base:, stream_title:, environment: AppEnvironment.current, clock: SystemClock.method(:now), logger: Rails.logger)
    raise ArgumentError, "http must respond to request" unless http.respond_to?(:request)
    raise ArgumentError, "token_vault is required" if token_vault.nil?
    raise ArgumentError, "api_base must be an https URL without a trailing slash" unless api_base.is_a?(String) && api_base.start_with?("https://") && !api_base.end_with?("/")
    raise ArgumentError, "stream_title must be a non-empty String" unless stream_title.is_a?(String) && !stream_title.strip.empty?
    raise ArgumentError, "environment must be an AppEnvironment" unless environment.is_a?(AppEnvironment)
    raise ArgumentError, "clock must respond to call" unless clock.respond_to?(:call)

    @http = http
    @token_vault = token_vault
    @api_base = api_base
    @stream_title = stream_title
    @environment = environment
    @clock = clock
    @logger = logger
  end

  # 配信を作成する。params は title・privacy_status・made_for_kids・scheduled_start_time（過不足は ArgumentError）。配信の識別子を返す
  def insert_broadcast(conn, params, broadcast:)
    fields = Requests.broadcast_params!(params)

    call(method: :insert_broadcast, conn: conn, broadcast: broadcast, query: { part: Requests::BROADCAST_PARTS }, json: Requests.broadcast_body(fields)) do |payload|
      Responses.broadcast_id(payload, :insert_broadcast)
    end
  end

  # 未開始の配信の一覧（UnstartedBroadcast の配列）。応答喪失時に、タイトルと開始予定時刻が一致するものを引き継ぐ（10.1）
  def list_unstarted_broadcasts(conn, broadcast:)
    query = { part: "id,snippet,status", broadcastStatus: "upcoming", maxResults: UNSTARTED_MAX_RESULTS }

    call(method: :list_unstarted_broadcasts, conn: conn, broadcast: broadcast, query: query) do |payload|
      Responses.unstarted_broadcasts(payload, :list_unstarted_broadcasts)
    end
  end

  # 配信用ストリームの接続情報（StreamInfo）。保存した識別子（conn.youtube_stream_id）で確認し、無い・無効な場合のみ作成する。
  # チャンネルの既存のストリームを一覧して再利用しない。保存は、呼び出し側が行う（窓口は、接続の行を書き換えない）
  def ensure_stream(conn, broadcast:)
    require_connection!(conn)
    stored = conn.youtube_stream_id
    existing = stored.present? ? check_stream(conn, broadcast, Requests.id!(stored, "youtube_stream_id")) : nil

    existing || create_stream(conn, broadcast)
  end

  # 配信とストリームを紐づける。成功は true
  def bind(conn, youtube_broadcast_id, youtube_stream_id, broadcast:)
    broadcast_id = Requests.id!(youtube_broadcast_id, "youtube_broadcast_id")
    stream_id = Requests.id!(youtube_stream_id, "youtube_stream_id")
    query = { id: broadcast_id, streamId: stream_id, part: "id,contentDetails" }

    call(method: :bind, conn: conn, broadcast: broadcast, query: query) { |payload| Responses.bound_broadcast!(payload, :bind, broadcast_id) }
    true
  end

  # 配信の状態（YouTubeStatus）。存在しない（空の応答・404）は YouTubeStatus.not_found
  def fetch_status(conn, youtube_broadcast_id, broadcast:, bucket: nil)
    id = Requests.id!(youtube_broadcast_id, "youtube_broadcast_id")

    call(method: :fetch_status, conn: conn, broadcast: broadcast, bucket: bucket, query: { part: "id,status", id: id }, tolerate: [ YouTubeErrors::NotFound ]) do |payload|
      Responses.status(payload, :fetch_status, id)
    end
  rescue YouTubeErrors::NotFound
    YouTubeStatus.not_found
  end

  # ストリームの健全性（StreamHealth）。ストリームが存在しなければ YouTubeErrors::NotFound
  def fetch_stream_health(conn, youtube_stream_id, broadcast:)
    id = Requests.id!(youtube_stream_id, "youtube_stream_id")

    call(method: :fetch_stream_health, conn: conn, broadcast: broadcast, query: { part: "id,status", id: id }) do |payload|
      Responses.stream_health(payload, :fetch_stream_health, id)
    end
  end

  # 完了へ遷移させる（遷移は非同期。要求の受理を成功とする）。成功は true
  def complete(conn, youtube_broadcast_id, broadcast:, bucket: nil)
    id = Requests.id!(youtube_broadcast_id, "youtube_broadcast_id")
    query = { broadcastStatus: "complete", id: id, part: "status" }

    call(method: :complete, conn: conn, broadcast: broadcast, bucket: bucket, query: query, parse: false)
    true
  end

  # 配信を削除する。成功は true
  def delete(conn, youtube_broadcast_id, broadcast:, bucket: nil)
    id = Requests.id!(youtube_broadcast_id, "youtube_broadcast_id")

    call(method: :delete, conn: conn, broadcast: broadcast, bucket: bucket, query: { id: id }, parse: false)
    true
  end

  # 接続時の確認（7.2）。チャンネルの有無と、ライブ配信が有効かを、各 1 ユニットの一覧取得で確認する（共通枠から支出する）。
  #   チャンネルが無い（空の一覧・youtubeSignupRequired・channelNotFound）           -> no_channel
  #   配信の一覧取得が、ライブ未有効・制限中のエラーを返す                            -> live_not_enabled（チャンネル名つき）
  #   どちらでもない                                                                 -> connected（チャンネル名つき）
  # 確認不能（共通枠の枯渇・一時的な失敗・想定外の応答）は、結果にせず、型付きの例外を投げる。
  # access_token を渡すと、TokenVault を使わず、そのトークンで確認する（接続の成立前。接続の行はまだ無いので、conn は nil でよい）
  def probe_channel(conn, access_token: nil)
    title = lookup_channel(conn, access_token)
    return ProbeResult.new(outcome: Contract::ConnectResult::NO_CHANNEL, channel_title: nil) if title.nil?

    outcome = live_enabled?(conn, access_token) ? Contract::ConnectResult::CONNECTED : Contract::ConnectResult::LIVE_NOT_ENABLED
    ProbeResult.new(outcome: outcome, channel_title: title)
  end

  # 依存するもの（トークンの保管庫・HTTP）を出さない
  def inspect
    "#<#{self.class.name}>"
  end

  private

  # --- ensure_stream・probe_channel の部品 ---

  # 保存した識別子で確認する。有効なら StreamInfo、無効（空の一覧・404）なら nil。一時的な失敗などは、そのまま伝える（無効と取り違えない）
  def check_stream(conn, broadcast, stored_id)
    call(method: :check_stream, conn: conn, broadcast: broadcast, query: { part: "id,cdn,status", id: stored_id }, tolerate: [ YouTubeErrors::NotFound ]) do |payload|
      item = Responses.stream_item(payload, :check_stream, stored_id)
      item && Responses.stream_info(item, :check_stream, created: false, environment: @environment)
    end
  rescue YouTubeErrors::NotFound
    nil
  end

  def create_stream(conn, broadcast)
    call(method: :create_stream, conn: conn, broadcast: broadcast, query: { part: Requests::STREAM_PARTS }, json: Requests.stream_body(@stream_title)) do |payload|
      Responses.stream_info(payload, :create_stream, created: true, environment: @environment)
    end
  end

  # チャンネル名。チャンネルが無ければ nil
  def lookup_channel(conn, access_token)
    call(method: :probe_channel_lookup, conn: conn, broadcast: nil, query: { part: "snippet", mine: "true" }, access_token: access_token, tolerate: [ YouTubeErrors::NoChannel ]) do |payload|
      Responses.channel_title(payload, :probe_channel_lookup)
    end
  rescue YouTubeErrors::NoChannel
    nil
  end

  # ライブ配信が有効か。配信の一覧取得が、ライブ未有効・制限中のエラーを返せば false（7.2）
  def live_enabled?(conn, access_token)
    query = { part: "id", mine: "true", maxResults: "1" }
    call(method: :probe_live_enabled, conn: conn, broadcast: nil, query: query, access_token: access_token, tolerate: LIVE_DISABLED_ERRORS) { true }
  rescue *LIVE_DISABLED_ERRORS
    false
  end

  # --- 1 つの経路 ---

  # すべての YouTube への呼び出しの経路。method は Calls の種別、bucket は枠が 2 つある呼び出しの枠、query は URL のクエリ、
  # json は JSON の本文（nil なら本文なし）、access_token は呼び出し側が渡すトークン（TokenVault を使わない）、
  # tolerate は「想定した結果」として扱う例外（失敗の警告ログにしない。投げる動作は同じ）、
  # parse は成功の応答の本文を JSON として解釈するか。ブロックは、成功の応答（解釈した JSON）を値にする。
  # ブロックの中の UnexpectedResponse も、ほかの失敗と同じように記録する。
  def call(method:, conn:, broadcast:, bucket: nil, query: {}, json: nil, access_token: nil, tolerate: [], parse: true, &interpret)
    spec = Calls.fetch(method)
    pool = spec.resolve_bucket(bucket)
    check_actors!(spec, conn, broadcast, access_token)
    ensure_outside_transaction!(method)

    now = current_time
    token = access_token || @token_vault.access_token(user_id: conn.user_id, now: now)
    book!(spec, pool, broadcast, now)
    response = transmit(spec, token, query, json)
    respond(spec, response, now, conn, parse, &interpret)
  rescue YouTubeErrors::Base => error
    log_failure(method, error, conn, broadcast, tolerated: tolerate.any? { |error_class| error.is_a?(error_class) })
    raise
  end

  # 台帳へ記帳する。枠が足りなければ QuotaInsufficient（HTTP を呼ばない）。記帳は、呼び出し側のトランザクションの外で、独立して確定する
  def book!(spec, pool, broadcast, now)
    granted =
      if pool == :common
        QuotaLedger.spend_common!(method: spec.api_method, units: spec.units, quota_date: UsageCalendar.quota_date(now), result: BOOKED_RESULT, now: now)
      else
        QuotaLedger.spend!(broadcast, method: spec.api_method, units: spec.units, bucket: pool, result: BOOKED_RESULT, now: now)
      end
    raise YouTubeErrors::QuotaInsufficient.new(call_kind: spec.kind, bucket: pool) unless granted
  end

  # HTTP を 1 回送る。通信の失敗は、型付きの例外にする（ExternalHttp は Zlib::Error を受け止めないので、ここで受ける）
  def transmit(spec, token, query, json)
    url = url_for(spec, query)
    headers = { "Authorization" => "Bearer #{token}" }
    body = nil
    if json
      headers["Content-Type"] = JSON_CONTENT_TYPE
      body = JSON.generate(json)
    elsif spec.http_method == :post
      body = "" # 本文なしの POST は、Content-Length: 0 を送る
    end

    perform_request(spec.kind, spec.http_method, url, headers, body)
  rescue ExternalHttp::Failure => failure
    raise communication_error(spec.kind, failure)
  rescue Zlib::Error
    raise YouTubeErrors::UnexpectedResponse.new(call_kind: spec.kind, detail: :invalid_encoding)
  end

  # 要求の URL。基底の URL・API のパス・クエリ（部分の値は、パーセントエンコードする）
  def url_for(spec, query)
    base = "#{@api_base}/#{spec.path}"
    query.empty? ? base : "#{base}?#{URI.encode_www_form(query)}"
  end

  # YouTube へ HTTP を送る唯一の場所。疑似の窓口（FakeYouTubeGateway）は、これを置き換える
  def perform_request(_kind, http_method, url, headers, body)
    @http.request(http_method, url, headers: headers, body: body)
  end

  def respond(spec, response, now, conn, parse, &interpret)
    raise failure_for(spec, response, now, conn) unless SUCCESS_STATUSES.cover?(response.status)

    payload = parse ? success_payload(response, spec.kind) : nil
    interpret ? interpret.call(payload) : payload
  end

  # 成功の応答の本文（JSON）。本文が無ければ nil（204 など）
  def success_payload(response, kind)
    return nil if response.body.to_s.strip.empty?

    response.json
  rescue ExternalHttp::Failure => failure
    raise YouTubeErrors::UnexpectedResponse.new(call_kind: kind, detail: failure.reason)
  end

  # 失敗の応答を、型付きの例外にする（投げずに返す）。応答の本文は、例外に載せない
  def failure_for(spec, response, now, conn)
    error = YouTubeErrors.classify(status: response.status, payload: error_payload(response), call_kind: spec.kind)
    # 台帳の計上に反して、割り当て超過が返った: 当該割り当て日の終わりまで、新規受付を停止する（8.4）
    QuotaLedger.mark_exhausted!(quota_date: UsageCalendar.quota_date(now)) if error.is_a?(YouTubeErrors::QuotaExceeded)
    # トークンを拒否された: メモリ上のアクセストークンを捨てる（次の呼び出しで、更新トークンから取得し直す。失効なら TokenRevoked になる）
    @token_vault.forget_access_token(user_id: conn.user_id) if response.status == UNAUTHORIZED_STATUS && conn
    error
  end

  # 失敗の応答の本文（解釈した JSON）。解釈できなければ nil
  def error_payload(response)
    response.json
  rescue ExternalHttp::Failure
    nil
  end

  def communication_error(kind, failure)
    case failure.reason
    when :timeout then YouTubeErrors::Timeout.new(call_kind: kind, detail: :timeout)
    when :connection, :tls then YouTubeErrors::Transient.new(call_kind: kind, detail: failure.reason)
    else YouTubeErrors::UnexpectedResponse.new(call_kind: kind, detail: failure.reason)
    end
  end

  # --- 検査 ---

  def check_actors!(spec, conn, broadcast, access_token)
    unless access_token.nil? || (access_token.is_a?(String) && GoogleTokenClient::TOKEN_PATTERN.match?(access_token))
      raise ArgumentError, "access_token must be a printable token without whitespace"
    end

    if spec.common?
      raise ArgumentError, "connection is required unless access_token is given" if conn.nil? && access_token.nil?

      require_connection!(conn) unless conn.nil?
    else
      require_connection!(conn)
      require_broadcast!(broadcast)
      raise ArgumentError, "broadcast does not belong to the account of the connection" unless broadcast.user_id == conn.user_id
    end
  end

  def require_connection!(conn)
    raise ArgumentError, "connection must be a persisted YoutubeConnection" unless conn.is_a?(YoutubeConnection) && conn.persisted?
  end

  def require_broadcast!(broadcast)
    raise ArgumentError, "broadcast must be a persisted Broadcast" unless broadcast.is_a?(Broadcast) && broadcast.persisted?
  end

  def ensure_outside_transaction!(kind)
    inside = ApplicationRecord.with_connection { |connection| connection.current_transaction.joinable? }
    raise InsideTransaction.new(kind) if inside
  end

  def current_time
    now = @clock.call
    raise ArgumentError, "clock must return a Time" unless now.is_a?(Time)

    now
  end

  # --- ログ（符号と内部の識別子だけ） ---

  def log_failure(kind, error, conn, broadcast, tolerated:)
    if tolerated
      @logger.debug("#{LOG_TAG} outcome call=#{kind} class=#{error.class.name.demodulize}")
      return
    end

    fields = [
      "call=#{kind}",
      (broadcast.is_a?(Broadcast) && broadcast.persisted? ? "broadcast_id=#{broadcast.id}" : nil),
      (conn.is_a?(YoutubeConnection) ? "user_id=#{conn.user_id}" : nil),
      "class=#{error.class.name.demodulize}",
      (error.status ? "status=#{error.status}" : nil),
      (error.reason ? "reason=#{error.reason}" : nil),
      (error.detail ? "detail=#{error.detail}" : nil)
    ]
    @logger.warn("#{LOG_TAG} failed #{fields.compact.join(' ')}")
  end
end
