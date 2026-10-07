require "rails_helper"

# 実時計を読む、アプリケーション層のサービスの中で、唯一の場所（issue #7）。
# ほかのサービス（RateLimiter・UsageRecorder・SessionStore など）は、時計・時刻を引数で受け取る（テストで時刻を進められる）。
RSpec.describe SystemClock do
  it "現在の時刻を返す（JST のタイムゾーンつき）" do
    now = described_class.now

    expect(now).to be_within(5.seconds).of(Time.current)
    expect(now.time_zone.name).to eq("Tokyo")
  end

  it "呼び出しのたびに、時刻を読み直す" do
    first = described_class.now
    travel_to(first + 1.hour) { expect(described_class.now).to be_within(5.seconds).of(first + 1.hour) }
  end

  it "時計として呼べる（引数の時計に渡せる）" do
    clock = described_class.method(:now)

    expect(clock.call).to be_within(5.seconds).of(Time.current)
  end

  include ActiveSupport::Testing::TimeHelpers
end
