require "spec_helper"
require "date"
require "time"
require_relative "support/domain_loader"
require_relative "support/time_helpers"
require_relative "support/admission_scenario"

# 開始受付判定（requirements.md 9 章・15 章「開始受付判定」。契約 http-rejections.json）。
# 時刻・設定値・現況は引数で受け取る。bot 判定（外部サービスの呼び出し）と現況は、遅延評価（呼び出すと値を返す関数）で受け取り、
# 順 0〜2 で拒否するときは、どちらも呼ばない。順 3 で拒否するときは、現況を呼ばない（現況の開示と外部呼び出しを、正当な要求に限る）。
#
# 基準の入力（AdmissionScenario）は、すべての判定を通る。拒否理由ごとに、その理由だけが該当するよう変える。
# 基準の時刻は、JST 2026-10-07 13:30（利用日 2026-10-07・暦月 2026-10）、太平洋時間 2026-10-06 21:30（割り当て日 2026-10-06）。
RSpec.describe "開始受付判定（StartAdmission.decide）" do
  extend DomainTimeHelpers
  include DomainTimeHelpers

  # 9.2 の判定順（順 0〜13）。契約の rejection_reason と同じ順（下の例で確かめる）
  reasons = %w[
    invalid_input not_logged_in rate_limited bot_check_failed broadcast_in_progress youtube_not_connected
    authorization_revoked live_not_enabled allowance_consumed attempts_exhausted intake_paused
    transfer_budget_exceeded capacity_full quota_insufficient
  ].freeze
  # 順 5・6・7 は、接続状態の 1 つの値で表すため、同時には成り立たない
  connection_group = %w[youtube_not_connected authorization_revoked live_not_enabled].freeze

  def scenario
    AdmissionScenario.new
  end

  # 順 index の理由で拒否したときの、呼び出し回数の期待値 [ bot 判定, 現況 ]
  def expected_calls(index)
    return [ 0, 0 ] if index <= 2
    return [ 1, 0 ] if index == 3

    [ 1, 1 ]
  end

  def calls_of(scenario)
    [ scenario.bot_provider.calls, scenario.snapshot_provider.calls ]
  end

  it "判定順（順 0〜13）は、契約の rejection_reason の順と同じで、契約の order と一致する" do
    expect(reasons).to eq(Contract::RejectionReason::ALL)
    reasons.each_with_index do |reason, index|
      expect(Contract::HttpRejections.fetch(reason).fetch("order")).to eq(index)
    end
  end

  describe "受理（すべての判定を通る）" do
    it "Admission::Accepted を返す。利用日・割り当て日・予約額（550）・適用される上限（時間上限・プロファイルの範囲）" do
      result = scenario.decide

      expect(result).to be_a(Admission::Accepted)
      expect(result).to be_accepted
      expect(result.usage_date).to eq(Date.new(2026, 10, 7))
      expect(result.quota_date).to eq(Date.new(2026, 10, 6))
      expect(result.reservation_units).to eq(550)
      expect(result.reservation_units).to eq(Contract::Limits::QUOTA.fetch("broadcast_reservation_units"))
      expect(result.limits.time_limit_seconds).to eq(3_600)
      expect(result.limits.profiles).to eq(Contract::Limits::PROFILES)
    end

    it "bot 判定と現況は、それぞれ 1 回だけ呼ぶ" do
      s = scenario
      s.decide

      expect(calls_of(s)).to eq([ 1, 1 ])
    end

    it "設定が、適用される上限に反映される（時間上限 30 分は 1,800 秒）" do
      s = scenario
      s.settings = Settings.from_raw("time_limit_minutes" => "30")

      expect(s.decide.limits.time_limit_seconds).to eq(1_800)
    end

    it "利用日と割り当て日は、時刻から算出される（基準: 利用日 10-07・割り当て日 10-06）。取り違えない" do
      result = scenario.decide

      expect(result.usage_date).not_to eq(result.quota_date)
    end

    it "出力は、タイトル・ユーザーの識別情報を含まない（項目は、利用日・割り当て日・予約額・上限だけ）" do
      s = scenario
      s.input = s.input.with(title: "SECRET-TITLE-0123456789")
      result = s.decide

      expect(Admission::Accepted.members).to eq(%i[usage_date quota_date reservation_units limits])
      expect(result.inspect).not_to include("SECRET")
      expect(result.to_h.to_s).not_to include("SECRET")
    end
  end

  describe "拒否理由 14 種（その理由だけが該当する入力で、その理由が返る）" do
    reasons.each_with_index do |reason, index|
      it "順 #{index}: #{reason}" do
        s = scenario.violate(reason)
        result = s.decide

        expect(result).to be_a(Admission::Rejected)
        expect(result).to be_rejected
        expect(result.reason).to eq(reason)
        expect(result.resolution).to eq(Contract::HttpRejections.fetch(reason).fetch("resolution"))
        expect(result.retry_at&.iso8601).to eq(AdmissionScenario::EXPECTED_RETRY_AT[reason])
        expect(result.fields).to eq(reason == "invalid_input" ? [ "title" ] : [])
        expect(calls_of(s)).to eq(expected_calls(index)), "bot 判定・現況の呼び出し回数が、順 #{index} の期待と違います"
      end
    end

    it "理由ごとの再試行の目安時刻（JST）: 頻度超過は呼び出し側が渡した時刻、利用枠消費済み・試行上限は次の JST 03:00、転送量は翌月 1 日 00:00 JST、API 割り当て不足は次の割り当て日の始まり。ほかは nil" do
      with_retry_at = AdmissionScenario::EXPECTED_RETRY_AT.keys

      expect(with_retry_at).to eq(%w[rate_limited allowance_consumed attempts_exhausted transfer_budget_exceeded quota_insufficient])
      (reasons - with_retry_at).each do |reason|
        expect(scenario.violate(reason).decide.retry_at).to be_nil
      end
    end

    it "再試行の目安時刻は、JST（+09:00）の Time" do
      with_retry_at = AdmissionScenario::EXPECTED_RETRY_AT.keys

      with_retry_at.each do |reason|
        retry_at = scenario.violate(reason).decide.retry_at

        expect(retry_at.utc_offset).to eq(32_400)
        expect(retry_at).to be > AdmissionScenario::NOW
      end
    end
  end

  describe "判定順（最初に該当した理由を返す。9.2）" do
    it "順 k 以降のすべてが該当するとき、順 k の理由が返る（k = 0〜13。順の入れ替わりを検知する）" do
      reasons.each_with_index do |reason, k|
        s = scenario
        # 順 5・6・7 は、接続状態の 1 つの値で表す。k がその中なら k の理由、k が手前なら順 5、k が後ろなら該当なし
        applicable = reasons.drop(k).reject { |candidate| connection_group.include?(candidate) }
        applicable << (connection_group.include?(reason) ? reason : "youtube_not_connected") if k <= 7
        applicable.each { |candidate| s.violate(candidate) }

        expect(s.decide.reason).to eq(reason), "順 #{k}（#{reason}）以降がすべて該当するのに、別の理由が返りました"
      end
    end

    pairs = reasons.each_index.to_a.combination(2).reject { |a, b| connection_group.include?(reasons[a]) && connection_group.include?(reasons[b]) }

    it "2 つの組み合わせ（14 の理由から 2 つ = 91 組。接続状態の 1 つの値で表す順 5・6・7 の 3 組は、同時に成り立たないので除く = 88 組）" do
      expect(reasons.size * (reasons.size - 1) / 2).to eq(91)
      expect(pairs.size).to eq(88)
    end

    pairs.each do |a, b|
      it "順 #{a}（#{reasons[a]}）と順 #{b}（#{reasons[b]}）が同時に該当するとき、順 #{a} が返る（適用の順に依らない）。呼び出し回数も順 #{a} のもの" do
        forward = scenario.violate(reasons[a]).violate(reasons[b])
        backward = scenario.violate(reasons[b]).violate(reasons[a])

        expect(forward.decide.reason).to eq(reasons[a])
        expect(backward.decide.reason).to eq(reasons[a])
        expect(calls_of(forward)).to eq(expected_calls(a))
        expect(calls_of(backward)).to eq(expected_calls(a))
      end
    end

    {
      "満員（順 12）より、利用枠消費済み（順 8）が先（再試行が無駄になる利用者へ、満員と案内しない）" => %w[allowance_consumed capacity_full],
      "満員（順 12）より、試行上限（順 9）が先" => %w[attempts_exhausted capacity_full],
      "API 割り当て不足（順 13）より、利用枠消費済み（順 8）が先" => %w[allowance_consumed quota_insufficient],
      "満員（順 12）より、受付停止（順 10）が先" => %w[intake_paused capacity_full],
      "満員（順 12）より、転送量の予算超過（順 11）が先" => %w[transfer_budget_exceeded capacity_full],
      "API 割り当て不足（順 13）より、満員（順 12）が先" => %w[capacity_full quota_insufficient],
      "進行中の配信あり（順 4）が、YouTube 未接続（順 5）より先" => %w[broadcast_in_progress youtube_not_connected],
      "進行中の配信あり（順 4）が、満員（順 12）より先" => %w[broadcast_in_progress capacity_full],
      "認可失効（順 6）が、利用枠消費済み（順 8）より先" => %w[authorization_revoked allowance_consumed],
      "ライブ未有効（順 7）が、利用枠消費済み（順 8）より先" => %w[live_not_enabled allowance_consumed],
      "利用枠消費済み（順 8）が、試行上限（順 9）より先" => %w[allowance_consumed attempts_exhausted],
      "頻度超過（順 2）が、bot 判定（順 3）より先（bot 判定を呼ばない）" => %w[rate_limited bot_check_failed],
      "未ログイン（順 1）が、頻度超過（順 2）より先" => %w[not_logged_in rate_limited],
      "入力不備（順 0）が、未ログイン（順 1）より先" => %w[invalid_input not_logged_in],
      "bot 判定（順 3）が、進行中の配信あり（順 4）より先（現況を呼ばない）" => %w[bot_check_failed broadcast_in_progress]
    }.each do |label, (earlier, later)|
      it label do
        s = scenario.violate(later).violate(earlier)

        expect(s.decide.reason).to eq(earlier)
      end
    end

    it "順 4〜13 の規則表は、契約の順 4〜13 と同じ並び" do
      expect(StartAdmission::StateRules::RULES.map(&:reason)).to eq(Contract::RejectionReason::ALL.drop(4))
    end
  end

  describe "遅延評価（bot 判定・現況）" do
    it "順 0（入力不備）で拒否するとき、bot 判定も現況も一度も呼ばない" do
      s = scenario.violate("invalid_input")
      s.decide

      expect(calls_of(s)).to eq([ 0, 0 ])
    end

    it "順 1（未ログイン）で拒否するとき、bot 判定も現況も一度も呼ばない" do
      s = scenario.violate("not_logged_in")
      s.decide

      expect(calls_of(s)).to eq([ 0, 0 ])
    end

    it "順 2（頻度超過）で拒否するとき、bot 判定も現況も一度も呼ばない（外部サービスの呼び出しを、正当な要求に限る）" do
      s = scenario.violate("rate_limited")
      s.decide

      expect(calls_of(s)).to eq([ 0, 0 ])
    end

    %i[fail indeterminate].each do |verdict|
      it "順 3（bot 判定が #{verdict}）で拒否するとき、bot 判定は 1 回、現況は一度も呼ばない（現況を開示しない）" do
        s = scenario
        s.bot_verdict = verdict
        result = s.decide

        expect(result.reason).to eq("bot_check_failed")
        expect(calls_of(s)).to eq([ 1, 0 ])
      end
    end

    it "順 4 以降で拒否するとき、bot 判定は 1 回、現況も 1 回だけ呼ぶ（2 回目を呼ばない）" do
      s = scenario.violate("capacity_full")
      s.decide

      expect(calls_of(s)).to eq([ 1, 1 ])
    end

    it "0〜2 のうち複数が該当しても、どちらも呼ばない（入力不備 + 未ログイン + 頻度超過）" do
      s = scenario.violate("rate_limited").violate("not_logged_in").violate("invalid_input")
      s.decide

      expect(calls_of(s)).to eq([ 0, 0 ])
    end

    it "bot 判定が :pass 以外（:fail・:indeterminate）は拒否する。判定不能は、受理側へ倒さない" do
      %i[fail indeterminate].each do |verdict|
        s = scenario
        s.bot_verdict = verdict

        expect(s.decide).to be_a(Admission::Rejected)
      end
      expect(scenario.decide).to be_a(Admission::Accepted)
    end

    it "bot 判定が :fail のとき、現況の理由（たとえば満員）ではなく、bot 判定を返す" do
      s = scenario.violate("capacity_full").violate("quota_insufficient")
      s.bot_verdict = :indeterminate

      expect(s.decide.reason).to eq("bot_check_failed")
    end

    it "bot 判定が想定外の値（nil・真偽値・文字列・未知のシンボル）のときは、拒否ではなく例外（現況は呼ばない）" do
      [ nil, true, false, "pass", :PASS, :ok, :passed, 1 ].each do |invalid|
        s = scenario
        s.bot_verdict = invalid

        expect { s.decide }.to raise_error(ArgumentError, /bot_verdict/)
        expect(calls_of(s)).to eq([ 1, 0 ])
      end
    end

    it "bot 判定の呼び出しが例外を投げたら、そのまま伝える（握りつぶさず、受理もしない）。現況は呼ばない" do
      s = scenario
      bot = CountingProvider.new { raise "verifier down" }
      snapshot = CountingProvider.new(s.snapshot)

      expect do
        StartAdmission.decide(input: s.input, session_valid: true, rate_limit: s.rate_limit, bot_verdict: bot, snapshot: snapshot,
                              settings: s.settings, now: s.now)
      end.to raise_error(RuntimeError, "verifier down")
      expect([ bot.calls, snapshot.calls ]).to eq([ 1, 0 ])
    end

    it "現況の呼び出しが例外を投げたら、そのまま伝える（握りつぶさない）" do
      s = scenario
      bot = CountingProvider.new(:pass)
      snapshot = CountingProvider.new { raise "database down" }

      expect do
        StartAdmission.decide(input: s.input, session_valid: true, rate_limit: s.rate_limit, bot_verdict: bot, snapshot: snapshot,
                              settings: s.settings, now: s.now)
      end.to raise_error(RuntimeError, "database down")
      expect([ bot.calls, snapshot.calls ]).to eq([ 1, 1 ])
    end

    it "現況が AccountSnapshot でないときは ArgumentError（Hash などを受け付けない）" do
      s = scenario
      snapshot = CountingProvider.new({ consumed_count: 0 })

      expect do
        StartAdmission.decide(input: s.input, session_valid: true, rate_limit: s.rate_limit, bot_verdict: -> { :pass }, snapshot: snapshot,
                              settings: s.settings, now: s.now)
      end.to raise_error(ArgumentError, /snapshot/)
    end
  end

  describe "各規則の境界値" do
    # [ 設定（文字列の Hash）, 現況の変更（quota: は台帳の変更）, 期待する理由（受理は nil） ]
    {
      "利用枠: 設定 1・追加 0・消費 0 は受理" => [ {}, { consumed_count: 0 }, nil ],
      "利用枠: 設定 1・追加 0・消費 1 は利用枠消費済み" => [ {}, { consumed_count: 1 }, "allowance_consumed" ],
      "利用枠: 設定 1・追加 1・消費 1 は受理（開発者の手動リセットによる追加）" => [ {}, { extra_grants: 1, consumed_count: 1 }, nil ],
      "利用枠: 設定 1・追加 1・消費 2 は利用枠消費済み" => [ {}, { extra_grants: 1, consumed_count: 2 }, "allowance_consumed" ],
      "利用枠: 設定 2・追加 0・消費 1 は受理" => [ { "daily_allowance" => "2" }, { consumed_count: 1 }, nil ],
      "利用枠: 設定 2・追加 0・消費 2 は利用枠消費済み" => [ { "daily_allowance" => "2" }, { consumed_count: 2 }, "allowance_consumed" ],
      "利用枠: 設定 1・消費 2（設定を下げた後など、消費が上回る）は利用枠消費済み（<= 0）" => [ {}, { consumed_count: 2 }, "allowance_consumed" ],
      "利用枠: 設定 0・追加 0・消費 0 は利用枠消費済み" => [ { "daily_allowance" => "0" }, {}, "allowance_consumed" ],
      "利用枠: 設定 0・追加 1・消費 0 は受理" => [ { "daily_allowance" => "0" }, { extra_grants: 1 }, nil ],
      "利用枠: 設定 3・追加 2・消費 4 は受理（3 + 2 - 4 = 1）" => [ { "daily_allowance" => "3" }, { extra_grants: 2, consumed_count: 4 }, nil ],
      "利用枠: 設定 3・追加 2・消費 5 は利用枠消費済み（3 + 2 - 5 = 0）" => [ { "daily_allowance" => "3" }, { extra_grants: 2, consumed_count: 5 }, "allowance_consumed" ],
      "開始試行: 上限 3・計上 0 は受理" => [ {}, { attempt_count: 0 }, nil ],
      "開始試行: 上限 3・計上 2 は受理" => [ {}, { attempt_count: 2 }, nil ],
      "開始試行: 上限 3・計上 3 は試行上限" => [ {}, { attempt_count: 3 }, "attempts_exhausted" ],
      "開始試行: 上限 3・計上 4 は試行上限" => [ {}, { attempt_count: 4 }, "attempts_exhausted" ],
      "開始試行: 上限 1・計上 0 は受理" => [ { "attempt_limit" => "1" }, { attempt_count: 0 }, nil ],
      "開始試行: 上限 1・計上 1 は試行上限" => [ { "attempt_limit" => "1" }, { attempt_count: 1 }, "attempts_exhausted" ],
      "開始試行: 上限 0・計上 0 は試行上限" => [ { "attempt_limit" => "0" }, { attempt_count: 0 }, "attempts_exhausted" ],
      "同時配信数: 上限 3・現在 2 は受理" => [ {}, { concurrent_count: 2 }, nil ],
      "同時配信数: 上限 3・現在 3 は満員" => [ {}, { concurrent_count: 3 }, "capacity_full" ],
      "同時配信数: 上限 3・現在 4 は満員" => [ {}, { concurrent_count: 4 }, "capacity_full" ],
      "同時配信数: 上限 1・現在 0 は受理" => [ { "concurrent_limit" => "1" }, { concurrent_count: 0 }, nil ],
      "同時配信数: 上限 1・現在 1 は満員" => [ { "concurrent_limit" => "1" }, { concurrent_count: 1 }, "capacity_full" ],
      "同時配信数: 上限 0・現在 0 は満員" => [ { "concurrent_limit" => "0" }, { concurrent_count: 0 }, "capacity_full" ],
      "転送量: 予算 10 GB・積算 0 は受理" => [ {}, { transfer_sent_bytes: 0 }, nil ],
      "転送量: 予算 10 GB・積算 9,999,999,999 バイトは受理" => [ {}, { transfer_sent_bytes: 9_999_999_999 }, nil ],
      "転送量: 予算 10 GB・積算 10,000,000,000 バイト（達した）は転送量の予算超過" => [ {}, { transfer_sent_bytes: 10_000_000_000 }, "transfer_budget_exceeded" ],
      "転送量: 予算 10 GB・積算 10,000,000,001 バイトは転送量の予算超過" => [ {}, { transfer_sent_bytes: 10_000_000_001 }, "transfer_budget_exceeded" ],
      "転送量: 予算 1 GB・積算 999,999,999 バイトは受理" => [ { "monthly_transfer_budget_gb" => "1" }, { transfer_sent_bytes: 999_999_999 }, nil ],
      "転送量: 予算 1 GB・積算 1,000,000,000 バイトは転送量の予算超過（1 GB = 10 億バイト）" => [ { "monthly_transfer_budget_gb" => "1" }, { transfer_sent_bytes: 1_000_000_000 }, "transfer_budget_exceeded" ],
      "転送量: 予算 0 GB は、積算 0 でも転送量の予算超過" => [ { "monthly_transfer_budget_gb" => "0" }, { transfer_sent_bytes: 0 }, "transfer_budget_exceeded" ],
      "受付停止: 無効は受理" => [ { "intake_paused" => "false" }, {}, nil ],
      "受付停止: 有効は受付停止" => [ { "intake_paused" => "true" }, {}, "intake_paused" ],
      "API 割り当て: 予約中 8,450（+550 = 9,000）は受理" => [ {}, { quota: { reserved_units: 8_450 } }, nil ],
      "API 割り当て: 予約中 8,451（+550 = 9,001）は API 割り当て不足" => [ {}, { quota: { reserved_units: 8_451 } }, "quota_insufficient" ],
      "API 割り当て: 使用済み 4,000 + 予約中 4,450（+550 = 9,000）は受理" => [ {}, { quota: { used_units: 4_000, reserved_units: 4_450 } }, nil ],
      "API 割り当て: 使用済み 4,001 + 予約中 4,450（+550 = 9,001）は API 割り当て不足" => [ {}, { quota: { used_units: 4_001, reserved_units: 4_450 } }, "quota_insufficient" ],
      "API 割り当て: 16 本目（予約中 8,250 + 550 = 8,800）は受理" => [ {}, { quota: { reserved_units: 8_250 } }, nil ],
      "API 割り当て: 17 本目（予約中 8,800 + 550 = 9,350）は API 割り当て不足" => [ {}, { quota: { reserved_units: 8_800 } }, "quota_insufficient" ],
      "API 割り当て: 共通枠の使用済み 500 は、判定に影響しない（受理）" => [ {}, { quota: { common_used_units: 500 } }, nil ],
      "API 割り当て: 1 日の割り当て 20,000 なら、予約中 18,450 は受理" => [ { "daily_quota_units" => "20000" }, { quota: { reserved_units: 18_450 } }, nil ],
      "API 割り当て: 1 日の割り当て 20,000 でも、予約中 18,451 は API 割り当て不足" => [ { "daily_quota_units" => "20000" }, { quota: { reserved_units: 18_451 } }, "quota_insufficient" ],
      "API 割り当て: 割り当て超過が返った日（exhausted）は、空きがあっても API 割り当て不足" => [ {}, { quota: { exhausted: true } }, "quota_insufficient" ],
      "API 割り当て: 1 日の割り当て 1,000（配信に使える上限 0）は API 割り当て不足" => [ { "daily_quota_units" => "1000" }, {}, "quota_insufficient" ],
      "API 割り当て: 1 日の割り当て 1,550（配信に使える上限 550）は受理" => [ { "daily_quota_units" => "1550" }, {}, nil ]
    }.each do |label, (raw_settings, snapshot_changes, expected)|
      it label do
        s = scenario
        s.settings = Settings.from_raw(raw_settings)
        quota_changes = snapshot_changes[:quota]
        s.amend(**snapshot_changes.except(:quota))
        s.amend_quota_day(**quota_changes) if quota_changes
        result = s.decide

        if expected
          expect(result).to be_a(Admission::Rejected)
          expect(result.reason).to eq(expected)
        else
          expect(result).to be_a(Admission::Accepted)
        end
      end
    end

    {
      "not_connected" => "youtube_not_connected",
      "revoked" => "authorization_revoked",
      "live_not_enabled" => "live_not_enabled",
      "connected" => nil
    }.each do |state, expected|
      it "YouTube の接続状態 #{state}: #{expected || '受理'}" do
        s = scenario
        s.amend(connection_state: state)
        result = s.decide

        expect(result.respond_to?(:reason) ? result.reason : nil).to eq(expected)
      end
    end

    it "進行中の配信が無ければ受理、あれば進行中の配信あり" do
      s = scenario
      s.amend(broadcast_in_progress: false)
      expect(s.decide).to be_a(Admission::Accepted)

      s.amend(broadcast_in_progress: true)
      expect(s.decide.reason).to eq("broadcast_in_progress")
    end
  end

  describe "入力の検証（順 0）と fields" do
    it "不備のある項目名を、すべて fields に返す（複数の不備は全項目）" do
      s = scenario
      s.input = StartAdmission::Input.new(title: "a" * 101, privacy_status: "friends", made_for_kids: nil)
      result = s.decide

      expect(result.reason).to eq("invalid_input")
      expect(result.fields).to eq(%w[title privacy_status made_for_kids])
      expect(result.resolution).to eq("fix_input")
      expect(result.retry_at).to be_nil
    end

    it "子ども向けの申告が未選択（nil）は、不備" do
      s = scenario
      s.input = s.input.with(made_for_kids: nil)

      expect(s.decide.fields).to eq([ "made_for_kids" ])
    end

    it "拒否の出力に、タイトルを含めない（入力不備でも、項目名だけ）" do
      s = scenario
      s.input = s.input.with(title: "<SECRET-TITLE-0123456789>")
      result = s.decide

      expect(result.inspect).not_to include("SECRET")
      expect(result.fields).to eq([ "title" ])
    end

    it "入力不備は、未ログインより先（9.2。順 0）。セッションが無効でも、不備の項目を返す" do
      s = scenario.violate("not_logged_in")
      s.input = s.input.with(title: " ")

      expect(s.decide.reason).to eq("invalid_input")
    end
  end

  describe "現況の日付の検査（古い現況で判定しない。利用日・割り当て日は、算出規則で成立する）" do
    it "現況の利用日が、判定の時刻の利用日と違うときは StaleSnapshot（前日の利用枠で判定しない）" do
      s = scenario
      s.amend(usage_date: Date.new(2026, 10, 6))

      expect { s.decide }.to raise_error(StartAdmission::StaleSnapshot, /usage_date/) { |error|
        expect(error).to be_a(ArgumentError)
        expect(error.message).to be_ascii_only
      }
    end

    it "現況の暦月が、判定の時刻の暦月と違うときは StaleSnapshot" do
      s = scenario
      s.amend(month_key: "2026-09")

      expect { s.decide }.to raise_error(StartAdmission::StaleSnapshot, /month_key/)
    end

    it "現況の台帳の割り当て日が、判定の時刻の割り当て日と違うときは StaleSnapshot（利用日と取り違えない）" do
      s = scenario
      s.amend_quota_day(quota_date: Date.new(2026, 10, 7))

      expect { s.decide }.to raise_error(StartAdmission::StaleSnapshot, /quota_date/)
    end

    it "現況の日付が正しければ、通る" do
      expect(scenario.decide).to be_a(Admission::Accepted)
    end

    it "現況の日付の検査は、現況を呼んだあと、規則を評価する前に行う（古い現況から、理由を作らない）" do
      s = scenario.violate("capacity_full")
      s.amend(usage_date: Date.new(2026, 10, 6))

      expect { s.decide }.to raise_error(StartAdmission::StaleSnapshot)
      expect(calls_of(s)).to eq([ 1, 1 ])
    end

    it "拒否で終わる順 0〜3 では、現況を呼ばないので、日付も検査しない" do
      s = scenario.violate("invalid_input")
      s.amend(usage_date: Date.new(2026, 10, 6))

      expect(s.decide.reason).to eq("invalid_input")
    end
  end

  describe "暦・時差との結合（日付の境界・夏時間）" do
    it "JST 02:59:59（利用日は前日）: 利用枠消費済みの再試行の目安は、1 秒後の JST 03:00" do
      s = scenario.violate("allowance_consumed")
      s.at(jst(2026, 10, 7, 2, 59, 59), usage_date: Date.new(2026, 10, 6), month_key: "2026-10", quota_date: Date.new(2026, 10, 6))
      result = s.decide

      expect(result.reason).to eq("allowance_consumed")
      expect(result.retry_at.iso8601).to eq("2026-10-07T03:00:00+09:00")
    end

    it "JST 03:00:00（利用日が切り替わる）: 現況の利用日は当日。再試行の目安は翌日の JST 03:00" do
      s = scenario.violate("attempts_exhausted")
      s.at(jst(2026, 10, 7, 3, 0, 0), usage_date: Date.new(2026, 10, 7), month_key: "2026-10", quota_date: Date.new(2026, 10, 6))
      result = s.decide

      expect(result.retry_at.iso8601).to eq("2026-10-08T03:00:00+09:00")
    end

    it "JST 03:00:00 の判定に、前の利用日の現況（利用日 10-06）を渡すと StaleSnapshot（03:00 のリセットが、算出規則で成立している）" do
      s = scenario.violate("allowance_consumed")
      s.at(jst(2026, 10, 7, 3, 0, 0), usage_date: Date.new(2026, 10, 6), month_key: "2026-10", quota_date: Date.new(2026, 10, 6))

      expect { s.decide }.to raise_error(StartAdmission::StaleSnapshot, /usage_date/)
    end

    it "月末の最後の 1 秒（JST 2026-10-31 23:59:59）: 転送量の再試行の目安は、1 秒後の翌月 1 日 00:00 JST" do
      s = scenario.violate("transfer_budget_exceeded")
      s.at(jst(2026, 10, 31, 23, 59, 59), usage_date: Date.new(2026, 10, 31), month_key: "2026-10", quota_date: Date.new(2026, 10, 31))
      result = s.decide

      expect(result.reason).to eq("transfer_budget_exceeded")
      expect(result.retry_at.iso8601).to eq("2026-11-01T00:00:00+09:00")
    end

    it "月初の JST 00:00:00（暦月は新しい月。利用日は前日のまま）: 転送量の再試行の目安は、翌々月 1 日" do
      s = scenario.violate("transfer_budget_exceeded")
      s.at(jst(2026, 11, 1, 0, 0, 0), usage_date: Date.new(2026, 10, 31), month_key: "2026-11", quota_date: Date.new(2026, 10, 31))
      result = s.decide

      expect(result.retry_at.iso8601).to eq("2026-12-01T00:00:00+09:00")
    end

    it "春の夏時間の切り替えの日（2026-03-08T12:00Z = PDT 05:00）: API 割り当て不足の再試行の目安は、03-09 00:00 PDT = JST 16:00（UTC-8 の固定なら 17:00 で誤る）" do
      s = scenario.violate("quota_insufficient")
      s.at(utc(2026, 3, 8, 12, 0, 0), usage_date: Date.new(2026, 3, 8), month_key: "2026-03", quota_date: Date.new(2026, 3, 8))
      result = s.decide

      expect(result.reason).to eq("quota_insufficient")
      expect(result.retry_at.iso8601).to eq("2026-03-09T16:00:00+09:00")
    end

    it "秋の夏時間の切り替えの日（2026-11-01T09:30Z = PST 01:30 の 2 回目）: 再試行の目安は、11-02 00:00 PST = JST 17:00（UTC-7 の固定なら 16:00 で誤る）" do
      s = scenario.violate("quota_insufficient")
      s.at(utc(2026, 11, 1, 9, 30, 0), usage_date: Date.new(2026, 11, 1), month_key: "2026-11", quota_date: Date.new(2026, 11, 1))
      result = s.decide

      expect(result.retry_at.iso8601).to eq("2026-11-02T17:00:00+09:00")
    end

    it "割り当て日の境界（2026-03-09T07:00:00Z = PDT 00:00）: 現況の割り当て日は 03-09。1 秒前（06:59:59Z）の現況は 03-08" do
      after = scenario.violate("quota_insufficient")
      after.at(utc(2026, 3, 9, 7, 0, 0), usage_date: Date.new(2026, 3, 9), month_key: "2026-03", quota_date: Date.new(2026, 3, 9))
      before = scenario.violate("quota_insufficient")
      before.at(utc(2026, 3, 9, 6, 59, 59), usage_date: Date.new(2026, 3, 9), month_key: "2026-03", quota_date: Date.new(2026, 3, 8))

      expect(after.decide.retry_at.iso8601).to eq("2026-03-10T16:00:00+09:00")
      expect(before.decide.retry_at.iso8601).to eq("2026-03-09T16:00:00+09:00")
    end

    it "頻度超過の再試行の目安は、呼び出し側が渡した時刻（UTC で渡しても JST で返る）" do
      s = scenario
      s.rate_limit = StartAdmission::RateLimit.exceeded_until(Time.utc(2026, 10, 7, 4, 59, 30))
      result = s.decide

      expect(result.reason).to eq("rate_limited")
      expect(result.retry_at.iso8601).to eq("2026-10-07T13:59:30+09:00")
    end
  end

  describe "引数の検査（呼び出し側の誤りは、拒否でも受理でもなく、例外にする。現況・bot 判定は呼ばない）" do
    def decide_with(**overrides)
      s = AdmissionScenario.new
      bot = CountingProvider.new(:pass)
      snapshot = CountingProvider.new(s.snapshot)
      arguments = {
        input: s.input, session_valid: true, rate_limit: s.rate_limit, bot_verdict: bot, snapshot: snapshot, settings: s.settings, now: s.now
      }.merge(overrides)
      result = begin
        StartAdmission.decide(**arguments)
      rescue ArgumentError => error
        error
      end
      [ result, arguments.fetch(:bot_verdict), arguments.fetch(:snapshot) ]
    end

    {
      input: [ nil, {}, { title: "a" }, "title", 1 ],
      session_valid: [ nil, "true", 1, 0, :true, [] ],
      rate_limit: [ nil, true, {}, { exceeded: true }, 3 ],
      bot_verdict: [ nil, :pass, "pass", true, 1 ],
      snapshot: [ nil, :snapshot, {}, 1 ],
      settings: [ nil, {}, "settings", 1 ],
      now: [ nil, "2026-10-07 13:30:00", Date.new(2026, 10, 7), 1_791_000_000, 1.5 ]
    }.each do |argument, invalid_values|
      invalid_values.each do |invalid|
        it "#{argument}: #{invalid.inspect} は ArgumentError。bot 判定・現況を呼ばない" do
          result, bot, snapshot = decide_with(argument => invalid)

          expect(result).to be_a(ArgumentError)
          expect(result.message).to include(argument.to_s)
          expect([ bot, snapshot ].grep(CountingProvider).sum(&:calls)).to eq(0)
        end
      end
    end

    it "キーワード引数の不足は ArgumentError（既定値で補わない）" do
      s = scenario

      expect { StartAdmission.decide(input: s.input, session_valid: true) }.to raise_error(ArgumentError)
      expect { StartAdmission.decide }.to raise_error(ArgumentError)
    end
  end

  describe "純粋さ（同じ入力に同じ出力。27 章の再現性）" do
    it "Time.now・Date.today が失敗する状態でも、受理・拒否の両方が動く" do
      allow(Time).to receive(:now).and_raise("Time.now must not be called")
      allow(Date).to receive(:today).and_raise("Date.today must not be called")

      expect(scenario.decide).to be_a(Admission::Accepted)
      expect(scenario.violate("quota_insufficient").decide).to be_a(Admission::Rejected)
      expect(scenario.violate("allowance_consumed").decide.retry_at).not_to be_nil
    end

    it "同じ入力に、何度呼んでも同じ出力を返す（受理・拒否）" do
      accepted = scenario
      rejected = scenario.violate("transfer_budget_exceeded")

      expect(accepted.decide).to eq(accepted.decide)
      expect(rejected.decide).to eq(rejected.decide)
    end

    it "引数を変更しない。凍結した引数も受け付ける" do
      s = scenario
      s.now = s.now.dup.freeze
      s.input = s.input.with(title: "ライブ配信".dup.freeze)
      before = [ s.input, s.snapshot, s.settings, s.rate_limit ].map(&:to_h)

      s.decide

      expect([ s.input, s.snapshot, s.settings, s.rate_limit ].map(&:to_h)).to eq(before)
    end

    it "受理・拒否の結果は凍結されている" do
      expect(scenario.decide).to be_frozen
      expect(scenario.violate("capacity_full").decide).to be_frozen
    end

    it "複数のスレッドが同時に呼んでも、結果が混ざらない（共有の状態を持たない）" do
      targets = %w[capacity_full quota_insufficient transfer_budget_exceeded intake_paused allowance_consumed attempts_exhausted broadcast_in_progress rate_limited]
      results = targets.map { |reason| Thread.new { [ reason, scenario.violate(reason).decide.reason ] } }.map(&:value)

      results.each { |expected, actual| expect(actual).to eq(expected) }
    end
  end

  describe "StartAdmission::RateLimit（頻度制限の判定結果。呼び出し側が数える）" do
    it "within_limit は、超過なし・目安時刻なし" do
      limit = StartAdmission::RateLimit.within_limit

      expect(limit).not_to be_exceeded
      expect(limit.retry_at).to be_nil
      expect(limit).to be_frozen
    end

    it "exceeded_until は、超過あり・枠が空く時刻つき" do
      time = Time.utc(2026, 10, 7, 4, 45, 0)
      limit = StartAdmission::RateLimit.exceeded_until(time)

      expect(limit).to be_exceeded
      expect(limit.retry_at).to eq(time)
    end

    it "超過ありで時刻なし・超過なしで時刻あり・型違いは ArgumentError（矛盾した状態を作れない）" do
      time = Time.utc(2026, 10, 7, 4, 45, 0)

      expect { StartAdmission::RateLimit.new(exceeded: true, retry_at: nil) }.to raise_error(ArgumentError, /retry_at/)
      expect { StartAdmission::RateLimit.new(exceeded: false, retry_at: time) }.to raise_error(ArgumentError, /retry_at/)
      [ nil, "true", 1, :yes ].each do |invalid|
        expect { StartAdmission::RateLimit.new(exceeded: invalid, retry_at: nil) }.to raise_error(ArgumentError, /exceeded/)
      end
      expect { StartAdmission::RateLimit.exceeded_until("2026-10-07T13:45:00+09:00") }.to raise_error(ArgumentError, /retry_at/)
      expect { StartAdmission::RateLimit.exceeded_until(nil) }.to raise_error(ArgumentError, /retry_at/)
    end
  end

  describe "再試行の目安時刻の規則（契約の retry_at_rule）" do
    it "契約のすべての retry_at_rule に対応する（契約に規則が増えたら、ここで検知する）" do
      expect(StartAdmission::RetryAt::RULES.keys.sort).to eq(Contract::HttpRejections::RETRY_AT_RULES.sort)
    end

    it "拒否理由ごとの規則は、契約の http-rejections.json のとおり（理由 => 規則）" do
      expected = {
        "rate_limited" => "rate_limit_window",
        "allowance_consumed" => "next_usage_day_start",
        "attempts_exhausted" => "next_usage_day_start",
        "transfer_budget_exceeded" => "next_month_start",
        "quota_insufficient" => "next_quota_day_start"
      }
      reasons.each do |reason|
        expect(Contract::HttpRejections.fetch(reason).fetch("retry_at_rule")).to eq(expected.fetch(reason, "none"))
      end
    end
  end
end
