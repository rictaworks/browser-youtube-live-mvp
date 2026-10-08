require "rails_helper"
require "support/model_support"
require "services/support/ledger_support"

# 再確認の門 RecheckGate（issue #11。requirements.md 7.2・8.4・28.1。src/contracts/http-api.md 2.3 の can_recheck_at）。
#   next_allowed_at(user)  次に再確認できる時刻。今すぐできるなら nil。次の 2 つのうち、遅い方
#     1. 頻度制限: アカウント単位で 1 分に 1 回・1 日（直近 24 時間）20 回。再確認を消費せずに求める（RateLimiter#peek）
#     2. 共通枠: 共通枠が尽きた割り当て日は、その割り当て日の終わり（次の太平洋時間の 0 時）まで、再確認・接続時の確認を受け付けない（8.4）
# 割り当て日は、固定の時差ではなく、太平洋時間のタイムゾーン定義（夏時間を含む）で算出する（UsageCalendar）。時計は注入する。
RSpec.describe RecheckGate do
  include LedgerSupport

  let(:now) { noon_of(quota_day(0)) } # 太平洋時間の 2026-10-07 正午
  let(:clock_state) { { now: now } }
  let(:clock) { -> { clock_state[:now] } }
  let(:limiter) { RateLimiter.new(clock: clock) }
  let(:gate) { described_class.new(limiter: limiter, clock: clock) }
  let(:user) { create(:user) }

  def advance(seconds)
    clock_state[:now] += seconds
  end

  def record_recheck(for_user = user)
    expect(limiter.check(RateLimitPolicy.recheck, for_user.id)).to be_allowed
  end

  # 再確認 1 回に要する共通枠のユニット（チャンネルの一覧取得 + 配信の一覧取得）
  def probe_units
    YouTubeGateway::Calls.fetch(:probe_channel_lookup).units + YouTubeGateway::Calls.fetch(:probe_live_enabled).units
  end

  describe "#next_allowed_at（頻度制限）" do
    it "再確認の記録が無く、共通枠にも余裕があれば、今すぐできる（nil）" do
      expect(gate.next_allowed_at(user)).to be_nil
    end

    it "再確認の直後は、1 分後（再確認の時刻 + 60 秒）。JST（+09:00）の時刻で返す" do
      record_recheck

      result = gate.next_allowed_at(user)

      expect(result).to eq(now + 60)
      expect(result.utc_offset).to eq(9 * 3600)
    end

    it "1 分が過ぎれば、また今すぐできる（60 秒ちょうどで nil。59 秒後はまだ）" do
      record_recheck

      advance(59)
      expect(gate.next_allowed_at(user)).to eq(now + 60)

      advance(1)
      expect(gate.next_allowed_at(user)).to be_nil
    end

    it "1 日（直近 24 時間）に 20 回に達すると、最も古い記録から 24 時間後（1 分の規則より遅い時刻）" do
      20.times do
        record_recheck
        advance(61)
      end

      expect(gate.next_allowed_at(user)).to eq(now + 86_400)
    end

    it "20 回に達していなければ、1 分ごとに今すぐできる（19 回目まで）" do
      19.times do
        record_recheck
        advance(61)
      end

      expect(gate.next_allowed_at(user)).to be_nil
    end

    it "求めても、再確認を消費しない（何度求めても同じ。続けて check が許可される）" do
      first = gate.next_allowed_at(user)
      10.times { gate.next_allowed_at(user) }

      expect(first).to be_nil
      expect(limiter.check(RateLimitPolicy.recheck, user.id)).to be_allowed
      expect(limiter.check(RateLimitPolicy.recheck, user.id)).not_to be_allowed
    end

    it "アカウントごとに独立（別のアカウントの再確認は、影響しない）" do
      other = create(:user)
      record_recheck(other)

      expect(gate.next_allowed_at(user)).to be_nil
      expect(gate.next_allowed_at(other)).to eq(now + 60)
    end
  end

  describe "#next_allowed_at（共通枠。日付またぎ）" do
    it "共通枠が尽きた割り当て日は、その割り当て日の終わり（次の太平洋時間の 0 時）まで。JST で返す" do
      seed_day(quota_day(0), common: QuotaPolicy::COMMON_UNITS)

      result = gate.next_allowed_at(user)

      expect(result).to eq(UsageCalendar.next_quota_date_start(now))
      expect(result).to eq(Time.utc(2026, 10, 8, 7, 0, 0)) # 太平洋夏時間（UTC-7）の 10/8 0 時
      expect(result.utc_offset).to eq(9 * 3600)
    end

    it "再確認の頻度制限が無くても、共通枠が尽きていれば待たされる（アカウントによらない）" do
      seed_day(quota_day(0), common: QuotaPolicy::COMMON_UNITS)

      expect(gate.next_allowed_at(user)).not_to be_nil
      expect(gate.next_allowed_at(create(:user))).not_to be_nil
    end

    it "再確認 1 回の分（2 ユニット）が残っていなければ、尽きたとみなす（途中の 1 呼び出しで止まって、枠を使い切らない）" do
      expect(probe_units).to eq(2)
      seed_day(quota_day(0), common: QuotaPolicy::COMMON_UNITS - 1)

      expect(gate.next_allowed_at(user)).to eq(UsageCalendar.next_quota_date_start(now))
    end

    it "再確認 1 回の分（2 ユニット）が残っていれば、今すぐできる" do
      seed_day(quota_day(0), common: QuotaPolicy::COMMON_UNITS - probe_units)

      expect(gate.next_allowed_at(user)).to be_nil
    end

    it "割り当て日をまたげば、新しい割り当て日の共通枠で数える（前日に尽きていても、日付がかわれば今すぐできる）" do
      seed_day(quota_day(0), common: QuotaPolicy::COMMON_UNITS)
      clock_state[:now] = UsageCalendar.next_quota_date_start(now) # 太平洋時間の 10/8 0 時ちょうど

      expect(UsageCalendar.quota_date(clock_state[:now])).to eq(quota_day(1))
      expect(gate.next_allowed_at(user)).to be_nil
    end

    it "割り当て日の終わりの 1 秒前は、まだ待たされる" do
      seed_day(quota_day(0), common: QuotaPolicy::COMMON_UNITS)
      clock_state[:now] = UsageCalendar.next_quota_date_start(now) - 1

      expect(gate.next_allowed_at(user)).to eq(UsageCalendar.next_quota_date_start(clock_state[:now]))
    end

    it "頻度制限の時刻と共通枠の時刻の遅い方（共通枠が尽きた日に、再確認の記録がある）" do
      seed_day(quota_day(0), common: QuotaPolicy::COMMON_UNITS)
      record_recheck

      expect(gate.next_allowed_at(user)).to eq(UsageCalendar.next_quota_date_start(now))
    end

    it "頻度制限の方が遅ければ、頻度制限の時刻（1 日の上限 20 回。共通枠が尽きる日の終わりより遅い）" do
      # 太平洋時間の 10/7 23:00（割り当て日の終わりの 1 時間前）に 20 回
      clock_state[:now] = Time.utc(2026, 10, 8, 6, 0, 0)
      seed_day(quota_day(0), common: QuotaPolicy::COMMON_UNITS)
      first_at = clock_state[:now]
      20.times do
        record_recheck
        advance(61)
      end

      result = gate.next_allowed_at(user)

      expect(result).to eq(first_at + 86_400)
      expect(result).to be > UsageCalendar.next_quota_date_start(first_at)
    end

    it "夏時間の切り替えをまたぐ割り当て日でも、タイムゾーン定義で求める（固定の時差で計算しない）" do
      # 2026-11-01 は太平洋時間の夏時間の終了日。その日は 25 時間ある
      clock_state[:now] = Time.utc(2026, 11, 1, 12, 0, 0) # 太平洋標準時（UTC-8）の 11/1 04:00
      seed_day(Date.new(2026, 11, 1), common: QuotaPolicy::COMMON_UNITS)

      expect(gate.next_allowed_at(user)).to eq(Time.utc(2026, 11, 2, 8, 0, 0)) # 太平洋標準時の 11/2 0 時 = UTC 08:00
    end

    it "台帳を読むだけで、行を作らない・変えない" do
      expect { gate.next_allowed_at(user) }.not_to change { [ QuotaDay.count, QuotaEntry.count ] }
    end
  end

  describe "構築・引数" do
    it "アカウント（User）も、識別子（UUID の文字列）も渡せる" do
      record_recheck

      expect(gate.next_allowed_at(user.id)).to eq(now + 60)
      expect(gate.next_allowed_at(user)).to eq(now + 60)
    end

    it "アカウントを特定できない値は ArgumentError（nil・空・UUID でない文字列）" do
      [ nil, "", "not-a-uuid", 123 ].each do |invalid|
        expect { gate.next_allowed_at(invalid) }.to raise_error(ArgumentError)
      end
    end

    it "時計が Time を返さなければ ArgumentError（黙って通さない）" do
      broken = described_class.new(limiter: limiter, clock: -> { 123 })

      expect { broken.next_allowed_at(user) }.to raise_error(ArgumentError, /Time/)
    end

    it "頻度制限の計数を省くと、プロセスで共有する計数（RateLimiter.shared）を、呼び出しのたびに引く" do
      shared = RateLimiter.new(clock: clock)
      allow(RateLimiter).to receive(:shared).and_return(shared)
      shared.check(RateLimitPolicy.recheck, user.id)

      expect(described_class.new(clock: clock).next_allowed_at(user)).to eq(now + 60)
    end

    it "時計を省くと実時計（SystemClock）。呼び出しのたびに読む" do
      result = described_class.new(limiter: RateLimiter.new).next_allowed_at(user)

      expect(result).to be_nil
    end
  end
end
