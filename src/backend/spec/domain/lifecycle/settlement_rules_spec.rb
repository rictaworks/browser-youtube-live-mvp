require "spec_helper"
require_relative "../support/domain_loader"

# 清算（requirements.md 15 章「清算」・10.4・10.5・25.2・8.4）。SettlementRules。
#   plan(youtube_status:)                         YouTube 側の状態から、清算の指示を決める
#   apply_result(settlement_state:, attempts:, result:)   清算の呼び出しの結果を、清算状態へ反映する
# 清算の試行は、終了処理に続く最初の試行（再試行ではない。attempts が 0）と、1・2・4 分間隔の最大 3 回の再試行。
RSpec.describe "清算（SettlementRules）" do
  describe "YouTube の lifeCycleStatus（SettlementRules::LifeCycleStatus）" do
    it "公式の 8 値（API の綴り）を持つ" do
      expect(SettlementRules::LifeCycleStatus::ALL).to eq(
        %w[complete created live liveStarting ready revoked testStarting testing]
      )
      expect(SettlementRules::LifeCycleStatus::ALL).to be_frozen
    end
  end

  describe ".plan（YouTube 側の状態 → 清算の指示）" do
    # 8 値と「存在しない」。10.4 の表（ライブ・未開始・終端）と、事前確認で判明した遷移中の 2 値
    {
      "live" => [ :transition_to_complete, "ライブ → 完了へ遷移させる" ],
      "testing" => [ :transition_to_complete, "テスト中（モニターストリームを無効にしているので、通常は存在しない）→ 完了へ遷移させる" ],
      "created" => [ :delete_broadcast, "未開始（作成済み）→ 配信を削除する" ],
      "ready" => [ :delete_broadcast, "未開始（準備完了）→ 配信を削除する" ],
      "liveStarting" => [ :delete_broadcast, "ライブへの遷移中で止まった配信 → 削除する（10.4 の表に行が無い。YouTube の公式の案内。疑義）" ],
      "testStarting" => [ :delete_broadcast, "テストへの遷移中で止まった配信 → 削除する（同上）" ],
      "complete" => [ :mark_settled, "完了（終端）→ 何もしない（清算済み）" ],
      "revoked" => [ :mark_settled, "取り消し（終端）→ 何もしない（清算済み）" ]
    }.each do |status, (kind, label)|
      it "#{status}: #{label}" do
        expect(SettlementRules.plan(youtube_status: status)).to eq(Directive.of(kind))
      end
    end

    it "存在しない（SettlementRules::NOT_FOUND）→ 何もしない（清算済み）" do
      expect(SettlementRules::NOT_FOUND).to eq(:not_found)
      expect(SettlementRules.plan(youtube_status: SettlementRules::NOT_FOUND)).to eq(Directive.of(:mark_settled))
    end

    it "8 値すべてに指示がある（網羅）。呼び出しを要するのは、完了への遷移 2 値・削除 4 値" do
      kinds = SettlementRules::LifeCycleStatus::ALL.to_h { |status| [ status, SettlementRules.plan(youtube_status: status).kind ] }

      expect(kinds.values.tally).to eq(transition_to_complete: 2, delete_broadcast: 4, mark_settled: 2)
    end

    {
      "未知の値" => "unknownStatus",
      "大文字・小文字の違い" => "Live",
      "空文字列" => "",
      "nil（状態が得られなかった。存在しないとは区別する）" => nil,
      "シンボル（NOT_FOUND 以外）" => :live
    }.each do |label, value|
      it "#{label} は、黙って清算済みにせず、UnknownLifeCycleStatus（ArgumentError）" do
        expect { SettlementRules.plan(youtube_status: value) }
          .to raise_error(SettlementRules::UnknownLifeCycleStatus, /unknown YouTube lifeCycleStatus: #{Regexp.escape(value.inspect)}/)
        expect(SettlementRules::UnknownLifeCycleStatus.ancestors).to include(ArgumentError)
      end
    end

    it "指示は凍結された値。同じ入力に同じ出力" do
      first = SettlementRules.plan(youtube_status: "live")

      expect(first).to be_frozen
      expect(SettlementRules.plan(youtube_status: "live")).to eq(first)
    end
  end

  describe ".apply_result（結果を清算状態へ反映する）" do
    release = [ :release_reservation, {} ]
    discard = [ :discard_stream_id, {} ]
    success_results = %i[success not_found already_terminal]
    failure_results = %i[not_transitionable forbidden failed]

    def outcome(settlement_state, attempts, result)
      SettlementRules.apply_result(settlement_state: settlement_state, attempts: attempts, result: result)
    end

    def expect_outcome(actual, state:, attempts:, delay:, directives:)
      expect(actual.settlement_state).to eq(state)
      expect(actual.attempts).to eq(attempts)
      expect(actual.retry_delay_seconds).to eq(delay)
      expect(actual.directives).to eq(directives.map { |kind, args| Directive.new(kind: kind, args: args) })
    end

    describe "未清算（pending）で、成功・「存在しない」・「すでに終端」" do
      success_results.each do |result|
        (0..3).each do |attempts|
          it "#{result}（#{attempts} 回目の試行）→ 清算済み・予約の解放" do
            expect_outcome(outcome("pending", attempts, result), state: "settled", attempts: attempts + 1, delay: nil, directives: [ release ])
          end
        end
      end
    end

    describe "未清算（pending）で、失敗（現在の状態から要求の状態へ遷移・削除できない・権限・一時的な失敗）" do
      # 試行の回数 → [次の状態, 反映後の試行回数, 次の再試行までの秒数, 指示]
      {
        0 => [ "pending", 1, 60, [] ],
        1 => [ "pending", 2, 120, [] ],
        2 => [ "pending", 3, 240, [] ],
        3 => [ "abandoned", 4, nil, [ release, discard ] ]
      }.each do |attempts, (state, next_attempts, delay, directives)|
        failure_results.each do |result|
          it "#{result}（#{attempts} 回目の試行）→ #{state}#{delay ? "・#{delay} 秒後に再試行" : "・予約の解放とストリームの識別子の破棄"}" do
            expect_outcome(outcome("pending", attempts, result), state: state, attempts: next_attempts, delay: delay, directives: directives)
          end
        end
      end

      it "最初の試行（終了処理に続く清算。0 回目）の失敗では、1 分後に再試行。再試行は 1・2・4 分間隔の最大 3 回（4 回目の試行の失敗で、清算不能）" do
        delays = (0..2).map { |attempts| outcome("pending", attempts, :failed).retry_delay_seconds }

        expect(delays).to eq([ 60, 120, 240 ])
        expect(delays).to eq(Contract::Limits::DEADLINES.fetch("settlement_retry_delays_seconds"))
        expect(outcome("pending", 3, :failed).settlement_state).to eq("abandoned")
      end

      it "遷移・削除できない（invalidTransition など。終端ではない）は、清算済みにしない。未清算のまま再試行する" do
        expect(outcome("pending", 0, :not_transitionable).settlement_state).to eq("pending")
      end
    end

    describe "清算不能（abandoned）からの再清算（次回の準備時。10.5）" do
      success_results.each do |result|
        it "#{result} → 清算済み（予約の解放・ストリームの破棄は、清算不能になった時点で済んでいるので、指示なし）" do
          expect_outcome(outcome("abandoned", 4, result), state: "settled", attempts: 5, delay: nil, directives: [])
        end
      end

      failure_results.each do |result|
        it "#{result} → 清算不能のまま（再試行の予定を作らない。準備を妨げない）" do
          expect_outcome(outcome("abandoned", 4, result), state: "abandoned", attempts: 5, delay: nil, directives: [])
        end
      end

      it "権限の範囲外（forbidden）は、清算不能のまま残す。認可失効として扱わない（指示に、接続状態の変更を含まない）" do
        result = outcome("abandoned", 4, :forbidden)

        expect(result.settlement_state).to eq("abandoned")
        expect(result.directives).to eq([])
      end
    end

    describe "終端（不要・清算済み）は、どの結果でも変わらない（冪等）" do
      %w[none settled].each do |state|
        (success_results + failure_results).each do |result|
          it "#{state} + #{result} → #{state}（試行回数も変えない・指示なし）" do
            expect_outcome(outcome(state, 2, result), state: state, attempts: 2, delay: nil, directives: [])
          end
        end
      end
    end

    describe "ストリームの取り替えとの関係" do
      it "清算不能になるときの、ストリームの識別子の破棄の指示は、StreamReplacementPolicy の判断に従う（10.5 の表の「清算不能になった時点」）" do
        allow(StreamReplacementPolicy).to receive(:discard?).and_call_original
        outcome("pending", 3, :failed)

        expect(StreamReplacementPolicy).to have_received(:discard?).with(trigger: StreamReplacementPolicy::SETTLEMENT_ABANDONED)
      end

      it "StreamReplacementPolicy が破棄しないと判断すれば、破棄の指示を含めない（判断を、この規則で重複して持たない）" do
        allow(StreamReplacementPolicy).to receive(:discard?).and_return(false)

        expect(outcome("pending", 3, :failed).directives).to eq([ Directive.of(:release_reservation) ])
      end
    end

    describe "検査" do
      it "契約に無い清算状態は ArgumentError" do
        expect { outcome("unknown", 0, :success) }.to raise_error(ArgumentError, /settlement_state must be a Contract::SettlementState value/)
        expect { outcome(:pending, 0, :success) }.to raise_error(ArgumentError, /settlement_state must be a Contract::SettlementState value/)
      end

      it "結果が表に無い値（文字列・未知のシンボル・nil）は ArgumentError" do
        [ "success", :unknown, nil ].each do |result|
          expect { outcome("pending", 0, result) }.to raise_error(ArgumentError, /result must be one of/)
        end
      end

      it "試行の回数が整数でない・負なら ArgumentError" do
        expect { outcome("pending", -1, :failed) }.to raise_error(ArgumentError, /attempts must be >= 0/)
        expect { outcome("pending", 1.5, :failed) }.to raise_error(ArgumentError, /attempts must be an Integer/)
        expect { outcome("pending", nil, :failed) }.to raise_error(ArgumentError, /attempts must be an Integer/)
      end

      it "未清算で、試行の回数が再試行の上限を超えていれば（あり得ない状態）、ArgumentError" do
        expect { outcome("pending", 4, :failed) }.to raise_error(ArgumentError, /attempts must be <= 3 in state pending, got 4/)
      end
    end

    it "結果は、凍結された値（Outcome）。同じ入力に同じ出力" do
      first = outcome("pending", 3, :failed)

      expect(first).to be_frozen
      expect(first.directives).to be_frozen
      expect(outcome("pending", 3, :failed)).to eq(first)
      expect(SettlementRules::Outcome.members).to eq(%i[settlement_state attempts retry_delay_seconds directives])
    end
  end

  describe ".result_for_error（YouTube のエラーの reason → 結果）" do
    {
      "redundantTransition" => [ :already_terminal, "すでに要求の状態（完了済み）。清算済みとして扱う" ],
      "invalidTransition" => [ :not_transitionable, "現在の状態から要求の状態へ遷移できない。終端ではない" ],
      "liveBroadcastDeletionNotAllowed" => [ :not_transitionable, "現在の状態では削除できない。終端ではない" ],
      "errorStreamInactive" => [ :not_transitionable, "ストリームが有効でないため遷移できない。終端ではない" ],
      "liveBroadcastNotFound" => [ :not_found, "配信が存在しない。清算済みとして扱う" ],
      "liveStreamNotFound" => [ :not_found, "ストリームが存在しない" ],
      "insufficientPermissions" => [ :forbidden, "権限の範囲外" ],
      "insufficientLivePermissions" => [ :forbidden, "ライブ配信の権限が不足している" ],
      "forbidden" => [ :forbidden, "権限の範囲外" ],
      "quotaExceeded" => [ :failed, "割り当て超過。一時的な失敗として、未清算のまま再試行する" ],
      "rateLimitExceeded" => [ :failed, "要求が多すぎる" ],
      "backendError" => [ :failed, "一時的な失敗" ],
      "someUnknownReason" => [ :failed, "未知の reason は、一時的な失敗として、未清算のまま再試行する（清算済みにしない）" ]
    }.each do |reason, (expected, label)|
      it "#{reason} → #{expected}（#{label}）" do
        expect(SettlementRules.result_for_error(reason: reason)).to eq(expected)
      end
    end

    it "すでに終端（redundantTransition）と、遷移できない（invalidTransition）は、別の結果（前者だけが清算済み）" do
      already = SettlementRules.result_for_error(reason: "redundantTransition")
      invalid = SettlementRules.result_for_error(reason: "invalidTransition")

      expect(already).not_to eq(invalid)
      expect(SettlementRules.apply_result(settlement_state: "pending", attempts: 0, result: already).settlement_state).to eq("settled")
      expect(SettlementRules.apply_result(settlement_state: "pending", attempts: 0, result: invalid).settlement_state).to eq("pending")
    end

    [ nil, :quotaExceeded, 403 ].each do |reason|
      it "reason が文字列でなければ（#{reason.inspect}）、ArgumentError" do
        expect { SettlementRules.result_for_error(reason: reason) }.to raise_error(ArgumentError, "reason must be a String, got #{reason.class}")
      end
    end

    it "返す結果は、apply_result が受け付ける 6 種のどれか" do
      reasons = %w[redundantTransition invalidTransition liveBroadcastNotFound insufficientPermissions quotaExceeded]

      reasons.each do |reason|
        expect(SettlementRules::RESULTS).to include(SettlementRules.result_for_error(reason: reason))
      end
      expect(SettlementRules::RESULTS).to match_array(%i[success not_found already_terminal not_transitionable forbidden failed])
    end
  end

  describe ".retry_delay_seconds（再試行までの間隔）" do
    {
      0 => 60,
      1 => 60,
      2 => 120,
      3 => 240
    }.each do |attempts_made, seconds|
      it "試行を #{attempts_made} 回行った清算は、次の試行まで #{seconds} 秒" do
        expect(SettlementRules.retry_delay_seconds(attempts_made: attempts_made)).to eq(seconds)
      end
    end

    it "試行を行った回数が、再試行の上限（3 回）を超えていれば ArgumentError（そのあと再試行は無い）" do
      expect { SettlementRules.retry_delay_seconds(attempts_made: 4) }.to raise_error(ArgumentError, /attempts_made must be <= 3, got 4/)
      expect { SettlementRules.retry_delay_seconds(attempts_made: -1) }.to raise_error(ArgumentError, /attempts_made must be >= 0/)
      expect { SettlementRules.retry_delay_seconds(attempts_made: "1") }.to raise_error(ArgumentError, /attempts_made must be an Integer/)
    end
  end

  describe ".terminal?（終端か。予約の残額を解放できるか）" do
    {
      "none" => true,
      "pending" => false,
      "settled" => true,
      "abandoned" => true
    }.each do |state, expected|
      it "#{state} → #{expected}（25.2）" do
        expect(SettlementRules.terminal?(state)).to eq(expected)
      end
    end

    it "契約に無い値は ArgumentError" do
      expect { SettlementRules.terminal?("unknown") }.to raise_error(ArgumentError, /settlement_state must be a Contract::SettlementState value/)
    end
  end

  describe "清算の支出（8.4）" do
    it "清算の支出は、終了・清算枠（#5 の QuotaPolicy の予約の枠 :settle）だけ" do
      expect(SettlementRules::BUCKET).to eq(:settle)
    end

    it "1 回の試行は 51 ユニット（状態確認 1 + 清算 50）。契約の単価（一覧取得 1・遷移と削除は各 50）から算出する" do
      unit_costs = Contract::Limits::QUOTA.fetch("unit_costs")

      expect(SettlementRules::STATUS_CHECK_UNITS).to eq(unit_costs.fetch("list"))
      expect(SettlementRules::SETTLE_CALL_UNITS).to eq([ unit_costs.fetch("transition"), unit_costs.fetch("delete") ].max)
      expect(SettlementRules::ATTEMPT_COST_UNITS).to eq(51)
    end

    it "最初の試行 1 回と、再試行の上限 3 回を合わせて 204 ユニット。終了・清算枠 210 ユニットに収まる" do
      expect(SettlementRules::MAX_RETRIES).to eq(3)
      expect((1 + SettlementRules::MAX_RETRIES) * SettlementRules::ATTEMPT_COST_UNITS).to eq(204)
      expect((1 + SettlementRules::MAX_RETRIES) * SettlementRules::ATTEMPT_COST_UNITS)
        .to be <= Contract::Limits::QUOTA.fetch("settle_reservation_units")
    end
  end

  it "インスタンスを作らない（状態を持たない）" do
    expect { SettlementRules.new }.to raise_error(NoMethodError)
  end
end
