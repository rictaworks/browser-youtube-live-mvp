require "rails_helper"

# ブラウザが送る測定イベントの検査（POST /api/usage-events の本文。src/contracts/http-api.md 3 章）。
# ブラウザが送れる種別は、capability_detected・source_granted・source_denied・line_measured・watch_url_copied の 5 つだけ。
# 数値（value）は、サーバーが区分に変換して記録する（数値のまま保存しない）。ユーザーエージェントの文字列を受け取らない。
RSpec.describe BrowserUsageEvent do
  sendable = %w[ capability_detected source_granted source_denied line_measured watch_url_copied ]
  not_sendable = Contract::UsageEventType::ALL - sendable

  def parse(attributes)
    described_class.parse(attributes)
  end

  it "ブラウザが送れる種別は、5 つ（契約のとおり）" do
    expect(described_class::SENDABLE_TYPES).to eq(sendable)
    expect(described_class::SENDABLE_TYPES).to be_frozen
  end

  describe ".parse（正常）" do
    it "契約の例: 回線計測（実効スループットと、ブラウザの分類）" do
      event = parse({ "event_type" => "line_measured", "value" => 5200, "browser_class" => { "family" => "chromium", "supported" => true } })

      expect(event.type).to eq("line_measured")
      expect(event.bucket).to eq("throughput_kbps:5000-5999")
      expect(event.browser_class).to eq(BrowserClass.new(family: "chromium", supported: true))
      expect(event.reason_code).to be_nil
    end

    sendable.each do |type|
      it "#{type} は、種別だけで受け付ける" do
        event = parse({ "event_type" => type })

        expect(event).to have_attributes(type: type, reason_code: nil, bucket: nil, browser_class: nil)
      end
    end

    it "符号（reason_code）を持てる" do
      expect(parse({ "event_type" => "source_denied", "reason_code" => "not_allowed" }).reason_code).to eq("not_allowed")
    end

    it "ブラウザの分類（系統と対応可否）を持てる。対応していない環境も、記録できる" do
      event = parse({ "event_type" => "capability_detected", "browser_class" => { "family" => "firefox", "supported" => false } })

      expect(event.browser_class.to_s).to eq("firefox:unsupported")
    end

    it "未知のキーは、無視する（契約: 要求の未知のキーは、無視します）。受け取った値は、保持しない" do
      event = parse({ "event_type" => "watch_url_copied", "email" => "dummy@example.test", "user_agent" => "Mozilla/5.0", "ip" => "203.0.113.5" })

      expect(event.to_h.values.map(&:to_s).join(" ")).not_to match(/@|Mozilla|203\.0\.113/)
      expect(event.to_h.keys).to match_array(%i[ type reason_code bucket browser_class ])
    end

    it "ブラウザの分類の中の未知のキー（user_agent など）は、無視する（保持しない）" do
      event = parse({ "event_type" => "capability_detected", "browser_class" => { "family" => "webkit", "supported" => true, "user_agent" => "Mozilla/5.0" } })

      expect(event.browser_class.to_s).to eq("webkit:supported")
      expect(event.inspect).not_to include("Mozilla")
    end

    it "JSON の null は、省略と同じ（任意の項目）" do
      event = parse({ "event_type" => "line_measured", "reason_code" => nil, "value" => nil, "browser_class" => nil })

      expect(event).to have_attributes(reason_code: nil, bucket: nil, browser_class: nil)
    end

    it "シンボルのキーでも読める（HashWithIndifferentAccess・ActionController::Parameters の変換後）" do
      expect(parse({ event_type: "line_measured", value: 100 }).bucket).to eq("throughput_kbps:0-799")
    end
  end

  describe "数値（value）の区分への変換" do
    {
      0 => "throughput_kbps:0-799",
      799 => "throughput_kbps:0-799",
      800 => "throughput_kbps:800-1199",
      1199 => "throughput_kbps:800-1199",
      1200 => "throughput_kbps:1200-1999",
      4099 => "throughput_kbps:3000-4099",
      4100 => "throughput_kbps:4100-4999",
      7999 => "throughput_kbps:6000-7999",
      8000 => "throughput_kbps:8000+",
      2_147_483_647 => "throughput_kbps:8000+"
    }.each do |value, bucket|
      it "line_measured の value=#{value} → #{bucket}" do
        expect(parse({ "event_type" => "line_measured", "value" => value }).bucket).to eq(bucket)
      end
    end

    it "数値そのものは、保持しない（区分だけ）" do
      event = parse({ "event_type" => "line_measured", "value" => 5234 })

      expect(event.to_h.values.map(&:to_s)).not_to include("5234")
      expect(event.inspect).not_to include("5234")
    end

    (sendable - [ "line_measured" ]).each do |type|
      it "#{type} は、数値（value）を持たない種別。送られたら invalid_input（value）" do
        expect { parse({ "event_type" => type, "value" => 5 }) }
          .to raise_error(BrowserUsageEvent::InvalidInput) { |error| expect(error.fields).to eq([ "value" ]) }
      end
    end
  end

  describe ".parse（ブラウザから送れない種別は、unsupported_event）" do
    not_sendable.each do |type|
      it "#{type} は、UnsupportedType にする" do
        expect { parse({ "event_type" => type }) }.to raise_error(BrowserUsageEvent::UnsupportedType)
      end
    end

    [ "unknown", "LINE_MEASURED", "line_measured ", " line_measured", "line-measured", "line_measured\n", "Line_Measured", "login_started; DROP TABLE" ].each do |type|
      it "未知の種別 #{type.inspect} は、UnsupportedType にする" do
        expect { parse({ "event_type" => type }) }.to raise_error(BrowserUsageEvent::UnsupportedType)
      end
    end

    it "種別が送れない種別のときは、ほかの項目の不備より先に、UnsupportedType にする" do
      expect { parse({ "event_type" => "login_started", "value" => "x", "reason_code" => "A B" }) }.to raise_error(BrowserUsageEvent::UnsupportedType)
    end

    it "例外のメッセージに、送られた種別の文字列を含めない" do
      expect { parse({ "event_type" => "dummy-unknown-type-must-not-appear" }) }
        .to raise_error(BrowserUsageEvent::UnsupportedType) { |error| expect(error.message).not_to include("dummy-unknown-type-must-not-appear") }
    end
  end

  describe ".parse（invalid_input）" do
    {
      "種別が無い" => [ {}, [ "event_type" ] ],
      "種別が null" => [ { "event_type" => nil }, [ "event_type" ] ],
      "種別が空" => [ { "event_type" => "" }, [ "event_type" ] ],
      "種別が空白" => [ { "event_type" => "  " }, [ "event_type" ] ],
      "種別が数値" => [ { "event_type" => 1 }, [ "event_type" ] ],
      "種別が配列" => [ { "event_type" => [ "line_measured" ] }, [ "event_type" ] ],
      "種別がオブジェクト" => [ { "event_type" => { "a" => 1 } }, [ "event_type" ] ],
      "符号が数値" => [ { "event_type" => "source_denied", "reason_code" => 1 }, [ "reason_code" ] ],
      "符号が空" => [ { "event_type" => "source_denied", "reason_code" => "" }, [ "reason_code" ] ],
      "符号に大文字" => [ { "event_type" => "source_denied", "reason_code" => "NotAllowed" }, [ "reason_code" ] ],
      "符号に空白" => [ { "event_type" => "source_denied", "reason_code" => "not allowed" }, [ "reason_code" ] ],
      "符号が 33 文字" => [ { "event_type" => "source_denied", "reason_code" => "a" * 33 }, [ "reason_code" ] ],
      "符号がメールアドレス" => [ { "event_type" => "source_denied", "reason_code" => "dummy@example.test" }, [ "reason_code" ] ],
      "符号が IP アドレス" => [ { "event_type" => "source_denied", "reason_code" => "203.0.113.5" }, [ "reason_code" ] ],
      "符号が配列" => [ { "event_type" => "source_denied", "reason_code" => [ "a" ] }, [ "reason_code" ] ],
      "値が文字列" => [ { "event_type" => "line_measured", "value" => "5200" }, [ "value" ] ],
      "値が小数" => [ { "event_type" => "line_measured", "value" => 5200.5 }, [ "value" ] ],
      "値が負" => [ { "event_type" => "line_measured", "value" => -1 }, [ "value" ] ],
      "値が真偽値" => [ { "event_type" => "line_measured", "value" => true }, [ "value" ] ],
      "値が範囲外（32 ビット整数を超える）" => [ { "event_type" => "line_measured", "value" => 2_147_483_648 }, [ "value" ] ],
      "値が配列" => [ { "event_type" => "line_measured", "value" => [ 1 ] }, [ "value" ] ],
      "ブラウザの分類が文字列（ユーザーエージェントの文字列）" => [ { "event_type" => "capability_detected", "browser_class" => "Mozilla/5.0 (X11; Linux x86_64)" }, [ "browser_class" ] ],
      "ブラウザの分類が配列" => [ { "event_type" => "capability_detected", "browser_class" => [] }, [ "browser_class" ] ],
      "ブラウザの分類の系統が未知" => [ { "event_type" => "capability_detected", "browser_class" => { "family" => "chrome", "supported" => true } }, [ "browser_class" ] ],
      "ブラウザの分類の系統が無い" => [ { "event_type" => "capability_detected", "browser_class" => { "supported" => true } }, [ "browser_class" ] ],
      "ブラウザの分類の系統が長い文字列" => [ { "event_type" => "capability_detected", "browser_class" => { "family" => "Mozilla/5.0", "supported" => true } }, [ "browser_class" ] ],
      "ブラウザの分類の対応可否が文字列" => [ { "event_type" => "capability_detected", "browser_class" => { "family" => "chromium", "supported" => "true" } }, [ "browser_class" ] ],
      "ブラウザの分類の対応可否が無い" => [ { "event_type" => "capability_detected", "browser_class" => { "family" => "chromium" } }, [ "browser_class" ] ],
      "ブラウザの分類が空のオブジェクト" => [ { "event_type" => "capability_detected", "browser_class" => {} }, [ "browser_class" ] ]
    }.each do |label, (attributes, fields)|
      it "#{label}: invalid_input（#{fields.join('・')}）" do
        expect { parse(attributes) }.to raise_error(BrowserUsageEvent::InvalidInput) { |error| expect(error.fields).to eq(fields) }
      end
    end

    it "複数の項目が不正なら、すべての項目名を、種別・符号・値・ブラウザの分類の順に返す" do
      attributes = { "event_type" => "line_measured", "reason_code" => "A B", "value" => "x", "browser_class" => "ua" }

      expect { parse(attributes) }.to raise_error(BrowserUsageEvent::InvalidInput) { |error| expect(error.fields).to eq(%w[ reason_code value browser_class ]) }
    end

    it "例外のメッセージに、送られた値を含めない" do
      expect { parse({ "event_type" => "source_denied", "reason_code" => "Dummy Value Must Not Appear" }) }
        .to raise_error(BrowserUsageEvent::InvalidInput) { |error| expect(error.message).not_to include("Dummy Value Must Not Appear") }
    end

    it "入力が Hash でなければ、invalid_input（種別）" do
      [ nil, "x", 1, [ { "event_type" => "line_measured" } ] ].each do |input|
        expect { parse(input) }.to raise_error(BrowserUsageEvent::InvalidInput) { |error| expect(error.fields).to eq([ "event_type" ]) }
      end
    end
  end

  it "値は凍結されている" do
    expect(parse({ "event_type" => "watch_url_copied" })).to be_frozen
  end
end
