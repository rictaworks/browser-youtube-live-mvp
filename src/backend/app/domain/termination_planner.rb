# frozen_string_literal: true

# 終了処理（requirements.md 15 章「終了処理」・10.4）。どの起点（利用者の停止・取り消し・期限・YouTube 側の終了・
# 管理者による停止・中継による切断など）でも、同じ規則で、終了の手順を計画する。
#
#   plan = TerminationPlanner.plan(broadcast: snapshot, reason: "user_stop")
#   plan.settlement_state   # => "pending"（YouTube 資源を持つ）または "none"（持たない）
#   plan.steps              # => [end_broadcast, stop_publishing, settle]（none のときは settle が無い）
#
# 手順（10.4）。順序は「終了（清算状態を同時に確定）→ 送出停止の指示 → 清算」。
#   end_broadcast     配信レコードを終了とし、同時に清算状態を定める（reason・settlement_state）。同一のトランザクションで行う
#   stop_publishing   心拍の応答で、中継へ送出の停止を指示する（利用者の停止では、ブラウザの終了通知により中継は止まっているが、
#                     どの起点でも同じ手順にする）
#   settle            YouTube 資源を清算する（YouTube 資源を持つときだけ。終了・清算枠から支出する）
#
# 清算状態の初期値（25.2）
#   YouTube 資源（配信の識別子）を持つ  pending（未清算）。10.5 の「終了と同時の未清算」。清算の結果が出るまで、未清算として扱う
#   持たない                            none（不要）。終端なので、予約の残額を即座に解放する（release_reservation が true）
#   pending は、終端（清算済み・清算不能）に達するまで、予約の残額を解放しない（8.4。解放は SettlementRules の指示）
# タイトルは、配信レコードの終了時に消去する（clear_title。10.1・20.3）。
#
# 計画は、清算の結果に依存しない（引数に取らない）。清算の成否・所要時間に関わらず、配信レコードは終了で、利用者の次の操作を妨げない。
# 副作用は実行しない。手順は Directive の値で返す。
class TerminationPlanner
  # 終了済みの配信に計画しようとした。清算状態を、あとから上書きして戻さないため、拒否する。
  class AlreadyEnded < ArgumentError; end

  # 計画。end_reason は終了理由、settlement_state は清算状態の初期値、steps は Directive の配列（順序どおり）、
  # release_reservation は予約の残額を即座に解放するか、clear_title はタイトルを消去するか。
  Plan = Data.define(:end_reason, :settlement_state, :steps, :release_reservation, :clear_title) do
    # 清算の指示があるか（YouTube 資源を持つとき）。
    def settle?
      steps.any? { |step| step.kind == :settle }
    end
  end

  SS = Contract::SettlementState
  private_constant :SS

  private_class_method :new

  class << self
    # broadcast（終了していない配信のスナップショット）を、reason（Contract::EndReason）で終了させる手順を計画する。
    def plan(broadcast:, reason:)
      LifecycleChecks.kind!(broadcast, BroadcastSnapshot, "broadcast")
      LifecycleChecks.contract_value!(Contract::EndReason, reason, "reason")
      raise AlreadyEnded, "broadcast is already ended (broadcast_id=#{broadcast.id})" if broadcast.ended?

      settlement_state = broadcast.youtube_resource? ? SS::PENDING : SS::NONE
      Plan.new(
        end_reason: reason,
        settlement_state: settlement_state,
        steps: steps_for(reason, settlement_state).freeze,
        release_reservation: SettlementRules.terminal?(settlement_state),
        clear_title: true
      )
    end

    private

    def steps_for(reason, settlement_state)
      steps = [
        Directive.of(:end_broadcast, reason: reason, settlement_state: settlement_state),
        Directive.of(:stop_publishing)
      ]
      steps << Directive.of(:settle, bucket: SettlementRules::BUCKET) unless SettlementRules.terminal?(settlement_state)
      steps
    end
  end
end
