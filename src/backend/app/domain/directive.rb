# frozen_string_literal: true

# 指示を表す不変の値。種別（シンボル）と、引数（シンボルのキーの Hash）だけを持つ。実行しない。
#
# 配信の生命周期の規則（Domain Core）は、副作用を実行せず、「何をするか」をこの値で返す。呼び出し側（アプリケーション層の
# アダプタ）が、種別に応じて実行する。同じ値を、次の場所で使う。
#   BroadcastStateMachine::Transition#effects   状態遷移の効果（利用枠の消費・YouTube の状態確認・終了処理の開始）
#   DeadlineEvaluator.evaluate                  期限の評価の結果（遷移の指示）
#   TerminationPlanner::Plan#steps              終了処理の手順（終了・送出停止の指示・清算）
#   SettlementRules                             清算の指示と、結果の反映後の指示（予約の解放・ストリームの識別子の破棄）
#
#   Directive.of(:end, reason: "start_timeout")   # kind は :end、args は { reason: "start_timeout" }
#
# 引数は複写して凍結する（作成後に、元の Hash を変えても影響しない）。値が同じなら等しい。
class Directive < Data.define(:kind, :args)
  class << self
    # 種別と、キーワードの引数から作る。
    def of(kind, **args)
      new(kind: kind, args: args)
    end
  end

  def initialize(kind:, args: {})
    LifecycleChecks.kind!(kind, Symbol, "kind")
    LifecycleChecks.kind!(args, Hash, "args")
    args.each_key { |key| LifecycleChecks.kind!(key, Symbol, "args keys") }
    super(kind: kind, args: args.dup.freeze)
  end
end
