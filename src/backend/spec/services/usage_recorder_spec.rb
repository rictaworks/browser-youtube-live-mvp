require "rails_helper"
require "support/model_support"
require "support/log_capture"

# 測定イベントの記録（issue #7。requirements.md 18.2・28.2。src/contracts/enums.json の usage_event_type）。
# 内部のアカウント識別子にだけ紐づける。氏名・メールアドレス・チャンネル名・タイトル・IP・端末を特定する文字列を、受け付けない。
RSpec.describe UsageRecorder do
  let(:now) { Time.utc(2026, 10, 7, 4, 30, 0) }
  let(:recorder) { described_class.new(clock: -> { now }) }
  let(:user) { create(:user) }

  # PII の混入を拒否する、受け付けない属性（Ruby のキーワード引数で、余分な属性は ArgumentError）
  pii_attributes = {
    email: "dummy@example.test",
    name: "Dummy Name",
    display_name: "Dummy Name",
    channel_title: "Dummy Channel",
    channel_name: "Dummy Channel",
    title: "Dummy Title",
    ip: "203.0.113.5",
    ip_address: "203.0.113.5",
    remote_ip: "203.0.113.5",
    user_agent: "Mozilla/5.0 (X11; Linux x86_64)",
    device: "Dummy Device",
    device_id: "dummy-device-0001",
    google_sub: "dummy-google-sub-0001",
    occurred_at: Time.utc(2000, 1, 1)
  }

  describe "#record（正常）" do
    it "測定イベントを 1 件作る（アカウント識別子・種別・符号・区分・ブラウザの分類・発生の時刻）" do
      browser = BrowserClass.new(family: "chromium", supported: true)

      event = recorder.record(user_id: user.id, type: "line_measured", reason_code: "ok", bucket: "throughput_kbps:4100-4999", browser_class: browser)

      expect(event).to be_a(UsageEvent).and be_persisted
      expect(UsageEvent.find(event.id)).to have_attributes(
        user_id: user.id, event_type: "line_measured", reason_code: "ok",
        bucket: "throughput_kbps:4100-4999", browser_class: "chromium:supported", occurred_at: now
      )
    end

    it "符号・区分・ブラウザの分類は、省略できる（nil で記録）" do
      event = recorder.record(user_id: user.id, type: "login_completed")

      expect(UsageEvent.find(event.id)).to have_attributes(reason_code: nil, bucket: nil, browser_class: nil)
    end

    it "アカウント識別子は、nil でもよい（ログイン前の出来事。アカウント削除のあと）" do
      event = recorder.record(user_id: nil, type: "login_started")

      expect(UsageEvent.find(event.id).user_id).to be_nil
    end

    it "測定イベントの種別 20 種のすべてを、記録できる" do
      expect(Contract::UsageEventType::ALL.size).to eq(20)

      Contract::UsageEventType::ALL.each do |type|
        expect { recorder.record(user_id: user.id, type: type) }.not_to raise_error
      end
      expect(UsageEvent.where(user_id: user.id).count).to eq(20)
    end

    it "発生の時刻は、引数の時計から取る（実時計に依存しない）" do
      event = described_class.new(clock: -> { Time.utc(2030, 1, 2, 3, 4, 5) }).record(user_id: user.id, type: "login_started")

      expect(event.occurred_at).to eq(Time.utc(2030, 1, 2, 3, 4, 5))
    end

    it "クラスメソッドでも呼べる（実時計）" do
      event = described_class.record(user_id: user.id, type: "login_started")

      expect(event.occurred_at).to be_within(5.seconds).of(Time.current)
    end

    it "返り値の inspect に、機密を出さない（アカウント識別子の列は、モデルの設定に従う）" do
      event = recorder.record(user_id: user.id, type: "login_started")

      expect(event.inspect).to include("login_started")
    end
  end

  describe "#record（拒否）" do
    it "種別が 20 種以外なら、例外にする" do
      [ "unknown", "", nil, :login_started, "LOGIN_STARTED", "login_started ", "login-started", 1 ].each do |type|
        expect { recorder.record(user_id: user.id, type: type) }.to raise_error(UsageRecorder::InvalidEventType)
      end
      expect(UsageEvent.count).to eq(0)
    end

    pii_attributes.each do |name, value|
      it "余分な属性 #{name}（#{value.class}）は、例外にする（受け付ける属性を、明示的に絞る）" do
        expect { recorder.record(user_id: user.id, type: "login_started", name => value) }.to raise_error(ArgumentError, /#{name}/)
        expect(UsageEvent.count).to eq(0)
      end
    end

    it "余分な属性の例外のメッセージに、値を含めない" do
      expect { recorder.record(user_id: user.id, type: "login_started", email: "dummy-pii-must-not-appear@example.test") }
        .to raise_error(ArgumentError) { |error| expect(error.message).not_to include("dummy-pii-must-not-appear") }
    end

    {
      "メールアドレス" => "dummy@example.test",
      "IP アドレス" => "203.0.113.5",
      "氏名" => "Dummy Name",
      "空白を含む" => "a b",
      "大文字" => "Reason",
      "33 文字（上限は 32）" => "a" * 33,
      "ハイフン" => "a-b",
      "日本語" => "日本",
      "空" => "",
      "改行" => "a\nb"
    }.each do |label, value|
      it "符号（reason_code）に #{label} は、例外にする（^[a-z0-9_]{1,32}$ だけ。自由記述を受け付けない）" do
        expect { recorder.record(user_id: user.id, type: "source_denied", reason_code: value) }.to raise_error(UsageRecorder::InvalidAttribute, /reason_code/)
        expect(UsageEvent.count).to eq(0)
      end
    end

    it "符号は、32 文字までの英小文字・数字・アンダースコアなら、記録できる" do
      expect { recorder.record(user_id: user.id, type: "source_denied", reason_code: "a" * 32) }.not_to raise_error
      expect { recorder.record(user_id: user.id, type: "source_denied", reason_code: "not_allowed_0") }.not_to raise_error
    end

    [ "12345", "throughput_kbps:99999", "dummy@example.test", "", "count:11", 5 ].each do |value|
      it "区分（bucket）に、区分の文字列でない #{value.inspect} は、例外にする（数値のまま・任意の文字列を保存しない）" do
        expect { recorder.record(user_id: user.id, type: "line_measured", bucket: value) }.to raise_error(UsageRecorder::InvalidAttribute, /bucket/)
      end
    end

    [ "chromium:supported", "Mozilla/5.0", { family: "chromium", supported: true }, 1, "" ].each do |value|
      it "ブラウザの分類（browser_class）に、BrowserClass でない #{value.inspect[0, 30]} は、例外にする（ユーザーエージェントの文字列を、受け取らない）" do
        expect { recorder.record(user_id: user.id, type: "capability_detected", browser_class: value) }.to raise_error(UsageRecorder::InvalidAttribute, /browser_class/)
      end
    end

    [ "not-a-uuid", "123", 123, "7c9d1e2f-3a4b-4c5d-8e6f-0a1b2c3d4e5f\n", :abc, "" ].each do |value|
      it "アカウント識別子（user_id）#{value.inspect} は、例外にする（UUID か nil）" do
        expect { recorder.record(user_id: value, type: "login_started") }.to raise_error(UsageRecorder::InvalidAttribute, /user_id/)
      end
    end

    it "user_id は、User のオブジェクトを受け付けない（識別子だけ）" do
      expect { recorder.record(user_id: user, type: "login_started") }.to raise_error(UsageRecorder::InvalidAttribute, /user_id/)
    end

    it "例外のメッセージに、値を含めない（符号・区分・識別子）" do
      expect { recorder.record(user_id: user.id, type: "source_denied", reason_code: "Dummy Value Must Not Appear") }
        .to raise_error(UsageRecorder::InvalidAttribute) { |error| expect(error.message).not_to include("Dummy Value Must Not Appear") }
    end
  end

  describe "保存されるもの（個人情報を含まない）" do
    it "usage_events の列は、識別子・アカウント識別子・発生の時刻・種別・符号・区分・ブラウザの分類だけ（PII の列が無い）" do
      expect(UsageEvent.column_names).to match_array(%w[ id user_id occurred_at event_type reason_code bucket browser_class ])
    end

    it "記録した行に、IP・氏名・メールアドレス・タイトルの値が入らない" do
      browser = BrowserClass.new(family: "firefox", supported: false)
      event = recorder.record(user_id: user.id, type: "capability_detected", reason_code: "missing_webcodecs", browser_class: browser)

      values = UsageEvent.find(event.id).attributes.values.map(&:to_s)
      expect(values.join(" ")).not_to match(/@|203\.0\.113|Mozilla/)
    end

    it "アカウントの削除で、測定イベントは、アカウントとの紐づけを外して残る（DB の外部キー）" do
      event = recorder.record(user_id: user.id, type: "login_completed")

      User.find(user.id).destroy!

      expect(UsageEvent.find(event.id).user_id).to be_nil
    end
  end

  describe "ログへ出さない" do
    it "ブラウザの分類・符号・アカウント識別子の記録で、ログへ機密・IP を出さない" do
      output = capture_logs do
        recorder.record(user_id: user.id, type: "capability_detected", reason_code: "ok", browser_class: BrowserClass.new(family: "chromium", supported: true))
      end

      expect(output).not_to include("203.0.113")
    end
  end
end
