# frozen_string_literal: true

# 清算（requirements.md 15 章「清算」・10.4・10.5・25.2・8.4）。終了した配信の YouTube 資源を、終端（完了または削除）へ導く規則。
#
#   SettlementRules.plan(youtube_status: "live")
#   # => Directive.of(:transition_to_complete)
#   SettlementRules.apply_result(settlement_state: "pending", attempts: 0, result: :failed)
#   # => Outcome(settlement_state: "pending", attempts: 1, retry_delay_seconds: 60, directives: [])
#
# 清算の試行
#   終了処理に続く最初の試行（再試行ではない）と、期限監視による最大 3 回の再試行（1・2・4 分の間隔）。
#   attempts は、「その試行の前に行った清算の試行の回数」。最初の試行は 0、k 回目の再試行は k（＝その試行が何回目の再試行か）。
#   結果の反映後の回数は attempts + 1（BroadcastSnapshot#settlement_attempts に保存する）。
#   4 回目の試行（3 回目の再試行）の失敗で、清算不能（25.2「再試行が 3 回に到達」）。1・2・4 分は、失敗した試行のあとの待ち時間。
#   接続の解除・アカウント削除の時点で行う清算の試行も、再試行の 1 回として数える（7.4）。
#
# 清算の支出（8.4）
#   終了・清算枠（BUCKET）だけ。1 回の試行は 51 ユニット（状態確認 1 + 完了への遷移または削除 50。ATTEMPT_COST_UNITS）。
#   最初の試行 1 回 + 再試行 3 回で 204 ユニットで、終了・清算枠（210）に収まる。他の用途で取り崩さない（#5 の QuotaPolicy）。
#   先行配信の清算（10.5）は、新しい配信の準備・確認枠から支出する（PriorSettlementCheck）。
#
# 15 章の関数との対応: 清算 = plan（YouTube 側の状態 → 指示）と apply_result（結果 → 清算状態・予約の解放）。
# 副作用は実行しない。指示は Directive の値で返す。
class SettlementRules
  # YouTube の lifeCycleStatus（liveBroadcasts の status.lifeCycleStatus。API の綴り）。公式の 8 値。
  module LifeCycleStatus
    COMPLETE = "complete"
    CREATED = "created"
    LIVE = "live"
    LIVE_STARTING = "liveStarting"
    READY = "ready"
    REVOKED = "revoked"
    TEST_STARTING = "testStarting"
    TESTING = "testing"

    ALL = [ COMPLETE, CREATED, LIVE, LIVE_STARTING, READY, REVOKED, TEST_STARTING, TESTING ].freeze
  end

  # 配信が YouTube に存在しない（状態が得られなかった nil とは区別する）。plan の youtube_status に渡す。
  NOT_FOUND = :not_found

  # lifeCycleStatus が、公式の 8 値でも NOT_FOUND でもない。黙って清算済みにしない。
  class UnknownLifeCycleStatus < ArgumentError; end

  # 清算の呼び出しの結果（apply_result の result）。YouTube のエラーの reason からは、result_for_error で得る。
  #   success             完了への遷移・削除に成功した（または、状態の確認で終端だった）
  #   not_found           存在しない（清算済みとして扱う。10.4・10.6）
  #   already_terminal    すでに終端（redundantTransition ＝ すでに要求の状態。清算済みとして扱う）
  #   not_transitionable  現在の状態から要求の状態へ遷移・削除できない（invalidTransition・liveBroadcastDeletionNotAllowed・
  #                       errorStreamInactive）。終端ではない。未清算のまま再試行する
  #   forbidden           権限の範囲外。清算不能からの再清算では、清算不能のまま残す（認可失効として扱わない。10.5）
  #   failed              一時的な失敗・タイムアウト・割り当て超過・未知のエラー。未清算のまま再試行する
  RESULTS = %i[success not_found already_terminal not_transitionable forbidden failed].freeze

  # 清算済みとして扱う結果
  SETTLED_RESULTS = %i[success not_found already_terminal].freeze

  # YouTube のエラーの reason（error.errors[].reason）→ 結果。表に無い reason は failed（未清算のまま再試行。清算済みにしない）。
  # 分類は reason の表引きで行い、HTTP ステータスでは決めない（403 が、権限・割り当て・遷移不可を兼ねるため）。
  ERROR_REASON_RESULTS = {
    "redundantTransition" => :already_terminal,
    "invalidTransition" => :not_transitionable,
    "liveBroadcastDeletionNotAllowed" => :not_transitionable,
    "errorStreamInactive" => :not_transitionable,
    "liveBroadcastNotFound" => :not_found,
    "liveStreamNotFound" => :not_found,
    "insufficientPermissions" => :forbidden,
    "insufficientLivePermissions" => :forbidden,
    "forbidden" => :forbidden
  }.freeze

  # YouTube 側の状態 → 清算の指示の種別。
  #   transition_to_complete  完了へ遷移させる（ライブ。テスト中は、モニターストリームを無効にしているので通常は存在しない）
  #   delete_broadcast        配信を削除する（未開始。遷移中で止まった配信も、YouTube の公式の案内が「削除して作り直す」。
  #                           liveStarting・testStarting は、10.4 の表に行が無い。要件への追記を、本人へ提案する）
  #   mark_settled            何もしない（清算済み）。終端（完了・取り消し）・存在しない
  ACTIONS = {
    LifeCycleStatus::LIVE => :transition_to_complete,
    LifeCycleStatus::TESTING => :transition_to_complete,
    LifeCycleStatus::CREATED => :delete_broadcast,
    LifeCycleStatus::READY => :delete_broadcast,
    LifeCycleStatus::LIVE_STARTING => :delete_broadcast,
    LifeCycleStatus::TEST_STARTING => :delete_broadcast,
    LifeCycleStatus::COMPLETE => :mark_settled,
    LifeCycleStatus::REVOKED => :mark_settled,
    NOT_FOUND => :mark_settled
  }.freeze

  # 結果の反映。settlement_state は次の清算状態、attempts は反映後の試行回数、retry_delay_seconds は未清算のままのとき、
  # 次の試行までの秒数（それ以外は nil）、directives は Directive の配列（release_reservation・discard_stream_id）。
  Outcome = Data.define(:settlement_state, :attempts, :retry_delay_seconds, :directives)

  SS = Contract::SettlementState
  private_constant :SS

  # 清算の支出（8.4）。枠は、#5 の QuotaPolicy の予約の枠（BUCKETS）と同じ符号（:settle）。単価は契約（limits.json の quota.unit_costs）から取る
  BUCKET = :settle
  STATUS_CHECK_UNITS = Contract::Limits::QUOTA.fetch("unit_costs").fetch("list")
  SETTLE_CALL_UNITS = Contract::Limits::QUOTA.fetch("unit_costs").values_at("transition", "delete").max
  ATTEMPT_COST_UNITS = STATUS_CHECK_UNITS + SETTLE_CALL_UNITS

  # 再試行の間隔（秒。1・2・4 分）と、上限の回数（3 回）。契約（limits.json の deadlines）から取る
  RETRY_DELAYS = Contract::Limits::DEADLINES.fetch("settlement_retry_delays_seconds")
  MAX_RETRIES = RETRY_DELAYS.size

  NO_DIRECTIVES = [].freeze
  private_constant :NO_DIRECTIVES

  private_class_method :new

  class << self
    # YouTube 側の状態から、清算の指示を決める。youtube_status は、lifeCycleStatus の 8 値（LifeCycleStatus）か NOT_FOUND。
    # 未知の値は UnknownLifeCycleStatus（黙って清算済みにしない）。
    def plan(youtube_status:)
      kind = ACTIONS.fetch(youtube_status) do
        raise UnknownLifeCycleStatus, "unknown YouTube lifeCycleStatus: #{youtube_status.inspect}"
      end

      Directive.of(kind)
    end

    # 清算の呼び出しの結果を、清算状態へ反映する。attempts は、この試行の前の試行の回数（最初の試行は 0）。
    def apply_result(settlement_state:, attempts:, result:)
      check_apply_inputs!(settlement_state, attempts, result)

      case settlement_state
      when SS::PENDING then apply_to_pending(attempts, result)
      when SS::ABANDONED then apply_to_abandoned(attempts, result)
      else unchanged(settlement_state, attempts)
      end
    end

    # YouTube のエラーの reason を、結果（RESULTS）へ分類する。表に無い reason は、failed。
    def result_for_error(reason:)
      LifecycleChecks.kind!(reason, String, "reason")

      ERROR_REASON_RESULTS.fetch(reason, :failed)
    end

    # 次の試行までの秒数。attempts_made は、行った試行の回数（最初の試行を含む。0 は、最初の試行がまだ記録されていない）。
    # 1 回目の再試行は、最初の試行の 1 分後（0 回でも同じ）、2 回目は 2 分後、3 回目は 4 分後。
    def retry_delay_seconds(attempts_made:)
      LifecycleChecks.integer!(attempts_made, "attempts_made", min: 0, max: MAX_RETRIES)

      RETRY_DELAYS.fetch([ attempts_made - 1, 0 ].max)
    end

    # 清算状態が終端（不要・清算済み・清算不能）か。終端に達した時点で、予約の残額を解放する（8.4）。
    def terminal?(settlement_state)
      LifecycleChecks.contract_value!(SS, settlement_state, "settlement_state")

      settlement_state != SS::PENDING
    end

    private

    def check_apply_inputs!(settlement_state, attempts, result)
      LifecycleChecks.contract_value!(SS, settlement_state, "settlement_state")
      LifecycleChecks.integer!(attempts, "attempts", min: 0)
      raise ArgumentError, "result must be one of #{RESULTS.inspect}, got #{result.inspect}" unless RESULTS.include?(result)
      return unless settlement_state == SS::PENDING && attempts > MAX_RETRIES

      raise ArgumentError, "attempts must be <= #{MAX_RETRIES} in state pending, got #{attempts}"
    end

    # 未清算: 成功・存在しない・すでに終端 → 清算済み（予約を解放）。失敗 → 未清算のまま再試行。再試行が尽きたら清算不能。
    def apply_to_pending(attempts, result)
      attempts_made = attempts + 1
      return settled(attempts_made, [ Directive.of(:release_reservation) ]) if SETTLED_RESULTS.include?(result)
      return pending(attempts_made) if attempts < MAX_RETRIES

      abandoned(attempts_made)
    end

    # 清算不能: 次回の準備時の再清算。成功・存在しない・すでに終端 → 清算済み。失敗（権限の範囲外を含む）→ 清算不能のまま。
    # 予約の解放・ストリームの識別子の破棄は、清算不能になった時点で済んでいる。
    def apply_to_abandoned(attempts, result)
      return settled(attempts + 1, NO_DIRECTIVES) if SETTLED_RESULTS.include?(result)

      Outcome.new(settlement_state: SS::ABANDONED, attempts: attempts + 1, retry_delay_seconds: nil, directives: NO_DIRECTIVES)
    end

    # 不要・清算済み: 終端。どの結果でも変えない（冪等）。
    def unchanged(settlement_state, attempts)
      Outcome.new(settlement_state: -settlement_state, attempts: attempts, retry_delay_seconds: nil, directives: NO_DIRECTIVES)
    end

    def settled(attempts_made, directives)
      Outcome.new(settlement_state: SS::SETTLED, attempts: attempts_made, retry_delay_seconds: nil, directives: directives.freeze)
    end

    def pending(attempts_made)
      Outcome.new(
        settlement_state: SS::PENDING,
        attempts: attempts_made,
        retry_delay_seconds: retry_delay_seconds(attempts_made: attempts_made),
        directives: NO_DIRECTIVES
      )
    end

    # 再試行が尽きた: 清算不能。予約の残額を解放し、ストリームの識別子の破棄は、取り替えの規則（StreamReplacementPolicy）に従う。
    def abandoned(attempts_made)
      directives = [ Directive.of(:release_reservation) ]
      directives << Directive.of(:discard_stream_id) if StreamReplacementPolicy.discard?(trigger: StreamReplacementPolicy::SETTLEMENT_ABANDONED)

      Outcome.new(settlement_state: SS::ABANDONED, attempts: attempts_made, retry_delay_seconds: nil, directives: directives.freeze)
    end
  end
end
