# YouTube・Google の応答のエラー分類と、型付きの例外（issue #10。requirements.md 10.6・10.5・10.4・7.3）。
#
#   YouTubeErrors.classify(status:, payload:, call_kind:)  応答（HTTP ステータスと、解釈した JSON）を、型付きの例外へ分類する（投げない。例外を返す）
#
# 分類は、error.errors[].reason（エラーの理由の符号）の表引きで行う（REASON_CLASSES）。HTTP ステータスや種別だけでは誤る
# （403 が、権限・割り当て・遷移不可・配信数の上限を兼ねる。concurrentBroadcastsExceedLimit は種別が rateLimitExceeded だが、
# 再試行で解消しない上限である）。reason が表に無いときだけ、ステータスの規則（404・429・5xx）を使う。どちらにも当たらなければ
# UnexpectedResponse（黙って成功にしない。特定の失敗にもしない）。OAuth のトークンエンドポイントの形（error が文字列）も、同じ表で引く。
#
# 各例外は disposition（10.6 の「動作」）を持つ。呼び出し側（準備・ライブ中の確認・清算。#13）が表引きして、動く。
# 窓口（YouTubeGateway）は、状態を変えない。接続状態の更新は、YouTubeConnection のメソッドで、呼び出し側が行う
# （更新トークンの恒久的な失敗だけは、TokenVault が TokenRevoked を投げる前に、接続状態を revoked にする）。
#
# 機密を出さない。メッセージは、クラス名・呼び出しの種別・ステータス・reason の符号だけ。応答の message（タイトルなどを含み得る）・
# 本文・トークン・配信キーを含めない。符号の形でない reason は、unrecognized に置き換える。
module YouTubeErrors
  # 符号の形（英字で始まり、英数字・_・.・- だけ、64 文字まで）。これに合わない reason・detail は、メッセージへ出さない
  SAFE_CODE = /\A[A-Za-z][A-Za-z0-9_.-]{0,63}\z/
  # 符号の形でない reason の代わりに記録する値
  UNRECOGNIZED = "unrecognized".freeze

  # disposition を引くときの文脈。default は通常の呼び出し。prior_settlement は、先行配信の清算（10.5）
  CONTEXTS = %i[ default prior_settlement ].freeze
  # 台帳の枠（QuotaInsufficient が、どの枠が足りなかったかを持つ）
  BUCKETS = %i[ prep settle common ].freeze

  # 呼び出し側への指示（10.6 の「動作」）。
  #   connection_state   接続状態を変えるなら、その状態（live_not_enabled・revoked）。変えないなら nil。変更は YouTubeConnection のメソッドで行う
  #   end_reason         準備（10.1）でこの失敗が解消しないとき、または認可が失効したときに、配信を終了する理由。終了を求めないなら nil。
  #                      ライブ中の確認・清算では、retryable と settlement_result で動く
  #   retryable          同じ呼び出しを繰り返せば成功し得るか（要求が多すぎる・一時的な失敗・タイムアウト）。準備中は合計 1 回まで、
  #                      ライブ中の確認は次の確認まで保留、清算は 10.4 の再試行に従う
  #   settlement_result  清算の呼び出しで起きたときの結果（SettlementRules::RESULTS の失敗系）。SettlementRules.apply_result へ渡す
  Disposition = Data.define(:connection_state, :end_reason, :retryable, :settlement_result) do
    def initialize(connection_state:, end_reason:, retryable:, settlement_result:)
      unless connection_state.nil? || [ Contract::YoutubeConnectionState::LIVE_NOT_ENABLED, Contract::YoutubeConnectionState::REVOKED ].include?(connection_state)
        raise ArgumentError, "connection_state must be nil, live_not_enabled or revoked"
      end
      raise ArgumentError, "end_reason must be nil or a contract end reason" unless end_reason.nil? || Contract::EndReason.valid?(end_reason)
      raise ArgumentError, "retryable must be true or false" unless [ true, false ].include?(retryable)
      unless (SettlementRules::RESULTS - [ :success ]).include?(settlement_result)
        raise ArgumentError, "settlement_result must be a failure result of SettlementRules"
      end

      super
    end
  end

  # すべての型付きの例外の親。call_kind は窓口の呼び出しの種別（insert_broadcast など）、status は HTTP ステータス、
  # reason は符号の形の reason（YouTube の応答の符号。トークン更新の応答の error を含む）、detail は窓口が付ける符号。
  class Base < StandardError
    attr_reader :call_kind, :status, :reason, :detail

    def initialize(call_kind: nil, status: nil, reason: nil, detail: nil)
      @call_kind = YouTubeErrors.symbol_or_nil!(call_kind, "call_kind")
      @status = status.nil? ? nil : Preconditions.integer!(status, "status")
      @reason = reason.nil? ? nil : YouTubeErrors.safe_reason(reason)
      @detail = YouTubeErrors.code_or_nil!(detail, "detail")
      super(build_message)
    end

    # 呼び出し側への指示。context は nil（通常）、:default、:prior_settlement（先行配信の清算。10.5）。未知の context は ArgumentError
    def disposition(context: nil)
      resolved = context.nil? ? :default : context
      raise ArgumentError, "context must be one of #{CONTEXTS.inspect}" unless CONTEXTS.include?(resolved)

      disposition_in(resolved)
    end

    def retryable?
      disposition.retryable
    end

    private

    # 文脈ごとの指示。文脈で変わる例外だけが、上書きする
    def disposition_in(_context)
      self.class::DISPOSITION
    end

    # メッセージに載せる項目（名前, 値）。値が nil の項目は載せない
    def message_fields
      [ [ "call", call_kind ], [ "status", status ], [ "reason", reason ], [ "detail", detail ] ]
    end

    def build_message
      fields = message_fields.filter_map { |name, value| "#{name}=#{value}" unless value.nil? }
      [ "youtube_error", "class=#{self.class.name.demodulize}", *fields ].join(" ")
    end
  end

  CS = Contract::YoutubeConnectionState
  ER = Contract::EndReason
  private_constant :CS, :ER

  # ライブ配信が有効でない（liveStreamingNotEnabled）。接続状態を「ライブ未有効」とし、有効化を案内する
  class LiveNotEnabled < Base
    DISPOSITION = Disposition.new(connection_state: CS::LIVE_NOT_ENABLED, end_reason: ER::PREPARE_FAILED, retryable: false, settlement_result: :failed)
  end

  # ライブ配信が制限されている（livePermissionBlocked）。および、チャンネルの閉鎖・停止、アカウントの閉鎖・停止
  # （channelClosed・channelSuspended・authenticatedUserAccountClosed・authenticatedUserAccountSuspended。10.6 に行が無いが、
  # 利用できない状態として、「ライブ未有効・制限中」と同じ扱いにする）。制限中である旨を案内する
  class LiveStreamingRestricted < Base
    DISPOSITION = Disposition.new(connection_state: CS::LIVE_NOT_ENABLED, end_reason: ER::PREPARE_FAILED, retryable: false, settlement_result: :failed)
  end

  # 権限が不足している（insufficientLivePermissions・insufficientPermissions・forbidden）。接続状態を「認可失効」とし、再接続を案内する。
  # ただし、先行配信の清算での応答は、認可失効にしない（権限の範囲外と返ったら、清算不能のまま残す。10.5）
  class InsufficientPermissions < Base
    DISPOSITION = Disposition.new(connection_state: CS::REVOKED, end_reason: ER::AUTHORIZATION_REVOKED, retryable: false, settlement_result: :forbidden)
    PRIOR_SETTLEMENT_DISPOSITION = DISPOSITION.with(connection_state: nil, end_reason: nil)

    private

    def disposition_in(context)
      context == :prior_settlement ? PRIOR_SETTLEMENT_DISPOSITION : DISPOSITION
    end
  end

  # 更新トークンが無効（invalid_grant。トークン更新の応答）。取り消し・期限切れ。接続状態を「認可失効」とし、進行中の配信は終了する
  class TokenRevoked < Base
    DISPOSITION = Disposition.new(connection_state: CS::REVOKED, end_reason: ER::AUTHORIZATION_REVOKED, retryable: false, settlement_result: :failed)
  end

  # 配信数が上限を超えている（userBroadcastsExceedLimit。および、種別が rateLimitExceeded の concurrentBroadcastsExceedLimit・
  # sharedIngestionBroadcastsExceedLimit。再試行で解消しない上限なので、RateLimited にしない）。YouTube 側の予定配信を整理するよう案内する
  class BroadcastLimitExceeded < Base
    DISPOSITION = Disposition.new(connection_state: nil, end_reason: ER::PREPARE_FAILED, retryable: false, settlement_result: :failed)
  end

  # 割り当て超過（quotaExceeded・dailyLimitExceeded）。窓口は、台帳に超過の印を付けてから投げる。当該割り当て日の新規受付を停止する（8.4）
  class QuotaExceeded < Base
    DISPOSITION = Disposition.new(connection_state: nil, end_reason: ER::PREPARE_FAILED, retryable: false, settlement_result: :failed)
  end

  # 台帳の枠が足りない（窓口が、HTTP を呼ぶ前に断った）。準備の呼び出しは準備の失敗として扱い、確認は行わず次の機会まで見送る（8.4）。
  # YouTube は呼ばれていない。足りなかった枠（prep・settle・common）を持つ
  class QuotaInsufficient < Base
    DISPOSITION = Disposition.new(connection_state: nil, end_reason: ER::PREPARE_FAILED, retryable: false, settlement_result: :failed)

    attr_reader :bucket

    def initialize(call_kind: nil, bucket: nil)
      raise ArgumentError, "bucket must be one of #{BUCKETS.inspect} or nil" unless bucket.nil? || BUCKETS.include?(bucket)

      @bucket = bucket
      super(call_kind: call_kind)
    end

    private

    def message_fields
      [ [ "call", call_kind ], [ "bucket", bucket ] ]
    end
  end

  # 要求が多すぎる（userRequestsExceedRateLimit・rateLimitExceeded・userRateLimitExceeded・429）。再試行の対象
  class RateLimited < Base
    DISPOSITION = Disposition.new(connection_state: nil, end_reason: ER::PREPARE_FAILED, retryable: true, settlement_result: :failed)
  end

  # 一時的な失敗（5xx・接続の失敗）。再試行の対象
  class Transient < Base
    DISPOSITION = Disposition.new(connection_state: nil, end_reason: ER::PREPARE_FAILED, retryable: true, settlement_result: :failed)
  end

  # アクセストークンの更新が、一時的に失敗した（ネットワーク・5xx）。接続状態は変えない。再試行の対象（TokenVault が投げる）
  class TokenTemporarilyUnavailable < Transient
  end

  # タイムアウト。再試行の対象。要求が処理された可能性がある（配信の作成の応答の喪失は、10.1 の引き継ぎで扱う）
  class Timeout < Base
    DISPOSITION = Disposition.new(connection_state: nil, end_reason: ER::PREPARE_FAILED, retryable: true, settlement_result: :failed)
  end

  # 対象が存在しない（liveBroadcastNotFound・liveStreamNotFound・404）。清算の呼び出しでは、清算済みとして扱う（10.4・10.6）
  class NotFound < Base
    DISPOSITION = Disposition.new(connection_state: nil, end_reason: nil, retryable: false, settlement_result: :not_found)
  end

  # すでに要求の状態（redundantTransition）。清算の呼び出しでは、清算済みとして扱う（10.4・10.6）
  class AlreadyTerminal < Base
    DISPOSITION = Disposition.new(connection_state: nil, end_reason: nil, retryable: false, settlement_result: :already_terminal)
  end

  # 現在の状態から、要求の遷移・削除・紐づけができない（invalidTransition・errorStreamInactive・liveBroadcastDeletionNotAllowed・
  # liveStreamDeletionNotAllowed・liveBroadcastBindingNotAllowed）。終端ではない（AlreadyTerminal と別）。再試行しても同じなので、
  # 呼び出し側が、未清算のまま 10.4 の再試行へ、または準備の失敗へ回す
  class NotAllowed < Base
    DISPOSITION = Disposition.new(connection_state: nil, end_reason: ER::PREPARE_FAILED, retryable: false, settlement_result: :not_transitionable)
  end

  # チャンネルが無い（channelNotFound・youtubeSignupRequired）。接続時の確認（7.2。#11）で使う
  class NoChannel < Base
    DISPOSITION = Disposition.new(connection_state: nil, end_reason: nil, retryable: false, settlement_result: :failed)
  end

  # 表に無い reason・形の違う応答（黙って成功にしない。特定の失敗にもしない）。detail に、窓口が付けた符号（missing_id など）を持つ
  class UnexpectedResponse < Base
    DISPOSITION = Disposition.new(connection_state: nil, end_reason: ER::PREPARE_FAILED, retryable: false, settlement_result: :failed)
  end

  # error.errors[].reason（トークンエンドポイントの error）→ 例外クラス。issue #10 の分類の表（スペックで固定する）
  REASON_CLASSES = {
    "liveStreamingNotEnabled" => LiveNotEnabled,
    "livePermissionBlocked" => LiveStreamingRestricted,
    "channelClosed" => LiveStreamingRestricted,
    "channelSuspended" => LiveStreamingRestricted,
    "authenticatedUserAccountClosed" => LiveStreamingRestricted,
    "authenticatedUserAccountSuspended" => LiveStreamingRestricted,
    "insufficientLivePermissions" => InsufficientPermissions,
    "insufficientPermissions" => InsufficientPermissions,
    "forbidden" => InsufficientPermissions,
    "invalid_grant" => TokenRevoked,
    "userBroadcastsExceedLimit" => BroadcastLimitExceeded,
    "concurrentBroadcastsExceedLimit" => BroadcastLimitExceeded,
    "sharedIngestionBroadcastsExceedLimit" => BroadcastLimitExceeded,
    "quotaExceeded" => QuotaExceeded,
    "dailyLimitExceeded" => QuotaExceeded,
    "userRequestsExceedRateLimit" => RateLimited,
    "rateLimitExceeded" => RateLimited,
    "userRateLimitExceeded" => RateLimited,
    "liveBroadcastNotFound" => NotFound,
    "liveStreamNotFound" => NotFound,
    "redundantTransition" => AlreadyTerminal,
    "invalidTransition" => NotAllowed,
    "errorStreamInactive" => NotAllowed,
    "liveBroadcastDeletionNotAllowed" => NotAllowed,
    "liveStreamDeletionNotAllowed" => NotAllowed,
    "liveBroadcastBindingNotAllowed" => NotAllowed,
    "channelNotFound" => NoChannel,
    "youtubeSignupRequired" => NoChannel
  }.freeze

  TOO_MANY_REQUESTS = 429
  NOT_FOUND_STATUS = 404
  SERVER_ERROR_STATUSES = (500..599)
  private_constant :TOO_MANY_REQUESTS, :NOT_FOUND_STATUS, :SERVER_ERROR_STATUSES

  class << self
    # 応答を、型付きの例外へ分類する（投げずに返す）。status は HTTP ステータス（整数）、payload は応答の JSON（解釈できなければ nil。
    # 形が違っても、例外にしない）、call_kind は窓口の呼び出しの種別（シンボルまたは nil）。
    #   1. reason の表（REASON_CLASSES）。errors に複数あれば、表にある最初のもの
    #   2. 表に無ければ、ステータスの規則: 404 は NotFound、429 は RateLimited、5xx は Transient
    #   3. どちらにも当たらなければ UnexpectedResponse（reason は記録する）
    def classify(status:, payload:, call_kind: nil)
      Preconditions.integer!(status, "status")
      symbol_or_nil!(call_kind, "call_kind")

      reasons = reasons_from(payload)
      known = reasons.find { |reason| REASON_CLASSES.key?(reason) }
      return REASON_CLASSES.fetch(known).new(call_kind: call_kind, status: status, reason: known) if known

      by_status(status).new(call_kind: call_kind, status: status, reason: reasons.first)
    end

    # 符号の形の reason はそのまま、それ以外は unrecognized
    def safe_reason(reason)
      reason.is_a?(String) && SAFE_CODE.match?(reason) ? reason : UNRECOGNIZED
    end

    def symbol_or_nil!(value, name)
      return value if value.nil? || value.is_a?(Symbol)

      raise ArgumentError, "#{name} must be a Symbol or nil, got #{value.class}"
    end

    # nil、または符号（シンボル、または符号の形の文字列）。自由な文章は、メッセージに載せない
    def code_or_nil!(value, name)
      return nil if value.nil?
      return value if value.is_a?(Symbol) || (value.is_a?(String) && SAFE_CODE.match?(value))

      raise ArgumentError, "#{name} must be a code (a Symbol, or a String of letters, digits, underscores, dots and hyphens) or nil"
    end

    private

    # 応答の JSON から、reason の列を取り出す。YouTube の形（error.errors[].reason）と、OAuth の形（error が文字列）。
    # 取り出せなければ空。文字列でない reason は、unrecognized として数える（先頭の符号を失わないため）
    def reasons_from(payload)
      return [] unless payload.is_a?(Hash)

      error = payload["error"]
      case error
      when String then [ error ]
      when Hash then error_entries(error["errors"])
      else []
      end
    end

    def error_entries(entries)
      return [] unless entries.is_a?(Array)

      entries.filter_map do |entry|
        next unless entry.is_a?(Hash) && entry.key?("reason")

        entry["reason"]
      end
    end

    def by_status(status)
      return NotFound if status == NOT_FOUND_STATUS
      return RateLimited if status == TOO_MANY_REQUESTS
      return Transient if SERVER_ERROR_STATUSES.cover?(status)

      UnexpectedResponse
    end
  end
end
