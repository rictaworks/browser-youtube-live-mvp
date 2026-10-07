# frozen_string_literal: true

# 配信レコードの状態遷移（requirements.md 15 章「配信の状態遷移」・25.1）。
#
#   BroadcastStateMachine.transition(state: "live", event: "user_stop")
#   # => #<data BroadcastStateMachine::Transition next_state="ended", effects=[#<data Directive kind=:terminate, args={reason: "user_stop"}>]>
#
# 状態（state）は契約の Contract::BroadcastState、事象（event）は契約の符号（文字列）。事象は 2 つの区分から成る。
#   進行の事象   準備の完了（provision_done）・送出開始（publish_started）・ライブ確定（live_confirmed）・
#                中断（interrupted。中断の通知・心拍の途絶）・復帰（resumed。復帰の通知・送出中の心拍）
#                ＝ Contract::BroadcastEventType の値
#   終了の事象   終了理由そのもの（Contract::EndReason の 13 種）。タイムアウト・停止・取り消し・YouTube 側の終了・認可失効など
#
# 規則
#   * 25.1 の遷移表を、1 本の矢印ごとに持つ（進行 5 本・終了 30 本）。認可失効（authorization_revoked）は、図では確定待ち・ライブ・
#     中断だけに描かれているが、10.6（更新トークンが無効：進行中の配信は終了する）により、終了していないすべての状態から終了へ遷移する
#   * 定義のない組は、状態を変えない（例外にしない。next_state が元の状態で、effects は空）。終了済みの配信は、どの事象でも
#     終了のまま、効果も無い（終了の事象は冪等。終了処理を再び始めない）
#   * 契約に無い状態・事象（誤り）は、定義のない組とは区別して、ArgumentError
#   * 副作用は実行しない。効果（effects）は、Directive（種別と引数）の値で返す
#       consume_allowance      利用枠の消費（確定待ち → ライブ。8.1・14 章。同一トランザクションで行う）
#       verify_youtube_status  YouTube の状態確認（中断 → ライブの復帰時。10.3）
#       terminate              終了処理の開始（reason: 終了理由。TerminationPlanner.plan の入力）
#   * 期限（13.2）による遷移・事象の発生は、この規則の外（DeadlineEvaluator が指示を返し、呼び出し側が事象にして渡す）
class BroadcastStateMachine
  # 遷移の結果。next_state は次の状態（文字列）、effects は Directive の配列（凍結）。
  Transition = Data.define(:next_state, :effects)

  S = Contract::BroadcastState
  E = Contract::BroadcastEventType
  R = Contract::EndReason
  private_constant :S, :E, :R

  NO_EFFECTS = [].freeze
  private_constant :NO_EFFECTS

  # 25.1 の進行の遷移。（状態, 事象）=> 結果
  PROGRESS = {
    [ S::RESERVED, E::PROVISION_DONE ] => Transition.new(next_state: S::AWAITING_MEDIA, effects: NO_EFFECTS),
    [ S::AWAITING_MEDIA, E::PUBLISH_STARTED ] => Transition.new(next_state: S::CONFIRMING, effects: NO_EFFECTS),
    [ S::CONFIRMING, E::LIVE_CONFIRMED ] => Transition.new(next_state: S::LIVE, effects: [ Directive.of(:consume_allowance) ].freeze),
    [ S::LIVE, E::INTERRUPTED ] => Transition.new(next_state: S::INTERRUPTED, effects: NO_EFFECTS),
    [ S::INTERRUPTED, E::RESUMED ] => Transition.new(next_state: S::LIVE, effects: [ Directive.of(:verify_youtube_status) ].freeze)
  }.freeze
  private_constant :PROGRESS

  # 25.1 の終了の遷移。状態 => 終了へ遷移させる事象（終了理由）。行末は、図の矢印の見出し。
  ENDINGS = {
    S::RESERVED => [
      R::START_TIMEOUT, # 受理から 90 秒以内に送出待ちへ進まない
      R::PREPARE_FAILED, R::PRIOR_UNSETTLED, # 準備の失敗・先行配信が未清算
      R::INSUFFICIENT_BANDWIDTH, R::USER_CANCEL, R::ADMIN_STOP, # 回線不足・取り消し・管理者による停止
      R::AUTHORIZATION_REVOKED # 認可失効（10.6）
    ].freeze,
    S::AWAITING_MEDIA => [
      R::START_TIMEOUT, # 30 秒以内に送出開始なし
      R::USER_CANCEL, R::ADMIN_STOP, # 取り消し・管理者による停止
      R::AUTHORIZATION_REVOKED # 認可失効（10.6）
    ].freeze,
    S::CONFIRMING => [
      R::CONFIRM_TIMEOUT, # 120 秒以内にライブにならない
      R::USER_CANCEL, R::ADMIN_STOP, R::RELAY_DISCONNECT, # 取り消し・管理者による停止・中継による切断
      R::AUTHORIZATION_REVOKED, R::YOUTUBE_ENDED # 認可失効・YouTube 側で終端
    ].freeze,
    S::LIVE => [
      R::USER_STOP, R::TIME_LIMIT, R::ADMIN_STOP, # 停止操作・時間上限・管理者による停止
      R::YOUTUBE_ENDED, R::AUTHORIZATION_REVOKED, R::RELAY_DISCONNECT # YouTube 側で終端・認可失効・中継による切断
    ].freeze,
    S::INTERRUPTED => [
      R::CONNECTION_LOST, # 期限内に復帰なし・復帰が 10 回を超過
      R::YOUTUBE_ENDED, R::AUTHORIZATION_REVOKED, R::RELAY_DISCONNECT, # YouTube 側で終端・認可失効・中継による切断
      R::USER_STOP, R::TIME_LIMIT, R::ADMIN_STOP # 停止操作・時間上限・管理者による停止
    ].freeze
  }.freeze
  private_constant :ENDINGS

  private_class_method :new

  class << self
    # 現在の状態と事象から、次の状態と副作用の指示を返す。定義のない組は、状態を変えない。
    def transition(state:, event:)
      check_inputs!(state, event)

      PROGRESS.fetch([ state, event ]) do
        if ENDINGS.fetch(state, NO_EFFECTS).include?(event)
          ending(event)
        else
          unchanged(state)
        end
      end
    end

    private

    def check_inputs!(state, event)
      LifecycleChecks.contract_value!(S, state, "state")
      return if E.valid?(event) || R.valid?(event)

      raise ArgumentError, "event must be a Contract::BroadcastEventType or Contract::EndReason value, got #{event.inspect}"
    end

    def ending(reason)
      Transition.new(next_state: S::ENDED, effects: [ Directive.of(:terminate, reason: reason) ].freeze)
    end

    def unchanged(state)
      Transition.new(next_state: -state, effects: NO_EFFECTS)
    end
  end
end
