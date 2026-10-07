require "spec_helper"
require_relative "../support/domain_loader"
require_relative "support/lifecycle_helpers"

# 先行配信の清算確認（requirements.md 15 章「先行配信の清算確認」・10.5・8.4）。
# PriorSettlementCheck.plan(prior_broadcasts:, current_stream_id:, prep_remaining_units:, own_prep_cost_units:)
#
# 配信用ストリームはアカウントごとに再利用する。以前の配信が YouTube 上で終端に達していない状態で同じストリームへ送出すると、
# 以前の配信へ映像が流れる。準備の最初の段で、次のとおり確認する。
#   * 現在の配信用ストリームへ紐づいた「未清算」: すべて確認の対象。1 件でも終端にできなければ、準備を中止する
#     （終了理由 prior_unsettled。開始試行を計上しない）
#   * 「清算不能」（ストリームの取り替えで、以後の配信と切り離されている）: 準備を妨げない。準備・確認枠の残額が
#     （未清算の確認と自配信の準備に要する額）を超える範囲でのみ、再清算の対象にする
# YouTube の識別子を消去した配信は、対象外。他のアカウントの配信は、対象にしない。
RSpec.describe "先行配信の清算確認（PriorSettlementCheck）" do
  include LifecycleSpecHelpers

  # 先行配信（終了済み）。既定は、現在のストリーム（dummy-stream-A）に紐づいた配信
  def prior(id, settlement_state:, stream: "dummy-stream-A", ended: 100, **overrides)
    attempts = settlement_state == "abandoned" ? 4 : 1
    ended_snapshot(
      id: id, settlement_state: settlement_state, settlement_attempts: attempts, youtube_stream_id: stream,
      ended_at: LifecycleSpecHelpers::T0 + ended, **overrides
    )
  end

  def pending(id, **overrides)
    prior(id, settlement_state: "pending", **overrides)
  end

  def abandoned(id, **overrides)
    prior(id, settlement_state: "abandoned", **overrides)
  end

  # 1 件の準備に要する額の目安（既定）: 準備・確認枠 340 のうち、自配信の準備に 202
  def check(priors, stream: "dummy-stream-A", remaining: 340, own: 202)
    PriorSettlementCheck.plan(prior_broadcasts: priors, current_stream_id: stream, prep_remaining_units: remaining, own_prep_cost_units: own)
  end

  def ids(snapshots)
    snapshots.map(&:id)
  end

  describe "支出の単位（8.4・10.5）" do
    it "先行配信の清算は、新しい配信の準備・確認枠（#5 の QuotaPolicy の予約の枠 :prep）から支出する。1 件の試行は 51 ユニット（状態確認 1 + 清算 50）" do
      expect(PriorSettlementCheck::BUCKET).to eq(:prep)
      expect(PriorSettlementCheck::ATTEMPT_COST_UNITS).to eq(SettlementRules::ATTEMPT_COST_UNITS)
      expect(PriorSettlementCheck::ATTEMPT_COST_UNITS).to eq(51)
    end

    it "中止のときの指示: 準備を中止し、終了理由は prior_unsettled（先行配信が未清算）、開始試行を計上しない" do
      expect(check([ pending("dummy-prior-1") ]).on_unsettled).to eq(
        Directive.of(:abort_preparation, end_reason: "prior_unsettled", count_attempt: false)
      )
    end

    it "中止の終了理由は、状態遷移の表で、受理済みから終了へ遷移できる" do
      reason = check([]).on_unsettled.args.fetch(:end_reason)

      expect(BroadcastStateMachine.transition(state: "reserved", event: reason).next_state).to eq("ended")
    end
  end

  describe "現在のストリームへ紐づいた「未清算」: すべて確認の対象" do
    it "先行配信が無ければ、確認は要らない（準備へ進める）" do
      plan = check([])

      expect(plan.verdict).to eq(:clear)
      expect(plan.confirm_targets).to eq([])
      expect(plan.resettle_targets).to eq([])
      expect(plan.confirm_cost_units).to eq(0)
      expect(plan.resettle_cost_units).to eq(0)
    end

    it "現在のストリームへ紐づいた未清算 1 件: 確認の対象（51 ユニット）。清算できるまで、準備へ進めない" do
      plan = check([ pending("dummy-prior-1") ])

      expect(plan.verdict).to eq(:settle_required)
      expect(ids(plan.confirm_targets)).to eq([ "dummy-prior-1" ])
      expect(plan.confirm_cost_units).to eq(51)
    end

    it "複数件（3 件）: すべて対象。終了の早い順（同じ時刻なら、識別子の順）" do
      priors = [ pending("dummy-prior-3", ended: 300), pending("dummy-prior-2b", ended: 200), pending("dummy-prior-2a", ended: 200), pending("dummy-prior-1", ended: 100) ]
      plan = check(priors)

      expect(ids(plan.confirm_targets)).to eq(%w[dummy-prior-1 dummy-prior-2a dummy-prior-2b dummy-prior-3])
      expect(plan.confirm_cost_units).to eq(4 * 51)
    end

    it "別のストリーム（取り替える前の古いストリーム）へ紐づいた未清算は、対象にしない（以後の配信と切り離されている）" do
      plan = check([ pending("dummy-prior-1", stream: "dummy-stream-OLD") ])

      expect(plan.verdict).to eq(:clear)
      expect(plan.confirm_targets).to eq([])
    end

    it "現在のストリームの識別子が無い（保存していない・破棄済み）なら、紐づく先行配信は無い" do
      plan = check([ pending("dummy-prior-1") ], stream: nil)

      expect(plan.verdict).to eq(:clear)
      expect(plan.confirm_targets).to eq([])
    end

    it "ストリームの識別子を持たない未清算は、現在のストリームへ紐づいていないので、対象にしない" do
      plan = check([ pending("dummy-prior-1", stream: nil) ])

      expect(plan.confirm_targets).to eq([])
    end

    it "YouTube の識別子を消去済みの未清算は、対象外（清算の手がかりが無い）" do
      plan = check([ pending("dummy-prior-1", youtube_broadcast_id: nil) ])

      expect(plan.verdict).to eq(:clear)
      expect(plan.confirm_targets).to eq([])
    end

    it "清算済み・不要は、対象外" do
      plan = check([ prior("dummy-prior-1", settlement_state: "settled"), prior("dummy-prior-2", settlement_state: "none") ])

      expect(plan.verdict).to eq(:clear)
      expect(plan.confirm_targets).to eq([])
      expect(plan.resettle_targets).to eq([])
    end

    it "終了していない配信が混ざっていても、対象にしない" do
      plan = check([ snapshot("reserved", id: "dummy-current"), pending("dummy-prior-1") ])

      expect(ids(plan.confirm_targets)).to eq([ "dummy-prior-1" ])
    end

    it "配信の識別子が同じでも、紐づけの印（bound）には依らず、同じストリームの識別子なら対象（bind の応答の保存の前に失敗した配信を見逃さない。安全側）" do
      expect(check([ pending("dummy-prior-1") ]).confirm_targets.size).to eq(1)
    end
  end

  describe "準備・確認枠の残額が、確認に足りないとき" do
    {
      "1 件・残額 51（ちょうど足りる）" => [ 1, 51, :settle_required ],
      "1 件・残額 50（1 ユニット足りない）" => [ 1, 50, :abort ],
      "3 件・残額 153（ちょうど）" => [ 3, 153, :settle_required ],
      "3 件・残額 152" => [ 3, 152, :abort ],
      "1 件・残額 0" => [ 1, 0, :abort ]
    }.each do |label, (count, remaining, verdict)|
      it "#{label}: #{verdict}" do
        priors = Array.new(count) { |index| pending("dummy-prior-#{index}", ended: 100 + index) }
        plan = check(priors, remaining: remaining, own: 0)

        expect(plan.verdict).to eq(verdict)
        expect(plan.confirm_targets.size).to eq(count)
      end
    end

    it "足りなければ、準備を中止する（支出せず、再清算も試みない）" do
      plan = check([ pending("dummy-prior-1"), abandoned("dummy-prior-2") ], remaining: 50, own: 0)

      expect(plan.verdict).to eq(:abort)
      expect(plan.resettle_targets).to eq([])
      expect(plan.resettle_cost_units).to eq(0)
    end

    it "未清算が無ければ、残額が 0 でも、確認は要らない" do
      expect(check([], remaining: 0, own: 0).verdict).to eq(:clear)
    end
  end

  describe "「清算不能」の再清算: 残額が（未清算の確認と自配信の準備に要する額）を超える範囲でのみ" do
    # 余裕 = 残額 - 確認の費用 - 自配信の準備の費用。再清算 1 件は 51 ユニット。余裕が 51 以上の件数だけ、再清算する
    {
      "余裕 51（ちょうど 1 件分）: 1 件" => [ [ 1, 51 ], 1 ],
      "余裕 50（1 ユニット足りない）: 0 件" => [ [ 1, 50 ], 0 ],
      "余裕 102（2 件分）: 2 件" => [ [ 2, 102 ], 2 ],
      "余裕 101: 1 件" => [ [ 2, 101 ], 1 ],
      "余裕 138（2 件分と少し）、清算不能が 5 件: 2 件" => [ [ 5, 138 ], 2 ],
      "余裕 1000、清算不能が 3 件: 3 件（件数を超えない）" => [ [ 3, 1000 ], 3 ],
      "余裕 0: 0 件" => [ [ 3, 0 ], 0 ]
    }.each do |label, ((count, spare), expected)|
      it "#{label}" do
        abandoned_priors = Array.new(count) { |index| abandoned("dummy-prior-#{index}", ended: 100 + index, stream: "dummy-stream-OLD") }
        plan = check(abandoned_priors, remaining: 202 + spare, own: 202)

        expect(plan.resettle_targets.size).to eq(expected)
        expect(plan.resettle_cost_units).to eq(expected * 51)
        expect(plan.verdict).to eq(:clear)
      end
    end

    it "余裕が負（残額が、自配信の準備にも足りない）: 0 件" do
      plan = check([ abandoned("dummy-prior-1") ], remaining: 100, own: 202)

      expect(plan.resettle_targets).to eq([])
    end

    it "未清算の確認の費用も、余裕から引く（未清算 1 件 51 + 自配信 202 = 253 を、残額に残す）" do
      priors = [ pending("dummy-prior-p"), abandoned("dummy-prior-a1", ended: 100), abandoned("dummy-prior-a2", ended: 101) ]

      expect(check(priors, remaining: 253 + 51, own: 202).resettle_targets.size).to eq(1)
      expect(check(priors, remaining: 253 + 50, own: 202).resettle_targets.size).to eq(0)
      expect(check(priors, remaining: 253 + 102, own: 202).resettle_targets.size).to eq(2)
    end

    it "既定の残額（340）と、自配信の準備 202 では、清算不能の再清算は 2 件まで（340 - 202 = 138）" do
      priors = Array.new(5) { |index| abandoned("dummy-prior-#{index}", ended: 100 + index) }

      expect(check(priors).resettle_targets.size).to eq(2)
    end

    it "再清算の対象は、終了の早い順に選ぶ（同じ時刻なら、識別子の順）" do
      priors = [ abandoned("dummy-prior-c", ended: 300), abandoned("dummy-prior-a", ended: 100), abandoned("dummy-prior-b", ended: 200) ]
      plan = check(priors, remaining: 202 + 102, own: 202)

      expect(ids(plan.resettle_targets)).to eq(%w[dummy-prior-a dummy-prior-b])
    end

    it "ストリームの識別子によらず、対象にする（取り替えで、切り離されているため）" do
      priors = [ abandoned("dummy-prior-1", stream: "dummy-stream-OLD"), abandoned("dummy-prior-2", stream: nil) ]

      expect(ids(check(priors).resettle_targets)).to eq(%w[dummy-prior-1 dummy-prior-2])
    end

    it "YouTube の識別子を消去済みの清算不能は、再清算の対象外" do
      plan = check([ abandoned("dummy-prior-1", youtube_broadcast_id: nil) ])

      expect(plan.resettle_targets).to eq([])
    end

    it "清算不能は、準備を妨げない（清算不能だけなら、準備へ進める。再清算が失敗しても同じ）" do
      plan = check([ abandoned("dummy-prior-1"), abandoned("dummy-prior-2") ], remaining: 0, own: 0)

      expect(plan.verdict).to eq(:clear)
    end

    it "未清算と清算不能が混在: 準備の可否は、未清算だけで決まる" do
      plan = check([ pending("dummy-prior-p"), abandoned("dummy-prior-a") ])

      expect(plan.verdict).to eq(:settle_required)
      expect(ids(plan.confirm_targets)).to eq([ "dummy-prior-p" ])
      expect(ids(plan.resettle_targets)).to eq([ "dummy-prior-a" ])
    end
  end

  describe "所有権: 他のアカウントの配信を対象にしない（14 章）" do
    it "複数のアカウントの配信が混ざっていたら、黙って処理せず、MixedAccounts（ArgumentError）" do
      priors = [ pending("dummy-prior-1"), pending("dummy-prior-2", user_id: "dummy-user-2") ]

      expect { check(priors) }.to raise_error(PriorSettlementCheck::MixedAccounts, /prior_broadcasts must belong to one account/)
      expect(PriorSettlementCheck::MixedAccounts.ancestors).to include(ArgumentError)
    end

    it "メッセージに、配信の識別子（アカウントの識別子は出さない）を載せる" do
      priors = [ pending("dummy-prior-1"), pending("dummy-prior-2", user_id: "dummy-user-2") ]

      expect { check(priors) }.to raise_error(PriorSettlementCheck::MixedAccounts) { |error|
        expect(error.message).to include("dummy-prior-2")
        expect(error.message).not_to include("dummy-user")
      }
    end

    it "同じアカウントの配信だけなら通す" do
      expect { check([ pending("dummy-prior-1"), abandoned("dummy-prior-2") ]) }.not_to raise_error
    end
  end

  describe "検査" do
    it "prior_broadcasts が配列でなければ ArgumentError" do
      expect { check(nil) }.to raise_error(ArgumentError, "prior_broadcasts must be a Array, got NilClass")
    end

    it "prior_broadcasts の要素が BroadcastSnapshot でなければ ArgumentError" do
      expect { check([ {} ]) }.to raise_error(ArgumentError, "prior_broadcasts element must be a BroadcastSnapshot, got Hash")
    end

    [ "", "  ", 1, :stream ].each do |stream|
      it "現在のストリームの識別子が、nil か空でない文字列でなければ（#{stream.inspect}）ArgumentError" do
        expect { check([], stream: stream) }.to raise_error(ArgumentError, /current_stream_id must be a non-empty String or nil/)
      end
    end

    it "準備・確認枠の残額・自配信の準備の費用は、0 以上の整数" do
      expect { check([], remaining: -1) }.to raise_error(ArgumentError, "prep_remaining_units must be >= 0, got -1")
      expect { check([], remaining: 1.5) }.to raise_error(ArgumentError, "prep_remaining_units must be an Integer, got Float")
      expect { check([], own: -1) }.to raise_error(ArgumentError, "own_prep_cost_units must be >= 0, got -1")
      expect { check([], own: nil) }.to raise_error(ArgumentError, "own_prep_cost_units must be an Integer, got NilClass")
    end
  end

  describe "純粋性・不変" do
    it "同じ入力に、等しい出力を返す。計画も、対象の一覧も凍結された値" do
      priors = [ pending("dummy-prior-1"), abandoned("dummy-prior-2") ]
      first = check(priors)

      expect(check(priors)).to eq(first)
      expect(first).to be_frozen
      expect(first.confirm_targets).to be_frozen
      expect(first.resettle_targets).to be_frozen
    end

    it "入力の配列を変えない（並べ替えも、書き換えもしない）" do
      priors = [ pending("dummy-prior-2", ended: 200), pending("dummy-prior-1", ended: 100) ]
      original = priors.dup

      check(priors)

      expect(priors).to eq(original)
    end

    it "Plan は、判定・確認の対象・再清算の対象・それぞれの費用・中止の指示を持つ" do
      expect(PriorSettlementCheck::Plan.members).to eq(
        %i[verdict confirm_targets resettle_targets confirm_cost_units resettle_cost_units on_unsettled]
      )
    end

    it "インスタンスを作らない（状態を持たない）" do
      expect { PriorSettlementCheck.new }.to raise_error(NoMethodError)
    end
  end
end
