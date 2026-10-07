# frozen_string_literal: true

# 配信レコード（broadcasts）のスナップショット。AR モデルを渡さず、規則が必要とする値だけを持つ不変の値オブジェクト。
#
# 期限の評価（DeadlineEvaluator）・終了処理（TerminationPlanner）・先行配信の清算確認（PriorSettlementCheck）が、
# 評価の対象として受け取る。アプリケーション層のアダプタが、配信レコードから作る（時刻は、Time。
# DB の値と、評価の時刻 now は、同じ時計の値であること）。#5 の AccountSnapshot とは独立した名前で、#5 に依存しない。
#
# 項目（requirements.md 21 章の broadcasts の列に対応。※は列に無く、アダプタが用意する項目）
#   id                          配信レコードの識別子。例外のメッセージ・ログで配信をたどるために持つ
#   user_id                     アカウント識別子（users.id）。他のアカウントの配信を混ぜないために持つ
#   state                       状態（Contract::BroadcastState）
#   end_reason                  終了理由（Contract::EndReason）。終了のときだけ必須
#   settlement_state            清算状態（Contract::SettlementState）。終了していなければ none
#   settlement_attempts         行った清算の試行の回数（終了処理に続く最初の試行を含む。0 は、まだ試行が記録されていない）。
#                               結果の反映後に、SettlementRules.apply_result が返す値（反映前の回数 + 1）へ更新する
#   settlement_attempted_at ※   最後の清算の試行を始めた時刻。試行が無ければ nil（再試行の間隔は、終了の時刻から数える）
#   accepted_at                 受理の時刻（必須）
#   provisioned_at              準備の完了の時刻。送出待ちから必須
#   publish_started_at          送出開始の時刻。確定待ちから必須
#   live_at                     ライブ確定の時刻。ライブ・中断で必須
#   interrupted_at              中断の時刻（中断に入ったとき、アプリケーションが記録した時刻）。中断で必須
#   relay_notified_at ※         中継が中断を通知した時刻（アプリケーションが受けた時刻）。通知が無ければ nil。
#                               心拍の途絶による中断のあとに通知が届いたときも記録する（13.2）。
#                               中断のたびに、アダプタが更新・消去する（前の中断の値を残さない。残ると作成が失敗する）
#   last_heartbeat_at           最後に心拍を受けた時刻。今回の心拍を反映してから評価する（評価の前に更新する）
#   last_checked_at             YouTube 側の状態の最終確認の時刻。確認を始めた時刻（評価の now）を記録する。
#                               応答を得た時刻を記録すると、5 秒間隔の確認が、期限監視の間隔とずれて、10 秒間隔になる。
#                               終了後は、清算の状態確認の時刻としては使わない（settlement_attempted_at を使う）
#   ended_at                    終了の時刻。終了のとき必須
#   resume_count                復帰の回数（中断からライブへ戻った回数）
#   time_limit_notice_sent ※    時間上限の予告を送出済みか
#   youtube_broadcast_id        YouTube の配信の識別子。無ければ、YouTube 資源を持たない（終了から 30 日で消去される）
#   youtube_stream_id           配信に紐づけたストリームの識別子
#
# 作成時に、型・契約の値・状態ごとの必須の時刻・状態どうしの整合を検査する。不整合は ArgumentError
# （メッセージに配信の識別子を載せる）。with は、複製を作るときも検査する。
class BroadcastSnapshot < Data.define(
  :id,
  :user_id,
  :state,
  :end_reason,
  :settlement_state,
  :settlement_attempts,
  :settlement_attempted_at,
  :accepted_at,
  :provisioned_at,
  :publish_started_at,
  :live_at,
  :interrupted_at,
  :relay_notified_at,
  :last_heartbeat_at,
  :last_checked_at,
  :ended_at,
  :resume_count,
  :time_limit_notice_sent,
  :youtube_broadcast_id,
  :youtube_stream_id
)
  # 任意の時刻の項目（nil、または Time）
  OPTIONAL_TIME_FIELDS = %i[
    settlement_attempted_at provisioned_at publish_started_at live_at interrupted_at relay_notified_at
    last_heartbeat_at last_checked_at ended_at
  ].freeze

  # 状態ごとに、必須の項目（期限の評価・終了処理が、その状態で起点にする時刻）
  REQUIRED_BY_STATE = {
    Contract::BroadcastState::RESERVED => [].freeze,
    Contract::BroadcastState::AWAITING_MEDIA => [ :provisioned_at ].freeze,
    Contract::BroadcastState::CONFIRMING => [ :publish_started_at ].freeze,
    Contract::BroadcastState::LIVE => [ :live_at ].freeze,
    Contract::BroadcastState::INTERRUPTED => [ :live_at, :interrupted_at ].freeze,
    Contract::BroadcastState::ENDED => [ :ended_at, :end_reason ].freeze
  }.freeze

  def initialize(
    id:,
    user_id:,
    state:,
    accepted_at:,
    end_reason: nil,
    settlement_state: Contract::SettlementState::NONE,
    settlement_attempts: 0,
    settlement_attempted_at: nil,
    provisioned_at: nil,
    publish_started_at: nil,
    live_at: nil,
    interrupted_at: nil,
    relay_notified_at: nil,
    last_heartbeat_at: nil,
    last_checked_at: nil,
    ended_at: nil,
    resume_count: 0,
    time_limit_notice_sent: false,
    youtube_broadcast_id: nil,
    youtube_stream_id: nil
  )
    super
    validate!
  end

  # 終了しているか。
  def ended?
    state == Contract::BroadcastState::ENDED
  end

  # YouTube 資源（配信）を持つか。配信の識別子があるとき。ストリームの識別子だけでは、持たない（ストリームは再利用する）。
  def youtube_resource?
    !youtube_broadcast_id.nil?
  end

  private

  # 検査の違反に、配信の識別子を添えて、ArgumentError にする。
  def validate!
    check_identifiers!
    check_codes!
    check_counts_and_flags!
    check_times!
    check_state_requirements!
    check_settlement_consistency!
    check_interruption_order!
  rescue ArgumentError => error
    raise ArgumentError, "#{error.message} (broadcast_id=#{id})"
  end

  def check_identifiers!
    LifecycleChecks.text!(id, "id")
    LifecycleChecks.text!(user_id, "user_id")
    LifecycleChecks.text_or_nil!(youtube_broadcast_id, "youtube_broadcast_id")
    LifecycleChecks.text_or_nil!(youtube_stream_id, "youtube_stream_id")
  end

  def check_codes!
    LifecycleChecks.contract_value!(Contract::BroadcastState, state, "state")
    LifecycleChecks.contract_value!(Contract::SettlementState, settlement_state, "settlement_state")
    LifecycleChecks.contract_value!(Contract::EndReason, end_reason, "end_reason") unless end_reason.nil?
  end

  def check_counts_and_flags!
    LifecycleChecks.integer!(settlement_attempts, "settlement_attempts", min: 0)
    LifecycleChecks.integer!(resume_count, "resume_count", min: 0)
    LifecycleChecks.boolean!(time_limit_notice_sent, "time_limit_notice_sent")
  end

  def check_times!
    LifecycleChecks.time!(accepted_at, "accepted_at")
    OPTIONAL_TIME_FIELDS.each { |field| LifecycleChecks.time_or_nil!(public_send(field), field) }
  end

  def check_state_requirements!
    REQUIRED_BY_STATE.fetch(state).each do |field|
      raise ArgumentError, "#{field} is required in state #{state}" if public_send(field).nil?
    end
    raise ArgumentError, "end_reason must be nil unless the state is ended" if !ended? && !end_reason.nil?
  end

  # 清算状態は、終了と同時に定まる（25.2）。終了していない配信は none（まだ定まっていない）。
  def check_settlement_consistency!
    return if ended? || settlement_state == Contract::SettlementState::NONE

    raise ArgumentError, "settlement_state must be none unless the state is ended"
  end

  # 中継の通知は、中断に入った時刻以降。前の中断の値が残っている（更新し忘れ）と、期限を誤るので、作成の時点で止める。
  def check_interruption_order!
    return if interrupted_at.nil? || relay_notified_at.nil? || relay_notified_at >= interrupted_at

    raise ArgumentError, "relay_notified_at must not be earlier than interrupted_at"
  end
end
