# 疑似の YouTube の窓口（issue #10）。開発・テストのみ。YouTubeGateway と同じインターフェース・同じ経路で、YouTube を呼ばずに動く。
#
# YouTubeGateway の子で、HTTP の送り先だけを、疑似の YouTube（FakeYouTubeGateway::Api。メモリの上）に置き換える。したがって、
# アクセストークンの取得（TokenVault）・台帳への記帳（実物と同じ単価）・トランザクションの検査・エラーの分類・応答の解釈は、実物と同じコードを通る。
# 選択は環境の判定（AppEnvironment#external_services。YouTubeServices）で行い、本番では構築できない（FakeServices.verify_environment!）。
#
# 疑似だけの公開メソッド
#   fail_next(error, on:, times:)            失敗の注入。次の呼び出しだけ失敗させる（テストと開発の両方から指定できる）
#                                            error: live_not_enabled・live_streaming_restricted・insufficient_permissions・broadcast_limit_exceeded・
#                                            quota_exceeded・rate_limited・transient・timeout・not_found・already_terminal・not_allowed・no_channel・
#                                            unexpected_response（YouTube の応答として返る。窓口の分類を通る）、
#                                            token_revoked・token_temporarily_unavailable（アクセストークンの取得の失敗。TokenVault を通る）
#                                            on: 公開メソッドの名前（bind・ensure_stream など）か、内部の種別（check_stream・create_stream など）。省略は、どの呼び出しでも
#   force_life_cycle_status(id, status)      配信の状態を、8 値のどれかに固定する（遷移中で止まった配信など）
#   set_stream_health(id, status:, error_types:)   ストリームの健全性を上書きする
#   reset!                                   疑似の YouTube・注入・トークンの番号を初期状態へ戻す
#   api                                      疑似の YouTube（状態の確認用）
#
# 疑似の YouTube の状態は、Api のインスタンスにある（メモリにだけ置く）。開発の常駐プロセスでは、YouTubeServices が、プロセスで 1 つの Api を共有する
# （要求ごとに窓口を作っても、状態が続く）。別のプロセスからの注入は、できない（同じプロセスの API。開発用のエンドポイントは、この issue の範囲外）。
class FakeYouTubeGateway < YouTubeGateway
  # 公開メソッドの名前 -> その呼び出しが行う HTTP 呼び出しの種別
  PUBLIC_CALLS = {
    insert_broadcast: %i[ insert_broadcast ],
    list_unstarted_broadcasts: %i[ list_unstarted_broadcasts ],
    ensure_stream: %i[ check_stream create_stream ],
    bind: %i[ bind ],
    fetch_status: %i[ fetch_status ],
    fetch_stream_health: %i[ fetch_stream_health ],
    complete: %i[ complete ],
    delete: %i[ delete ],
    probe_channel: %i[ probe_channel_lookup probe_live_enabled ]
  }.freeze

  # アクセストークンの取得の失敗の注入の名前 -> 疑似の Google のトークンエンドポイントの注入の名前（FakeGoogleTokenClient）
  TOKEN_FAILURES = {
    token_revoked: :token_revoked,
    token_temporarily_unavailable: :token_unavailable
  }.freeze

  attr_reader :api

  # api は FakeYouTubeGateway::Api。token_client（疑似の Google）・access_token_cache は、トークンの失敗を注入するときに要る
  # （注入を、キャッシュ済みのアクセストークンに邪魔されず、次の呼び出しで効かせるため、キャッシュを捨てる）
  def initialize(token_vault:, api:, api_base:, stream_title:, token_client: nil, access_token_cache: nil, environment: AppEnvironment.current,
                 clock: SystemClock.method(:now), logger: Rails.logger)
    FakeServices.verify_environment!(environment)
    raise ArgumentError, "api must be a FakeYouTubeGateway::Api" unless api.is_a?(Api)

    super(http: api, token_vault: token_vault, api_base: api_base, stream_title: stream_title, environment: environment, clock: clock, logger: logger)
    @api = api
    @token_client = token_client
    @access_token_cache = access_token_cache
  end

  # 次の呼び出しだけ、失敗させる（times 回）。on は、公開メソッドの名前か、内部の種別（省略は、どの呼び出しでも）。
  # トークンの失敗（token_revoked・token_temporarily_unavailable）は、呼び出しの種別で限れない（トークンは、どの呼び出しの前にも取得する）
  def fail_next(error, on: nil, times: 1)
    return fail_next_token(error, on, times) if TOKEN_FAILURES.key?(error)

    @api.fail_next(error, kinds: kinds_for(on), times: times)
  end

  def force_life_cycle_status(youtube_broadcast_id, status)
    @api.force_life_cycle_status(youtube_broadcast_id, status)
  end

  def set_stream_health(youtube_stream_id, status:, error_types: [])
    @api.set_stream_health(youtube_stream_id, status: status, error_types: error_types)
  end

  def reset!
    @api.reset!
    @token_client&.reset!
    @access_token_cache&.clear
    nil
  end

  private

  # YouTube への HTTP の代わりに、疑似の YouTube へ渡す（呼び出しの種別つき。失敗の注入の対象を決める）
  def perform_request(kind, http_method, url, headers, body)
    @api.handle(kind, http_method, url, headers, body)
  end

  def fail_next_token(error, on, times)
    raise ArgumentError, "on cannot limit a token failure (the token is fetched before every call)" unless on.nil?
    raise ArgumentError, "token_client is required to inject a token failure" if @token_client.nil?

    @token_client.fail_next(TOKEN_FAILURES.fetch(error), times: times)
    @access_token_cache&.clear
    nil
  end

  # on -> HTTP 呼び出しの種別の配列（nil は、どの呼び出しでも）
  def kinds_for(on)
    return nil if on.nil?
    return PUBLIC_CALLS.fetch(on) if PUBLIC_CALLS.key?(on)
    return [ on ] if Calls::TABLE.key?(on)

    raise ArgumentError, "on must be a public call (#{PUBLIC_CALLS.keys.join(', ')}) or a call kind"
  end
end
