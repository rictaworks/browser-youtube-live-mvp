# frozen_string_literal: true

# 先行配信の清算確認（requirements.md 15 章「先行配信の清算確認」・10.5・8.4）。
#
#   plan = PriorSettlementCheck.plan(
#     prior_broadcasts: [...],        # 当該アカウントの、終了した先行配信のスナップショット
#     current_stream_id: "...",       # 現在の配信用ストリームの識別子（無ければ nil）
#     prep_remaining_units: 340,      # 新しい配信の、準備・確認枠の残額
#     own_prep_cost_units: 202        # 新しい配信の準備に、このあと要する額（8.4 の表の準備の各呼び出しの上限の合計。
#                                     例: 応答喪失時の一覧取得 1 + 配信の作成 50 + ストリームの確認 1 + ストリームの作成 50 + 紐づけ 50 + 再試行 50）
#   )
#
# 配信用ストリームはアカウントごとに再利用する。以前の配信が YouTube 上で終端に達していない状態で同じストリームへ送出すると、
# 以前の配信へ映像が流れる。準備の最初の段（10.1 の段 1）で、次のとおり確認する。
#
#   確認の対象（confirm_targets）  現在の配信用ストリームへ紐づいた「未清算」の配信。すべてが対象。
#                                  YouTube の状態を確認し、終端でなければ現在有効な認可で清算する。1 件でも終端にできなければ、
#                                  準備を中止し、配信を終了する（on_unsettled。終了理由 prior_unsettled。開始試行を計上しない）。
#                                  現在のストリームの識別子と同じ識別子を持てば対象にする（紐づけの印には依らない。
#                                  紐づけの呼び出しと保存の間の失敗で、印の無い配信が、実際には紐づいている場合に備える。安全側）。
#   再清算の対象（resettle_targets） 「清算不能」の配信。ストリームの取り替えで、以後の配信と切り離されているので、準備を妨げない
#                                  （再清算が失敗しても、準備を止めない）。次回の準備時に、現在の認可での清算を試みる。
#                                  準備・確認枠の残額が（未清算の確認と自配信の準備に要する額）を超える範囲でのみ。
#                                  余裕 = 残額 - 確認の費用 - 自配信の準備の費用。1 件 51 ユニットで、余裕が足りる件数まで
#                                  （終了の早い順）。
#
# 判定（verdict）
#   clear           確認の対象が無い。準備へ進める（再清算の対象は、best-effort で試みる）
#   settle_required 確認の対象があり、残額で確認できる。すべてを終端にできたときだけ、準備へ進める
#   abort           確認の対象があり、残額が確認に足りない。支出せず、直ちに準備を中止する（on_unsettled）
#
# YouTube の識別子を消去した配信は、清算の手がかりが無いので対象外。他のアカウントの配信は、対象にしない
# （複数のアカウントの配信が混ざっていたら、MixedAccounts）。終了していない配信は、清算状態が none（BroadcastSnapshot の検査）なので、
# 未清算・清算不能のどちらにも当たらず、対象にならない。副作用は実行しない。
class PriorSettlementCheck
  # 複数のアカウントの配信が混ざっている。黙って処理しない。
  class MixedAccounts < ArgumentError; end

  # 計画。confirm_targets・resettle_targets は BroadcastSnapshot の配列（終了の早い順）、confirm_cost_units・
  # resettle_cost_units は、それぞれの最大の支出（ユニット）、on_unsettled は準備を中止するときの指示。
  Plan = Data.define(:verdict, :confirm_targets, :resettle_targets, :confirm_cost_units, :resettle_cost_units, :on_unsettled)

  SS = Contract::SettlementState
  private_constant :SS

  VERDICT_CLEAR = :clear
  VERDICT_SETTLE_REQUIRED = :settle_required
  VERDICT_ABORT = :abort

  # 先行配信の清算は、新しい配信の準備・確認枠から支出する。枠は、#5 の QuotaPolicy の予約の枠（BUCKETS）と同じ符号（:prep）。
  # 1 件の試行は、状態確認 1 + 清算 50（51 ユニット）
  BUCKET = :prep
  ATTEMPT_COST_UNITS = SettlementRules::ATTEMPT_COST_UNITS

  # 1 件でも終端にできなければ、準備を中止して配信を終了する。開始試行は、計上しない（8.2・10.5）
  ON_UNSETTLED = Directive.of(:abort_preparation, end_reason: Contract::EndReason::PRIOR_UNSETTLED, count_attempt: false)

  private_class_method :new

  class << self
    def plan(prior_broadcasts:, current_stream_id:, prep_remaining_units:, own_prep_cost_units:)
      check_inputs!(prior_broadcasts, current_stream_id, prep_remaining_units, own_prep_cost_units)

      candidates = prior_broadcasts.select(&:youtube_resource?)
      confirm = oldest_first(candidates.select { |broadcast| confirmation_target?(broadcast, current_stream_id) })
      confirm_cost = confirm.size * ATTEMPT_COST_UNITS
      verdict = verdict_for(confirm, confirm_cost, prep_remaining_units)
      resettle = resettlement_targets(candidates, verdict, spare_units(prep_remaining_units, confirm_cost, own_prep_cost_units))

      Plan.new(
        verdict: verdict,
        confirm_targets: confirm.freeze,
        resettle_targets: resettle.freeze,
        confirm_cost_units: confirm_cost,
        resettle_cost_units: resettle.size * ATTEMPT_COST_UNITS,
        on_unsettled: ON_UNSETTLED
      )
    end

    private

    def check_inputs!(prior_broadcasts, current_stream_id, prep_remaining_units, own_prep_cost_units)
      LifecycleChecks.kind!(prior_broadcasts, Array, "prior_broadcasts")
      prior_broadcasts.each { |broadcast| LifecycleChecks.kind!(broadcast, BroadcastSnapshot, "prior_broadcasts element") }
      check_single_account!(prior_broadcasts)
      LifecycleChecks.text_or_nil!(current_stream_id, "current_stream_id")
      LifecycleChecks.integer!(prep_remaining_units, "prep_remaining_units", min: 0)
      LifecycleChecks.integer!(own_prep_cost_units, "own_prep_cost_units", min: 0)
    end

    # 他のアカウントの配信を、対象にしない。混ざっていたら、どれが「当該アカウント」か判断できないので、拒否する。
    # メッセージには、配信の識別子だけを載せる（アカウントの識別子は出さない）。
    def check_single_account!(prior_broadcasts)
      reference = prior_broadcasts.first&.user_id
      mismatched = prior_broadcasts.reject { |broadcast| broadcast.user_id == reference }
      return if mismatched.empty?

      raise MixedAccounts, "prior_broadcasts must belong to one account (mismatching broadcast_ids=#{mismatched.map(&:id).join(',')})"
    end

    # 現在の配信用ストリームへ紐づいた未清算
    def confirmation_target?(broadcast, current_stream_id)
      broadcast.settlement_state == SS::PENDING && !current_stream_id.nil? && broadcast.youtube_stream_id == current_stream_id
    end

    def verdict_for(confirm, confirm_cost, prep_remaining_units)
      return VERDICT_CLEAR if confirm.empty?

      confirm_cost > prep_remaining_units ? VERDICT_ABORT : VERDICT_SETTLE_REQUIRED
    end

    # 再清算の余裕（ユニット）。残額から、確認の費用と、自配信の準備の費用を引いたもの。負なら 0
    def spare_units(prep_remaining_units, confirm_cost, own_prep_cost_units)
      [ prep_remaining_units - confirm_cost - own_prep_cost_units, 0 ].max
    end

    # 清算不能の配信を、余裕の範囲の件数だけ、終了の早い順に選ぶ。中止（abort）のときは、支出しないので、選ばない。
    def resettlement_targets(candidates, verdict, spare)
      return [] if verdict == VERDICT_ABORT

      abandoned = oldest_first(candidates.select { |broadcast| broadcast.settlement_state == SS::ABANDONED })
      abandoned.first(spare / ATTEMPT_COST_UNITS)
    end

    def oldest_first(broadcasts)
      broadcasts.sort_by { |broadcast| [ broadcast.ended_at, broadcast.id ] }
    end
  end
end
