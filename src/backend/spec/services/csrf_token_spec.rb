require "rails_helper"

# CSRF トークン（issue #7。requirements.md 28.1。src/contracts/http-api.md 1.2・1.4）。
# セッションの識別子と SESSION_SECRET から、HMAC で導出する。保存しない（GET /api/state が返す値と、X-CSRF-Token の照合の両方で、導出する）。
RSpec.describe DerivedKeys do
  let(:secret) { "dummy-session-secret-for-derived-keys-spec-0123456789" }

  it "用途ごとに、32 バイトの鍵を導出する（同じ秘密値・同じ用途なら、同じ鍵）" do
    keys = described_class.new(secret: secret)

    expect(keys.derive("csrf").bytesize).to eq(32)
    expect(keys.derive("csrf")).to eq(described_class.new(secret: secret).derive("csrf"))
  end

  it "用途が違えば、別の鍵（用途の分離）" do
    keys = described_class.new(secret: secret)

    expect(keys.derive("csrf")).not_to eq(keys.derive("oauth_cookie"))
  end

  it "秘密値が違えば、別の鍵" do
    expect(described_class.new(secret: secret).derive("csrf")).not_to eq(described_class.new(secret: "#{secret}x").derive("csrf"))
  end

  it "鍵は、秘密値そのものではない（秘密値は、鍵から復元できない一方向の導出）" do
    expect(described_class.new(secret: secret).derive("csrf")).not_to include(secret)
  end

  [ nil, "", "   ", 123 ].each do |value|
    it "秘密値 #{value.inspect} は、例外にする" do
      expect { described_class.new(secret: value) }.to raise_error(ArgumentError)
    end
  end

  [ nil, "", :csrf, 1 ].each do |purpose|
    it "用途 #{purpose.inspect} は、例外にする" do
      expect { described_class.new(secret: secret).derive(purpose) }.to raise_error(ArgumentError)
    end
  end

  it "inspect に、秘密値を出さない" do
    expect(described_class.new(secret: secret).inspect).not_to include(secret)
  end
end

RSpec.describe CsrfToken do
  let(:secret) { "dummy-session-secret-for-csrf-spec-0123456789abcdef" }
  let(:csrf) { described_class.new(secret: secret) }
  let(:session_token) { "dummy-session-token-0123456789abcdefghijklmnop" }

  describe "#derive" do
    it "64 文字の 16 進数（HMAC-SHA256）" do
      expect(csrf.derive(session_token)).to match(/\A\h{64}\z/)
    end

    it "同じセッション・同じ秘密値なら、何度導出しても同じ（保存せず、導出で照合できる）" do
      expect(csrf.derive(session_token)).to eq(csrf.derive(session_token))
      expect(csrf.derive(session_token)).to eq(described_class.new(secret: secret).derive(session_token))
    end

    it "セッションが違えば、別の値（セッションに紐づく）" do
      expect(csrf.derive(session_token)).not_to eq(csrf.derive("#{session_token}x"))
    end

    it "秘密値が違えば、別の値（SESSION_SECRET から導出する）" do
      expect(csrf.derive(session_token)).not_to eq(described_class.new(secret: "#{secret}x").derive(session_token))
    end

    it "セッションの識別子そのものを含まない" do
      expect(csrf.derive(session_token)).not_to include(session_token)
    end

    it "セッションの識別子と秘密値から、HMAC-SHA256 で導出する（鍵の導出は DerivedKeys の csrf）" do
      key = DerivedKeys.new(secret: secret).derive("csrf")

      expect(csrf.derive(session_token)).to eq(OpenSSL::HMAC.hexdigest("SHA256", key, session_token))
    end

    [ nil, "", "  ", 123, [ "a" ] ].each do |value|
      it "セッションの識別子 #{value.inspect} は、例外にする" do
        expect { csrf.derive(value) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "#valid?" do
    let(:expected) { csrf.derive(session_token) }

    it "正しい値なら true" do
      expect(csrf.valid?(session_token, expected)).to be(true)
    end

    {
      "欠落（nil）" => nil,
      "空" => "",
      "1 文字違い" => "0",
      "短い（前方一致）" => :prefix,
      "長い（後ろに足した）" => :suffix,
      "大文字" => :upcase,
      "別のセッションの値" => :other_session,
      "別の秘密値の値" => :other_secret,
      "文字列でない（数値）" => 123,
      "文字列でない（配列）" => [ "x" ]
    }.each do |label, kind|
      it "#{label}は false" do
        provided =
          case kind
          when :prefix then expected[0, 63]
          when :suffix then "#{expected}0"
          when :upcase then expected.upcase
          when :other_session then csrf.derive("another-session-token-0123456789abcdefghij")
          when :other_secret then described_class.new(secret: "#{secret}x").derive(session_token)
          when "0" then "#{expected[0, 63]}#{expected[63] == '0' ? '1' : '0'}"
          else kind
          end

        expect(csrf.valid?(session_token, provided)).to be(false)
      end
    end

    it "定数時間の比較を使う" do
      expect(ActiveSupport::SecurityUtils).to receive(:secure_compare).at_least(:once).and_call_original

      csrf.valid?(session_token, expected)
    end

    it "セッションの識別子が不正なら、例外にせず false（照合の失敗として扱う）" do
      expect(csrf.valid?(nil, expected)).to be(false)
      expect(csrf.valid?("", expected)).to be(false)
    end
  end

  it "inspect に、秘密値を出さない" do
    expect(csrf.inspect).not_to include(secret)
  end
end
