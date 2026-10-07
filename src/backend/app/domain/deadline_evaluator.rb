# frozen_string_literal: true

# 期限の評価（requirements.md 15 章「期限の評価」・13.2・10.2・10.3・10.4）。
#
#   DeadlineEvaluator.evaluate(broadcast: snapshot, now: Time, settings: settings)   # => [Directive, ...]
#
# 配信レコードの終了以外のすべての状態は期限を持つ。期限監視（5 秒以内の間隔。当該配信に関する要求の受理時にも）が、
# 全件をこの規則で評価し、中継・ブラウザからの通知が無くても、終端へ進める（27 章の終端性）。
# 通知（事象）の処理は、BroadcastStateMachine。この規則は、時刻だけから、指示を返す。副作用は実行しない。
#
# 期限ちょうどの時刻は、期限切れとして扱う（now >= 期限。「期限に達した」）。
#
# 状態ごとの評価（13.2 の表。数値は契約の limits.json の deadlines）
#   受理済み   受理から 90 秒以内に送出待ちへ進まない        → end（start_timeout）
#   送出待ち   準備の完了から 30 秒以内に送出開始が無い      → end（start_timeout）
#   確定待ち   送出開始から 120 秒以内にライブにならない      → end（confirm_timeout）。期限の前は、5 秒間隔の確認 poll_live_confirmation
#   ライブ     ライブ確定から 60 分（設定 time_limit_minutes）  → end（time_limit）。進行中の配信にも、評価の時点の設定を適用する
#              心拍が 10 秒途絶                                → interrupt（原因 heartbeat_lost・期限 75 秒）。終了を、中断より優先する
#              期限の前は、時間上限の 5 分前の予告 time_limit_notice（1 回）と、5 分間隔の確認 poll_live_health
#   中断       復帰が 10 回を超える中断は、復帰を待たずに      → end（connection_lost）
#              期限内（中継の通知から 30 秒。心拍の途絶から 75 秒）に復帰が無い → end（connection_lost）
#              ライブ確定から 60 分                              → end（time_limit）
#              複数の期限が過ぎているときは、期限の早い理由 1 つで終了する（同時刻は、この表の順）
#   終了       清算が未了（未清算）なら、1・2・4 分の間隔で最大 3 回の再試行 retry_settlement。ほかの指示は返さない
#              終端（不要・清算済み・清算不能）は、指示なし
#
# 中断の期限（interruption_deadline）: min(中断の時刻 + 75 秒, 中継の通知の時刻 + 30 秒)
#   通知による中断（通知の時刻 = 中断の時刻）: 30 秒。そのあとに心拍も途絶しても、30 秒のまま（期限は動かさない）
#   心拍の途絶による中断（通知なし）: 75 秒。通知が後から届いた場合は、先の期限と新しい期限の早い方
#
# 指示（Directive）
#   end                    reason: 終了理由（Contract::EndReason）
#   interrupt              cause: :heartbeat_lost・deadline_at: 中断の期限（評価の時刻から 75 秒）
#   time_limit_notice      notice_seconds: 時間上限までの残りの秒数（5 分。上限が 5 分以下ならその秒数）
#   poll_live_confirmation 確定待ちの、YouTube の配信状態の確認（5 秒間隔）
#   poll_live_health       ライブ中の、配信状態とストリームの健全性の確認（5 分間隔）
#   retry_settlement       attempts_made: 行った清算の試行の回数（最初の試行を含む）
#
# 心拍は、今回の心拍を反映した last_heartbeat_at で評価する（心拍の受理では、更新してから評価する）。
class DeadlineEvaluator
  S = Contract::BroadcastState
  R = Contract::EndReason
  SS = Contract::SettlementState
  private_constant :S, :R, :SS

  DEADLINES = Contract::Limits::DEADLINES
  RESERVED_SECONDS = DEADLINES.fetch("reserved_seconds")
  AWAITING_MEDIA_SECONDS = DEADLINES.fetch("awaiting_media_seconds")
  CONFIRMING_SECONDS = DEADLINES.fetch("confirming_seconds")
  RELAY_NOTIFIED_SECONDS = DEADLINES.fetch("interrupted_relay_notified_seconds")
  HEARTBEAT_LOST_INTERRUPT_SECONDS = DEADLINES.fetch("interrupted_heartbeat_lost_seconds")
  HEARTBEAT_LOST_DETECT_SECONDS = DEADLINES.fetch("heartbeat_lost_detect_seconds")
  MAX_RESUMES = DEADLINES.fetch("max_resumes")
  LIVE_CONFIRM_POLL_SECONDS = DEADLINES.fetch("live_confirm_poll_interval_seconds")
  LIVE_CHECK_INTERVAL_SECONDS = DEADLINES.fetch("live_check_interval_seconds")
  TIME_LIMIT_NOTICE_BEFORE_SECONDS = DEADLINES.fetch("time_limit_notice_before_seconds")

  NO_DIRECTIVES = [].freeze
  private_constant :NO_DIRECTIVES

  private_class_method :new

  class << self
    # 配信（スナップショット）を now で評価し、遷移の指示を返す。settings は、time_limit_minutes（整数、分）に応答するもの。
    def evaluate(broadcast:, now:, settings:)
      LifecycleChecks.kind!(broadcast, BroadcastSnapshot, "broadcast")
      LifecycleChecks.time!(now, "now")
      limit_seconds = time_limit_seconds(settings)

      with_broadcast_id(broadcast) { directives_for(broadcast, now, limit_seconds) }.freeze
    end

    # 中断の期限。interrupted_at は中断に入った時刻、relay_notified_at は中継が中断を通知した時刻（無ければ nil）。
    # 通知があれば、通知から 30 秒の期限と、中断の時刻から 75 秒の期限の、早い方。
    def interruption_deadline(interrupted_at:, relay_notified_at:)
      LifecycleChecks.time!(interrupted_at, "interrupted_at")
      LifecycleChecks.time_or_nil!(relay_notified_at, "relay_notified_at")

      deadlines = [ interrupted_at + HEARTBEAT_LOST_INTERRUPT_SECONDS ]
      deadlines << relay_notified_at + RELAY_NOTIFIED_SECONDS unless relay_notified_at.nil?
      deadlines.min
    end

    private

    # 評価の失敗（あり得ない状態の配信）に、配信の識別子を添えて、期限監視のログで、どの配信かをたどれるようにする。
    def with_broadcast_id(broadcast)
      yield
    rescue ArgumentError => error
      raise ArgumentError, "#{error.message} (broadcast_id=#{broadcast.id})"
    end

    def directives_for(broadcast, now, limit_seconds)
      case broadcast.state
      when S::RESERVED then expire_at(broadcast.accepted_at + RESERVED_SECONDS, R::START_TIMEOUT, now)
      when S::AWAITING_MEDIA then expire_at(broadcast.provisioned_at + AWAITING_MEDIA_SECONDS, R::START_TIMEOUT, now)
      when S::CONFIRMING then evaluate_confirming(broadcast, now)
      when S::LIVE then evaluate_live(broadcast, now, limit_seconds)
      when S::INTERRUPTED then evaluate_interrupted(broadcast, now, limit_seconds)
      when S::ENDED then evaluate_ended(broadcast, now)
      end
    end

    def evaluate_confirming(broadcast, now)
      expired = expire_at(broadcast.publish_started_at + CONFIRMING_SECONDS, R::CONFIRM_TIMEOUT, now)
      return expired unless expired.empty?
      return NO_DIRECTIVES unless poll_due?(broadcast.last_checked_at, LIVE_CONFIRM_POLL_SECONDS, now)

      [ Directive.of(:poll_live_confirmation) ]
    end

    # 終了（時間上限）を、中断より優先する。中断の指示のときは、ほかの指示（予告・確認）を返さない。
    def evaluate_live(broadcast, now, limit_seconds)
      limit_at = broadcast.live_at + limit_seconds
      return [ Directive.of(:end, reason: R::TIME_LIMIT) ] if now >= limit_at
      return [ interrupt_directive(now) ] if heartbeat_lost?(broadcast, now)

      directives = []
      directives << notice_directive(limit_seconds) if notice_due?(broadcast, limit_at, now)
      directives << Directive.of(:poll_live_health) if poll_due?(last_check_of(broadcast), LIVE_CHECK_INTERVAL_SECONDS, now)
      directives
    end

    # 期限を過ぎたものの中で、期限の早いもの 1 つの理由で終了する。同じ時刻なら、候補の並びの順（表の順）。
    def evaluate_interrupted(broadcast, now, limit_seconds)
      expired = interrupted_candidates(broadcast, limit_seconds).each_with_index.select { |(due_at, _reason), _index| now >= due_at }
      return NO_DIRECTIVES if expired.empty?

      (_due_at, reason), _index = expired.min_by { |(due_at, _reason), index| [ due_at, index ] }
      [ Directive.of(:end, reason: reason) ]
    end

    # 中断の、終了の候補（期限, 理由）。表の順: 復帰の回数の超過・中断の期限・時間上限
    def interrupted_candidates(broadcast, limit_seconds)
      candidates = []
      candidates << [ broadcast.interrupted_at, R::CONNECTION_LOST ] if broadcast.resume_count >= MAX_RESUMES
      candidates << [ interruption_deadline(interrupted_at: broadcast.interrupted_at, relay_notified_at: broadcast.relay_notified_at), R::CONNECTION_LOST ]
      candidates << [ broadcast.live_at + limit_seconds, R::TIME_LIMIT ]
      candidates
    end

    # 終了済みは、清算の再試行だけ。清算の対象（YouTube の配信の識別子）が無ければ、指示なし。
    def evaluate_ended(broadcast, now)
      return NO_DIRECTIVES unless broadcast.settlement_state == SS::PENDING && broadcast.youtube_resource?
      return NO_DIRECTIVES if now < settlement_retry_due_at(broadcast)

      [ Directive.of(:retry_settlement, attempts_made: broadcast.settlement_attempts) ]
    end

    # 次の試行の時刻。最後の試行（無ければ終了）の時刻から、試行の回数に応じた間隔（1・2・4 分）。
    def settlement_retry_due_at(broadcast)
      base = [ broadcast.settlement_attempted_at, broadcast.ended_at ].compact.max
      base + SettlementRules.retry_delay_seconds(attempts_made: broadcast.settlement_attempts)
    end

    def expire_at(due_at, reason, now)
      return NO_DIRECTIVES if now < due_at

      [ Directive.of(:end, reason: reason) ]
    end

    # 確認は、まだ確認していなければ（nil）直ちに。確認していれば、間隔が過ぎたとき。
    def poll_due?(last_checked_at, interval_seconds, now)
      last_checked_at.nil? || now >= last_checked_at + interval_seconds
    end

    # ライブ中の確認の起点。最後の確認か、ライブ確定（確認の 1 回）の、遅い方。
    def last_check_of(broadcast)
      [ broadcast.last_checked_at, broadcast.live_at ].compact.max
    end

    # 心拍の途絶。最後の心拍か、ライブ確定の、遅い方（心拍が一度も届いていなくても、有限時間で中断する）から、10 秒。
    def heartbeat_lost?(broadcast, now)
      last_alive = [ broadcast.last_heartbeat_at, broadcast.live_at ].compact.max
      now >= last_alive + HEARTBEAT_LOST_DETECT_SECONDS
    end

    def notice_due?(broadcast, limit_at, now)
      !broadcast.time_limit_notice_sent && now >= limit_at - TIME_LIMIT_NOTICE_BEFORE_SECONDS
    end

    def notice_directive(limit_seconds)
      Directive.of(:time_limit_notice, notice_seconds: [ limit_seconds, TIME_LIMIT_NOTICE_BEFORE_SECONDS ].min)
    end

    def interrupt_directive(now)
      Directive.of(
        :interrupt,
        cause: :heartbeat_lost,
        deadline_at: interruption_deadline(interrupted_at: now, relay_notified_at: nil)
      )
    end

    def time_limit_seconds(settings)
      raise ArgumentError, "settings must respond to time_limit_minutes" unless settings.respond_to?(:time_limit_minutes)

      LifecycleChecks.integer!(settings.time_limit_minutes, "time_limit_minutes", min: 1) * LifecycleTimeUnits::SECONDS_PER_MINUTE
    end
  end
end
