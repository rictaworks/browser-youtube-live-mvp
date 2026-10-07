require "spec_helper"
require_relative "../support/domain_loader"

# 配信の状態遷移（requirements.md 15 章「配信の状態遷移」・25.1）。BroadcastStateMachine.transition(state:, event:)。
#
# 事象は契約の符号（文字列）。進行の事象 5 種（Contract::BroadcastEventType の provision_done・publish_started・
# live_confirmed・interrupted・resumed）と、終了の事象（Contract::EndReason の 13 種。事象の符号が終了理由そのもの）。
# 定義のない組は、状態を変えない（例外にしない。next_state が元の状態で、effects が空）。
# 契約に無い状態・事象（誤り）は、黙って通さず ArgumentError。
RSpec.describe "配信の状態遷移（BroadcastStateMachine）" do
  states = %w[reserved awaiting_media confirming live interrupted ended]
  progress_events = %w[provision_done publish_started live_confirmed interrupted resumed]
  end_reasons = %w[
    user_stop time_limit connection_lost youtube_ended authorization_revoked admin_stop start_timeout
    confirm_timeout prepare_failed prior_unsettled insufficient_bandwidth user_cancel relay_disconnect
  ]

  # 25.1 の進行の遷移。1 行が 1 本の矢印。効果は [種別, 引数] の配列
  progress_rows = [
    [ "reserved", "provision_done", "awaiting_media", [] ],
    [ "awaiting_media", "publish_started", "confirming", [] ],
    [ "confirming", "live_confirmed", "live", [ [ :consume_allowance, {} ] ] ],
    [ "live", "interrupted", "interrupted", [] ],
    [ "interrupted", "resumed", "live", [ [ :verify_youtube_status, {} ] ] ]
  ]

  # 25.1 の終了の遷移。状態 => { 矢印の見出し => 事象（終了理由）}。
  # 認可失効は、図では確定待ち・ライブ・中断だけに描かれているが、10.6（更新トークンが無効：進行中の配信は終了する）により、
  # 終了していないすべての状態から終了へ遷移する（issue #6）。
  ending_rows = {
    "reserved" => {
      "受理から 90 秒以内に送出待ちへ進まない" => %w[start_timeout],
      "準備の失敗・先行配信が未清算" => %w[prepare_failed prior_unsettled],
      "回線不足・取り消し・管理者による停止" => %w[insufficient_bandwidth user_cancel admin_stop],
      "認可失効（10.6）" => %w[authorization_revoked]
    },
    "awaiting_media" => {
      "30 秒以内に送出開始なし" => %w[start_timeout],
      "取り消し・管理者による停止" => %w[user_cancel admin_stop],
      "認可失効（10.6）" => %w[authorization_revoked]
    },
    "confirming" => {
      "120 秒以内にライブにならない" => %w[confirm_timeout],
      "取り消し・管理者による停止・中継による切断" => %w[user_cancel admin_stop relay_disconnect],
      "認可失効・YouTube 側で終端" => %w[authorization_revoked youtube_ended]
    },
    "live" => {
      "停止操作・時間上限・管理者による停止" => %w[user_stop time_limit admin_stop],
      "YouTube 側で終端・認可失効・中継による切断" => %w[youtube_ended authorization_revoked relay_disconnect]
    },
    "interrupted" => {
      "期限内に復帰なし・復帰が 10 回を超過" => %w[connection_lost],
      "YouTube 側で終端・認可失効・中継による切断" => %w[youtube_ended authorization_revoked relay_disconnect],
      "停止操作・時間上限・管理者による停止" => %w[user_stop time_limit admin_stop]
    }
  }
  ending_by_state = ending_rows.transform_values { |edges| edges.values.flatten }

  # 定義のある遷移の全体（状態, 事象）=> [次の状態, 効果]
  defined = {}
  progress_rows.each { |state, event, next_state, effects| defined[[ state, event ]] = [ next_state, effects ] }
  ending_by_state.each do |state, reasons|
    reasons.each { |reason| defined[[ state, reason ]] = [ "ended", [ [ :terminate, { reason: reason } ] ] ] }
  end

  def effects_of(pairs)
    pairs.map { |kind, args| Directive.new(kind: kind, args: args) }
  end

  describe "表の整合（このスペックの表が、25.1 の矢印の数と合っている）" do
    it "進行の遷移 5 本・終了の遷移 30 本（受理済み 7・送出待ち 4・確定待ち 6・ライブ 6・中断 7）" do
      expect(progress_rows.size).to eq(5)
      expect(ending_by_state.transform_values(&:size)).to eq(
        "reserved" => 7, "awaiting_media" => 4, "confirming" => 6, "live" => 6, "interrupted" => 7
      )
      expect(defined.size).to eq(35)
    end

    it "表の状態・事象は、契約の符号と一致する（状態 6・終了理由 13・進行の事象は契約の配信の出来事の種別に含まれる）" do
      expect(states).to eq(Contract::BroadcastState::ALL)
      expect(end_reasons).to match_array(Contract::EndReason::ALL)
      expect(Contract::BroadcastEventType::ALL).to include(*progress_events)
    end
  end

  describe "25.1 の遷移を 1 行ずつ（定義のある 35 本）" do
    defined.each do |(state, event), (next_state, effects)|
      it "#{state} + #{event} → #{next_state}（効果: #{effects.map(&:first).inspect}）" do
        transition = BroadcastStateMachine.transition(state: state, event: event)

        expect(transition.next_state).to eq(next_state)
        expect(transition.effects).to eq(effects_of(effects))
      end
    end
  end

  describe "定義のない組は、状態を変えず、効果も無い（例外にしない）" do
    states.product(progress_events + end_reasons).reject { |pair| defined.key?(pair) }.each do |state, event|
      it "#{state} + #{event} → #{state}（効果なし）" do
        transition = BroadcastStateMachine.transition(state: state, event: event)

        expect(transition.next_state).to eq(state)
        expect(transition.effects).to eq([])
      end
    end

    it "状態 6 × 事象 18 = 108 の組のうち、定義があるのは 35。残りの 73 組は、状態を変えない（網羅）" do
      all_pairs = states.product(progress_events + end_reasons)
      unchanged = all_pairs.reject { |pair| defined.key?(pair) }

      expect(all_pairs.size).to eq(108)
      expect(unchanged.size).to eq(73)
      expect(unchanged.all? { |state, event| BroadcastStateMachine.transition(state: state, event: event).next_state == state }).to be(true)
    end

    it "契約の配信の出来事の種別のうち、遷移の事象でないもの（受理・ソース追加・清算成功など）も、定義のない組。状態を変えない" do
      others = Contract::BroadcastEventType::ALL - progress_events

      expect(others.size).to eq(19)
      states.product(others).each do |state, event|
        transition = BroadcastStateMachine.transition(state: state, event: event)

        expect(transition.next_state).to eq(state), "#{state} + #{event}"
        expect(transition.effects).to eq([]), "#{state} + #{event}"
      end
    end
  end

  describe "issue #6 に挙げられた、表にない組" do
    it "ライブ確定前の状態（受理済み・送出待ち・確定待ち）から、利用者の停止（user_stop）は定義が無い（取り消しを使う）" do
      %w[reserved awaiting_media confirming].each do |state|
        expect(BroadcastStateMachine.transition(state: state, event: "user_stop").next_state).to eq(state)
        expect(BroadcastStateMachine.transition(state: state, event: "user_cancel").next_state).to eq("ended")
      end
    end

    it "ライブ後（ライブ・中断）に、利用者の取り消し（user_cancel）は定義が無い（停止を使う）" do
      %w[live interrupted].each do |state|
        expect(BroadcastStateMachine.transition(state: state, event: "user_cancel").next_state).to eq(state)
        expect(BroadcastStateMachine.transition(state: state, event: "user_stop").next_state).to eq("ended")
      end
    end

    it "回線不足（insufficient_bandwidth）は、受理済みからだけ" do
      ended_from = states.select { |state| BroadcastStateMachine.transition(state: state, event: "insufficient_bandwidth").next_state == "ended" && state != "ended" }

      expect(ended_from).to eq([ "reserved" ])
    end

    it "認可失効（authorization_revoked）は、終了していないすべての状態から終了へ遷移する（10.6）" do
      non_ended = states - [ "ended" ]

      non_ended.each do |state|
        transition = BroadcastStateMachine.transition(state: state, event: "authorization_revoked")

        expect(transition.next_state).to eq("ended"), state
        expect(transition.effects).to eq([ Directive.of(:terminate, reason: "authorization_revoked") ]), state
      end
    end

    {
      "接続喪失（connection_lost）" => [ "connection_lost", %w[interrupted] ],
      "確定タイムアウト（confirm_timeout）" => [ "confirm_timeout", %w[confirming] ],
      "開始タイムアウト（start_timeout）" => [ "start_timeout", %w[reserved awaiting_media] ],
      "時間上限（time_limit）" => [ "time_limit", %w[live interrupted] ],
      "準備の失敗（prepare_failed）" => [ "prepare_failed", %w[reserved] ],
      "先行配信が未清算（prior_unsettled）" => [ "prior_unsettled", %w[reserved] ],
      "中継による切断（relay_disconnect）" => [ "relay_disconnect", %w[confirming live interrupted] ],
      "YouTube 側で終了（youtube_ended）" => [ "youtube_ended", %w[confirming live interrupted] ],
      "管理者による停止（admin_stop）" => [ "admin_stop", %w[reserved awaiting_media confirming live interrupted] ],
      "利用者の取り消し（user_cancel）" => [ "user_cancel", %w[reserved awaiting_media confirming] ],
      "利用者の停止（user_stop）" => [ "user_stop", %w[live interrupted] ]
    }.each do |label, (event, expected_states)|
      it "#{label} で終了へ遷移する状態は、#{expected_states.join('・')} だけ" do
        ended_from = (states - [ "ended" ]).select { |state| BroadcastStateMachine.transition(state: state, event: event).next_state == "ended" }

        expect(ended_from).to match_array(expected_states)
      end
    end
  end

  describe "終了済みの配信に対する終了の事象は冪等（同じ結果）" do
    end_reasons.each do |reason|
      it "ended + #{reason} → ended（効果なし。終了処理を再び始めない）" do
        transition = BroadcastStateMachine.transition(state: "ended", event: reason)

        expect(transition).to eq(BroadcastStateMachine::Transition.new(next_state: "ended", effects: []))
      end
    end

    it "何度重ねても同じ" do
      first = BroadcastStateMachine.transition(state: "ended", event: "user_stop")
      second = BroadcastStateMachine.transition(state: first.next_state, event: "user_stop")

      expect(second).to eq(first)
    end

    progress_events.each do |event|
      it "ended + #{event}（進行の事象）も、状態を変えない" do
        expect(BroadcastStateMachine.transition(state: "ended", event: event)).to eq(
          BroadcastStateMachine::Transition.new(next_state: "ended", effects: [])
        )
      end
    end
  end

  describe "副作用の指示（effects）は値で返し、実行しない" do
    it "利用枠の消費（確定待ち → ライブ）は、引数の無い指示 consume_allowance" do
      transition = BroadcastStateMachine.transition(state: "confirming", event: "live_confirmed")

      expect(transition.effects).to eq([ Directive.of(:consume_allowance) ])
    end

    it "復帰（中断 → ライブ）の効果は、YouTube の状態確認 verify_youtube_status（復帰時の確認。10.3）" do
      transition = BroadcastStateMachine.transition(state: "interrupted", event: "resumed")

      expect(transition.effects).to eq([ Directive.of(:verify_youtube_status) ])
    end

    it "終了へ遷移するときの効果は、終了理由を引数に持つ terminate（終了処理 TerminationPlanner の起点）" do
      transition = BroadcastStateMachine.transition(state: "live", event: "time_limit")

      expect(transition.effects).to eq([ Directive.of(:terminate, reason: "time_limit") ])
    end

    it "効果は Directive の配列（種別とシンボルの引数だけの値）。凍結されている" do
      transition = BroadcastStateMachine.transition(state: "interrupted", event: "resumed")

      expect(transition).to be_frozen
      expect(transition.effects).to be_frozen
      expect(transition.effects).to all(be_a(Directive))
    end

    it "効果を持つ遷移は、利用枠の消費・復帰時の確認・終了処理の 3 種だけ（進行の遷移のうち効果を持つのは 2 本）" do
      kinds = defined.values.flat_map { |(_, effects)| effects.map(&:first) }.uniq

      expect(kinds).to match_array(%i[consume_allowance verify_youtube_status terminate])
    end
  end

  describe "純粋性（入力のみから出力が決まる。27 章の再現性）" do
    defined.each_key.first(5).each do |state, event|
      it "#{state} + #{event}: 同じ入力に、等しい出力を返す" do
        first = BroadcastStateMachine.transition(state: state, event: event)
        second = BroadcastStateMachine.transition(state: state, event: event)

        expect(second).to eq(first)
      end
    end

    it "状態・事象の文字列を変更しない（凍結されていない文字列を渡しても、そのまま）" do
      state = +"live"
      event = +"user_stop"

      BroadcastStateMachine.transition(state: state, event: event)

      expect([ state, event ]).to eq(%w[live user_stop])
    end

    it "Transition は next_state と effects だけを持つ" do
      expect(BroadcastStateMachine::Transition.members).to eq(%i[next_state effects])
    end

    it "インスタンスを作らない（状態を持たない）" do
      expect { BroadcastStateMachine.new }.to raise_error(NoMethodError)
    end
  end

  describe "契約に無い値は、黙って通さず ArgumentError（定義のない組とは区別する）" do
    {
      "未知の状態" => [ "unknown", "user_stop", /state must be a Contract::BroadcastState value/ ],
      "シンボルの状態" => [ :live, "user_stop", /state must be a Contract::BroadcastState value/ ],
      "nil の状態" => [ nil, "user_stop", /state must be a Contract::BroadcastState value/ ],
      "未知の事象" => [ "live", "unknown_event", /event must be a Contract::BroadcastEventType or Contract::EndReason value/ ],
      "シンボルの事象" => [ "live", :user_stop, /event must be a Contract::BroadcastEventType or Contract::EndReason value/ ],
      "nil の事象" => [ "live", nil, /event must be a Contract::BroadcastEventType or Contract::EndReason value/ ]
    }.each do |label, (state, event, message)|
      it "#{label}" do
        expect { BroadcastStateMachine.transition(state: state, event: event) }.to raise_error(ArgumentError, message)
      end
    end
  end
end
